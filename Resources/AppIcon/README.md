# CallScribe's icon: "Voice to words"

Three bars of a voice turning into three lines of text, on a midnight tile. The
bars are warm (orange → coral), the lines cool down to white as they become
words.

- `appicon.svg`: the app icon (1024 × 1024, macOS icon grid, 824 px tile).
  `../AppIcon.icns` holds it at 64 px and up.
- `appicon-small.svg`: two bars and two thicker lines, because the full mark
  turns to mush at 16 px. `../AppIcon.icns` holds it at 16 and 32 px.
- `AppIcon.icon`: the same design as layers for macOS 26 and later (an Icon
  Composer document: a #232850 → #0B0D1C fill, then the words and the voice as
  glass layers). `build.sh` compiles it into `Assets.car` with `actool`;
  `CFBundleIconName` points at it. Without it macOS 26 draws the `.icns` shrunk
  inside a gray square.

To rebuild `AppIcon.icns` after editing a source, render both SVGs to an
iconset with a renderer that draws SVG blur filters (`resvg`, or a browser;
macOS's own SVG renderer drops the glow): `icon_16x16.png`,
`icon_16x16@2x.png` and `icon_32x32.png` from `appicon-small.svg`, the other
seven sizes (64 to 1024 px) from `appicon.svg`. Then
`iconutil -c icns AppIcon.iconset -o ../AppIcon.icns`.

Colors: tile #232850 → #0B0D1C; mark #FF8A4C → #FF3F6C → #FFC2D2 → #FFFFFF
(left to right).
