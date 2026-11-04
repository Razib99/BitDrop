//! Coordinates expired credentials with the platform account service.
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::{oneshot, Mutex as AsyncMutex};

static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);
lazy_static::lazy_static! {
    static ref PENDING: Mutex<HashMap<u64, oneshot::Sender<Option<String>>>> = Mutex::new(HashMap::new());
    // Coalesce simultaneous 401 responses for the same rejected credential.
    static ref LAST_REFRESH: AsyncMutex<Option<(String, String, std::time::Instant)>> = AsyncMutex::new(None);
}

struct PendingRequest(u64);
impl Drop for PendingRequest {
    fn drop(&mut self) {
        PENDING.lock().remove(&self.0);
    }
}

pub async fn refresh_token(rejected: &str) -> Option<String> {
    refresh_token_with(rejected, std::time::Duration::from_secs(15), |request_id| {
        crate::api::audio_engine::emit_event(
            crate::api::audio_engine::EngineEvent::TokenRefreshRequested { request_id },
        )
    })
    .await
}

async fn refresh_token_with(
    rejected: &str,
    timeout: std::time::Duration,
    request: impl FnOnce(u64) -> bool,
) -> Option<String> {
    let mut last = LAST_REFRESH.lock().await;
    if let Some((old, new, refreshed_at)) = last.as_ref() {
        if new == rejected {
            *last = None;
        } else if old == rejected && refreshed_at.elapsed() < std::time::Duration::from_secs(5) {
            // Reuse only long enough to coalesce a burst of simultaneous failures.
            return Some(new.clone());
        }
    }
    let request_id = NEXT_REQUEST.fetch_add(1, Ordering::Relaxed);
    let (sender, receiver) = oneshot::channel();
    PENDING.lock().insert(request_id, sender);
    let _pending = PendingRequest(request_id);
    if !request(request_id) {
        return None;
    }
    let token = tokio::time::timeout(timeout, receiver).await.ok()?.ok()??;
    if token.is_empty() || token == rejected {
        return None;
    }
    *last = Some((
        rejected.to_string(),
        token.clone(),
        std::time::Instant::now(),
    ));
    Some(token)
}

pub fn supply_token(request_id: u64, token: Option<String>) {
    if let Some(sender) = PENDING.lock().remove(&request_id) {
        let _ = sender.send(token);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    static TEST_LOCK: AsyncMutex<()> = AsyncMutex::const_new(());

    #[tokio::test]
    async fn an_old_rejected_token_requests_new_credentials_after_the_reuse_window() {
        let _guard = TEST_LOCK.lock().await;
        let first = refresh_token_with("expired-original", Duration::from_secs(1), |id| {
            supply_token(id, Some("replacement-old".into()));
            true
        })
        .await;
        assert_eq!(first.as_deref(), Some("replacement-old"));
        LAST_REFRESH.lock().await.as_mut().unwrap().2 =
            std::time::Instant::now() - Duration::from_secs(6);
        let second = refresh_token_with("expired-original", Duration::from_secs(1), |id| {
            supply_token(id, Some("replacement-new".into()));
            true
        })
        .await;
        assert_eq!(second.as_deref(), Some("replacement-new"));
    }

    #[tokio::test]
    async fn simultaneous_rejections_share_one_refresh() {
        let _guard = TEST_LOCK.lock().await;
        let requests = AtomicU64::new(0);
        let refresh = || {
            refresh_token_with("expired-concurrent", Duration::from_secs(1), |id| {
                requests.fetch_add(1, Ordering::Relaxed);
                supply_token(id, Some("renewed-concurrent".into()));
                true
            })
        };
        let (first, second) = tokio::join!(refresh(), refresh());
        assert_eq!(first.as_deref(), Some("renewed-concurrent"));
        assert_eq!(second, first);
        assert_eq!(requests.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn missing_platform_response_times_out_and_removes_request() {
        let _guard = TEST_LOCK.lock().await;
        let id = AtomicU64::new(0);
        assert!(
            refresh_token_with("expired-timeout", Duration::from_millis(5), |request| {
                id.store(request, Ordering::Relaxed);
                true
            })
            .await
            .is_none()
        );
        assert!(!PENDING.lock().contains_key(&id.load(Ordering::Relaxed)));
    }

    #[tokio::test]
    async fn rejected_or_missing_credentials_are_not_reused() {
        let _guard = TEST_LOCK.lock().await;
        assert!(
            refresh_token_with("expired-rejected", Duration::from_secs(1), |id| {
                supply_token(id, Some("expired-rejected".into()));
                true
            })
            .await
            .is_none()
        );
        assert!(
            refresh_token_with("expired-missing", Duration::from_secs(1), |id| {
                supply_token(id, None);
                true
            })
            .await
            .is_none()
        );
    }

    #[tokio::test]
    async fn refresh_a_to_b_simulate_b_expiring_then_reject_a_again_verifies_new_refresh() {
        let _guard = TEST_LOCK.lock().await;
        // Step 1: Refresh A -> B
        let token_b = refresh_token_with("token-A", Duration::from_secs(1), |id| {
            supply_token(id, Some("token-B".into()));
            true
        })
        .await;
        assert_eq!(token_b.as_deref(), Some("token-B"));

        // Step 2: Simulate B expiring (age out past 5-second reuse window)
        LAST_REFRESH.lock().await.as_mut().unwrap().2 =
            std::time::Instant::now() - Duration::from_secs(6);

        // Step 3: Reject A again, verify a new platform refresh occurs (yielding token-C)
        let token_c = refresh_token_with("token-A", Duration::from_secs(1), |id| {
            supply_token(id, Some("token-C".into()));
            true
        })
        .await;
        assert_eq!(token_c.as_deref(), Some("token-C"));

        // Step 4: When token-B itself is rejected, verify cached entry is invalidated immediately
        let token_d = refresh_token_with("token-B", Duration::from_secs(1), |id| {
            supply_token(id, Some("token-D".into()));
            true
        })
        .await;
        assert_eq!(token_d.as_deref(), Some("token-D"));
    }
}
