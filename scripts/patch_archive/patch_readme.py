import re

with open("README.md", "r") as f:
    readme = f.read()

# Update Phase 5 in README
old_phase_5 = """- [ ] **Phase 5: Multi-Cloud & iOS Expansion**
  - [ ] S3-compatible, WebDAV, and OpenSubsonic backends
  - [ ] iOS shell (`AVAudioSession` + CoreAudio pull sink)"""

new_phase_5 = """- [ ] **Phase 5: Multi-Cloud & iOS Expansion**
  - [ ] S3-compatible, WebDAV, and OpenSubsonic backends
  - [x] iOS shell (`AVAudioSession` + CoreAudio pull sink)"""

readme = readme.replace(old_phase_5, new_phase_5)

with open("README.md", "w") as f:
    f.write(readme)
