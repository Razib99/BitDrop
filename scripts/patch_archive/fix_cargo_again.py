import re

with open("app/rust/Cargo.toml", "r") as f:
    cargo = f.read()

cargo = cargo.replace("\n[dependencies]\ntokio = ", "\ntokio = ")

with open("app/rust/Cargo.toml", "w") as f:
    f.write(cargo)
