# DReader 2.0.1

## Fixes

- Fixed local HTML image discovery for relative paths such as `cover.png`, `./images/cover.jpg`, and safe nested paths. Only existing local raster files are rendered; remote URLs and unsafe traversal paths remain excluded.
- Fixed low-contrast HTML/CSS text. Light document colors are now rejected for the E-Ink reader surface and fall back to a readable dark color.
- Preserved safe fallback behavior for unknown fonts and older KOReader builds without RGB color helpers.

AppDock core is unchanged. This is a DReader-only update and does not alter the AppDock 2.0.0 beta version.
