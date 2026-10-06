import re

with open("app/rust/src/api/audio_engine.rs", "r") as f:
    content = f.read()

bad_block = """lazy_static::lazy_static! {
    static ref PLAYER_STATE: Mutex<PlayerState> = Mutex::new(PlayerState::default());
    static ref CMD_SENDER: Mutex<Option<crossbeam_channel::Sender<DecoderCmd>>> = Mutex::new(None);
    #[cfg(target_os = "android")]
    static ref ACTIVE_STREAM: Mutex<Option<AudioStream<oboe::Output, f32>>> = Mutex::new(None);
}"""

good_block = """lazy_static::lazy_static! {
    static ref PLAYER_STATE: Mutex<PlayerState> = Mutex::new(PlayerState::default());
    static ref CMD_SENDER: Mutex<Option<crossbeam_channel::Sender<DecoderCmd>>> = Mutex::new(None);
}

#[cfg(target_os = "android")]
lazy_static::lazy_static! {
    static ref ACTIVE_STREAM: Mutex<Option<AudioStream<oboe::Output, f32>>> = Mutex::new(None);
}"""

content = content.replace(bad_block, good_block)

with open("app/rust/src/api/audio_engine.rs", "w") as f:
    f.write(content)
