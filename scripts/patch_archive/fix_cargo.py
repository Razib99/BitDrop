import re

with open("app/rust/Cargo.toml", "r") as f:
    cargo = f.read()

cargo = cargo.replace("""[target.'cfg(target_os = "android")'.dependencies]
oboe = "0.6.1"

# Google Drive API requirements
tokio = { version = "1.38", features = ["full"] }
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "stream"] }
byteorder = "1.5"
anyhow = "1.0"
""", """
[dependencies]
tokio = { version = "1.38", features = ["full"] }
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "stream"] }
byteorder = "1.5"
anyhow = "1.0"

[target.'cfg(target_os = "android")'.dependencies]
oboe = "0.6.1"
""")

with open("app/rust/Cargo.toml", "w") as f:
    f.write(cargo)
