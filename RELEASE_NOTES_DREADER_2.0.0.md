# DReader 2.0.0

DReader 2.0.0 extends the AppDock reader without requiring an AppDock core version change. It continues to use the existing `openFile(instance, path)` and `buildPane(instance, context)` DApp contracts.

## Included

- Local EPUB, HTML, HTM, and XHTML support.
- Embedded/local HTML and EPUB raster images are rendered in a bounded image area above the current page text.
- Inline and embedded CSS metadata for font family, base font size, and text color is read when available. Unknown fonts safely fall back to KOReader's standard `cfont`.
- Reader font size changes preserve the reader's relative layout scaling; the parsed heading ratio is retained as document style metadata.
- A page browser shows page numbers without previews and permits direct page selection.
- Unlimited per-book bookmarks are stored beside the book as `[bookname].lz` with chapter, page, timestamp, and optional annotation.
- The page browser provides access to the bookmark list.
- Existing reading progress, chapter navigation, local-first storage, archive-entry limits, and damaged-file rejection remain active.

## Compatibility and safety

No AppDock core file is required for this DReader release. The Files DApp can continue handing supported files to DReader through the established contract. EPUB archive paths are validated, archive and entry sizes are bounded, scripts/styles are removed from displayed text, and bookmark files are written through a temporary file before rename.

## Test focus

Test EPUBs with relative images, HTML documents with local images, missing fonts, CSS colors, multiple chapters, page jumps, bookmarks with and without notes, reopening a book, damaged EPUBs, and the Files-DApp handoff. Check both normal and split-height DApp panes on real KOReader hardware.

## Known scope

This is a pragmatic DApp reader, not a replacement for KOReader's full EPUB engine. Complex CSS layout, SVG/vector-only images, DRM, JavaScript, remote resources, and rich inline formatting are intentionally outside this release. DReader 2.0.0 does not include the AppDock Splitscreen bug fix.
