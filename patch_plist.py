import re

with open("app/ios/Runner/Info.plist", "r") as f:
    content = f.read()

bg_modes = """
    <key>UIBackgroundModes</key>
    <array>
        <string>audio</string>
    </array>
"""

# Insert before </dict>
content = content.replace("</dict>\n</plist>", bg_modes + "</dict>\n</plist>")

with open("app/ios/Runner/Info.plist", "w") as f:
    f.write(content)
