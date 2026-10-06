import re

with open("app/rust/Cargo.toml", "r") as f:
    cargo = f.read()

cargo = cargo.replace("""[target.'cfg(target_os = "android")'.dependencies]
oboe = "0.6.1"
rusqlite = { version = "0.31", features = ["bundled"] }""",
"""rusqlite = { version = "0.31", features = ["bundled"] }

[target.'cfg(target_os = "android")'.dependencies]
oboe = "0.6.1"
""")

with open("app/rust/Cargo.toml", "w") as f:
    f.write(cargo)
