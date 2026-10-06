import re

with open("app/lib/main.dart", "r") as f:
    content = f.read()

imports = """import 'package:audio_service/audio_service.dart';
import 'core_live/audio_handler.dart';
import 'providers/core_providers.dart';
"""
content = content.replace("import 'app.dart';", imports + "import 'app.dart';")

init_block = """  // Initialize the Rust FFI backend
  await RustLib.init();

  // Initialize the Android Background Audio Service
  final audioHandler = await AudioService.init(
    builder: () => BitDropAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.bitdrop.audio',
      androidNotificationChannelName: 'BitDrop Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  
  // Stash the handler globally for the provider to pick up
  globalAudioHandler = audioHandler;
"""

content = content.replace("  // Initialize the Rust FFI backend\n  await RustLib.init();\n", init_block)

with open("app/lib/main.dart", "w") as f:
    f.write(content)
