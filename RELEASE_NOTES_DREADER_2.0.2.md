# DReader 2.0.2

## Fix

DReader no longer treats the first document image as the only image. Local HTML images are now assigned to their corresponding heading/chapter group, and the reader displays the image marker belonging to the current paginated page. EPUB chapter images use the same marker-to-image ordering within each chapter.

## Validation

The regression suite covers multiple local HTML images in different chapters, relative image paths, embedded CSS, missing fonts, safe text contrast, pane construction, and Lua 5.1 syntax.

## Device test matrix

| Test | Device A | Device B | Result / notes |
|---|---|---|---|
| Open HTML with image before first heading | | | |
| Open HTML with images in two chapters | | | |
| Open EPUB with one image per chapter | | | |
| Open EPUB with multiple images in one chapter | | | |
| Direct page browser selection | | | |
| Font size and margin changes | | | |
| Split-height DApp pane | | | |
| Missing font fallback | | | |
| Light CSS color fallback | | | |
| Reopen book and preserve progress | | | |

AppDock core remains unchanged at 2.0.0. DReader 2.0.2 is a DApp-only update.
