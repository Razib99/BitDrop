import re

with open("/home/razib/.gemini/antigravity/brain/0e5fcd32-fc20-4937-b415-8b6dd9a28a25/task.md", "r") as f:
    content = f.read()

content = content.replace("- [/] **Task 4: DSP Engine (Rust)**", "- [x] **Task 4: DSP Engine (Rust)**")

with open("/home/razib/.gemini/antigravity/brain/0e5fcd32-fc20-4937-b415-8b6dd9a28a25/task.md", "w") as f:
    f.write(content)
