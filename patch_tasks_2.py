import re

with open("task.md", "r") as f:
    content = f.read()

content = content.replace("[ ] **Task 1: OAuth2", "[x] **Task 1: OAuth2")
content = content.replace("[ ] **Task 2: Drive API", "[x] **Task 2: Drive API")
content = content.replace("[ ] **Task 3: Byte-Range", "[x] **Task 3: Byte-Range")
content = content.replace("[ ] **Task 4: LRU Chunk", "[x] **Task 4: LRU Chunk")
content = content.replace("[ ] **Task 5: Cloud Metadata", "[x] **Task 5: Cloud Metadata")
content = content.replace("[ ] **Task 6: SQLite Database", "[x] **Task 6: SQLite Database")

with open("task.md", "w") as f:
    f.write(content)
