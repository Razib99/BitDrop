import re

# 1. Fix LiveBitDropCore contextLabel
with open("app/lib/core_live/live_core.dart", "r") as f:
    live = f.read()

live = live.replace("NowPlaying(track: track)", "NowPlaying(track: track, contextLabel: 'Local Music')")
with open("app/lib/core_live/live_core.dart", "w") as f:
    f.write(live)

# 2. Fix AppShell - remove coreEventsProvider listen
with open("app/lib/features/shell/app_shell.dart", "r") as f:
    shell = f.read()

# the shell usually has ref.listen(coreEventsProvider, ...)
# we can just comment out that listener
shell = re.sub(r"ref\.listen\(coreEventsProvider.*?\n\s+.*?\}\);", "", shell, flags=re.DOTALL)

with open("app/lib/features/shell/app_shell.dart", "w") as f:
    f.write(shell)

# 3. Fix core_providers.dart - remove developerMode
with open("app/lib/providers/core_providers.dart", "r") as f:
    prov = f.read()
prov = prov.replace(", developerMode: true", "")
with open("app/lib/providers/core_providers.dart", "w") as f:
    f.write(prov)

