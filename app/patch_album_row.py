import re

with open("lib/widgets/rows.dart", "r") as f:
    content = f.read()

replacement = """
                      AvailabilityGlyph(
                        availability: album.availability,
                        downloadProgress: album.downloadProgress,
                        size: 14,
                        showCloudOnly: true,
                      ),
"""

content = content.replace(
    """
                      AvailabilityGlyph(
                        availability: album.availability,
                        downloadProgress: album.downloadProgress,
                        size: 14,
                      ),""",
    replacement
)

with open("lib/widgets/rows.dart", "w") as f:
    f.write(content)
