import re

with open("lib/features/home/home_screen.dart", "r") as f:
    content = f.read()

replacement = """
          Row(
            children: [
              Expanded(
                child: Text(
                  paused
                      ? 'Playback is not affected. Scanning resumes automatically.'
                      : 'Your library is ready to browse. Details fill in over '
                          '${status.wifiOnly ? 'Wi-Fi' : 'any network'}.',
                  style: context.t.bodySmall.copyWith(color: c.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => ref.read(cloudLibraryProvider).cancelScan(),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 32),
                  foregroundColor: c.textSecondary,
                ),
                child: const Text('Stop Sync'),
              ),
            ],
          ),
"""

content = content.replace(
    """
          Text(
            paused
                ? 'Playback is not affected. Scanning resumes automatically.'
                : 'Your library is ready to browse. Details fill in over '
                    '${status.wifiOnly ? 'Wi-Fi' : 'any network'}.',
            style: context.t.bodySmall.copyWith(color: c.textSecondary),
          ),""",
    replacement
)

with open("lib/features/home/home_screen.dart", "w") as f:
    f.write(content)
