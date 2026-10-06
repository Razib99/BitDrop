import re

with open("app/lib/core_live/live_core.dart", "r") as f:
    core = f.read()

# Remove the interceptors from send()
core = re.sub(r"    \} else if \(cmd is SetGraphicGains\) \{.*?\} else if \(cmd is SetBypass\) \{.*?\} else \{", "    } else {", core, flags=re.DOTALL)

# Add listener in constructor
listen_hook = """    _mockCore.eq.listen((eqState) {
      if (eqState.graphicGains.isNotEmpty) {
        // Only 10 bands supported in Rust currently
        rust.engineSetEq(gains: eqState.graphicGains.take(10).toList());
      } else {
        rust.engineSetEq(gains: List.filled(10, 0.0));
      }
      rust.engineSetEqEnabled(enabled: !eqState.bypass);
    });
  }"""

core = re.sub(r"    \}\);\n  \}", "    });\n\n" + listen_hook, core, flags=re.DOTALL)

with open("app/lib/core_live/live_core.dart", "w") as f:
    f.write(core)
