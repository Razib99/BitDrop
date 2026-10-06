import re

# 1. Fix BitDropCore - remove `events`
with open("app/lib/core_api/bitdrop_core.dart", "r") as f:
    core = f.read()
core = re.sub(r"\s*Stream<CoreEvent> get events;", "", core)
with open("app/lib/core_api/bitdrop_core.dart", "w") as f:
    f.write(core)

# 2. Fix LiveBitDropCore - use PlayingState() and PausedState(), remove events
with open("app/lib/core_live/live_core.dart", "r") as f:
    live = f.read()

live = live.replace("Playing(QueueState.empty) : Paused(QueueState.empty)", "PlayingState() : PausedState()")
live = re.sub(r"\s*@override Stream<CoreEvent> get events => _mockCore.events;", "", live)
with open("app/lib/core_live/live_core.dart", "w") as f:
    f.write(live)

# 3. Fix core_providers.dart - ambiguous PlaybackState, remove eventsProvider
with open("app/lib/providers/core_providers.dart", "r") as f:
    prov = f.read()

prov = prov.replace("import 'package:audio_service/audio_service.dart';", "import 'package:audio_service/audio_service.dart' hide PlaybackState;")
prov = re.sub(r"/// One-shot core events[\s\S]*?ref.watch\(coreProvider\).events\);\n", "", prov)

with open("app/lib/providers/core_providers.dart", "w") as f:
    f.write(prov)
