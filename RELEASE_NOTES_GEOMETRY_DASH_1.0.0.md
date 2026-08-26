# Geometry Dash 1.0.0

Geometry Dash is a fully local AppDock runner game. Guide the cube through a hand-built multi-section course with single, double and triple spikes, raised blocks, stair patterns and jump pads. The course becomes denser in later sections and ends only after the final obstacle line.

Tap the arena to jump. Hardware **Press** and **Select** keys are alternatives when the device exposes them. Use **Play**, **Pause** and **Restart** below the arena; leaving or closing the DApp automatically pauses the game.

The moving arena is drawn directly to KOReader's active screen buffer and requests a bounded regional `fast` refresh per frame. Static headers and controls are not rebuilt while the cube runs. This deliberately favors responsive monochrome gameplay over color effects, animations outside the arena, network activity or an unbounded full-screen refresh loop.

## Verification

- Lua 5.1 syntax validation for the production DApp and local contract test.
- Level size, jump, jump-pad, spike collision, level completion, pause lifecycle, compact pane geometry and fast-refresh ordering are covered by regression tests.
- The DApp is offline-only and does not store personal data, use network access or run while it is inactive.
