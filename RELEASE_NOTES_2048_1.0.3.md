# 2048 1.0.3

## Rendering fix

The 4×4 board now assigns each `FrameContainer` its own direct `overlap_offset` inside the board `OverlapGroup`. Previously, the offset was incorrectly attached to the nested tile label; KOReader therefore painted every tile frame at the board origin, leaving only the upper-left tile visibly stacked.

## Touch controls

The game board now accepts full-pane KOReader swipe gestures. Swipe west, east, north, or south to make the corresponding move. Visible arrow buttons and hardware directional keys remain available as accessibility and non-touch fallbacks.

## Validation

The regression test covers all 16 direct tile widgets, distinct grid offsets, active theme colors, normal moves, tile merges, valid west swipes, and ignored unknown swipe directions. Lua 5.1 syntax checks passed for 2048 and the Store DApp collection.
