import re

with open("app/lib/core_live/live_core.dart", "r") as f:
    core = f.read()

# Add import for rust FFI
core = core.replace("import 'audio_handler.dart';", "import 'audio_handler.dart';\nimport '../src/rust/api/audio_engine.dart' as rust;")

# Intercept EQ commands
eq_hook = """    } else if (cmd is SetGraphicGains) {
      rust.engineSetEq(gains: cmd.gains);
      await _mockCore.send(cmd);
    } else if (cmd is SetBypass) {
      rust.engineSetEqEnabled(enabled: !cmd.bypass);
      await _mockCore.send(cmd);
    } else {"""

core = core.replace("    } else {\n      await _mockCore.send(cmd);\n    }", eq_hook)

with open("app/lib/core_live/live_core.dart", "w") as f:
    f.write(core)
