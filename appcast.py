#!/usr/bin/env python3
"""Lists a release first in appcast.xml, the Sparkle feed every installed
CallScribe checks once a day (SUFeedURL in Info.plist).

    ./appcast.py <dmg> <version> <build number> [notes as an HTML fragment]

Signs the DMG with Sparkle's sign_update, which reads the EdDSA private key
from the login keychain. Called by release.sh.
"""
import os
import re
import subprocess
import sys
from email.utils import formatdate

ROOT = os.path.dirname(os.path.abspath(__file__))
FEED = os.path.join(ROOT, "appcast.xml")
SIGN_UPDATE = os.path.join(ROOT, ".build/artifacts/sparkle/Sparkle/bin/sign_update")
DOWNLOAD = "https://github.com/chrisperkles/CallScribe/releases/download/v{version}/{name}"
CHANNEL = "    <title>CallScribe</title>\n"

EMPTY_FEED = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
{CHANNEL}  </channel>
</rss>
"""


def main():
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    dmg, version, build = sys.argv[1:4]
    notes = sys.argv[4] if len(sys.argv) == 5 else ""

    signed = subprocess.run([SIGN_UPDATE, dmg], check=True, capture_output=True, text=True).stdout
    signature = re.search(r'sparkle:edSignature="([^"]+)"', signed).group(1)
    length = re.search(r'length="(\d+)"', signed).group(1)

    feed = open(FEED).read() if os.path.exists(FEED) else EMPTY_FEED
    if f"<sparkle:version>{build}</sparkle:version>" in feed:
        sys.exit(f"build {build} is already in appcast.xml")

    url = DOWNLOAD.format(version=version, name=os.path.basename(dmg))
    description = f"\n      <description><![CDATA[{notes}]]></description>" if notes else ""
    item = f"""    <item>
      <title>{version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>{description}
      <enclosure url="{url}" sparkle:edSignature="{signature}" length="{length}" type="application/octet-stream"/>
    </item>
"""
    with open(FEED, "w") as f:
        f.write(feed.replace(CHANNEL, CHANNEL + item, 1))


if __name__ == "__main__":
    main()
