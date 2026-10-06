import re

with open("app/lib/core_live/live_core.dart", "r") as f:
    core = f.read()

core = core.replace("    } else {\n  }", "    } else {\n      await _mockCore.send(cmd);\n    }\n  }")

with open("app/lib/core_live/live_core.dart", "w") as f:
    f.write(core)
