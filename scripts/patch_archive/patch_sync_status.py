import re

with open("app/lib/core_live/live_core.dart", "r") as f:
    core = f.read()

# Replace delegated syncStatus
core = core.replace("@override Stream<SyncStatus> get syncStatus => _mockCore.syncStatus;", "final _syncStatus = BehaviorSubject<SyncStatus>.seeded(SyncStatus.idle);\n  @override Stream<SyncStatus> get syncStatus => _syncStatus.stream;")

with open("app/lib/core_live/live_core.dart", "w") as f:
    f.write(core)
