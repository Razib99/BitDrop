import re

with open("app/rust/Cargo.toml", "r") as f:
    cargo = f.read()

cargo = cargo.replace("""[target.'cfg(not(target_os = "android"))'.dependencies]
cpal = "0.15"
""", "")

with open("app/rust/Cargo.toml", "w") as f:
    f.write(cargo)
