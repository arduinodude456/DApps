# Geometry Dash 1.0.2 — Close-Button Input Fix

This release fixes an input-range conflict in the game pane. The jump gesture is now aligned to the actual arena rectangle below the AppDock header.

The AppDock close control is outside the jump range again and can reliably close Geometry Dash. Touches inside the arena continue to start and control jumps.

The regression test verifies the arena gesture coordinates, alongside the existing game-loop, collision, and regional `fast`-refresh checks.
