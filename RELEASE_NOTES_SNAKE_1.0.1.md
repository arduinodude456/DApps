# Snake 1.0.1 — Touch Steering Fix

Snake now recognizes touch swipes anywhere within its local pane. Swipe left, right, up, or down to steer; the matching move starts a paused game immediately.

The visible direction controls remain available as an additional touch fallback, as do the reader's directional keys. The close control remains separate from the local Snake touch range.

The regression test now verifies that the pane has a swipe gesture and that a downward swipe starts the game, selects the correct direction, and retains the bounded arena `fast`-refresh behavior.
