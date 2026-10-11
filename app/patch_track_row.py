import re

with open("lib/widgets/rows.dart", "r") as f:
    content = f.read()

replacement = """
              AvailabilityGlyph(
                availability: track.availability,
                cachedPercent: track.cachedPercent,
                downloadProgress: track.downloadProgress,
                showCloudOnly: true,
              ),
"""

content = content.replace(
    """
              AvailabilityGlyph(
                availability: track.availability,
                cachedPercent: track.cachedPercent,
                downloadProgress: track.downloadProgress,
              ),""",
    replacement
)

with open("lib/widgets/rows.dart", "w") as f:
    f.write(content)
