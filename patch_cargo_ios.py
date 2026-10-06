import re

with open("app/rust/Cargo.toml", "r") as f:
    cargo = f.read()

cargo += """
[target.'cfg(any(target_os = "ios", target_os = "macos"))'.dependencies]
cpal = "0.15"
"""

with open("app/rust/Cargo.toml", "w") as f:
    f.write(cargo)
