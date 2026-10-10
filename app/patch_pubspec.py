import re

with open("pubspec.yaml", "r") as f:
    content = f.read()

content = content.replace(
    "dev_dependencies:\n  flutter_test:",
    "dev_dependencies:\n  flutter_launcher_icons: ^0.13.1\n  flutter_test:"
)

with open("pubspec.yaml", "w") as f:
    f.write(content)
