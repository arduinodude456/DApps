# DReader 2.0.3

## Fix

Fixed HTML image ordering. The first image marker was generated with document-global numbering, while the HTML image cache was rebuilt per chapter. As a result, a later image could be selected for the current page while the first image appeared to be skipped.

HTML documents now use one bounded, document-global local image list for all chapters. `IMAGE_1`, `IMAGE_2`, and subsequent markers therefore resolve to the corresponding local files consistently. Multiple images on one page remain bounded by the E-Ink image limit.

EPUB chapter image ordering remains local to each chapter, matching the chapter text markers.

AppDock core remains unchanged at 2.0.0.
