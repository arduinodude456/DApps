# Snake 1.0.0 — Offline E-Ink Grid Game

Snake brings the classic grid game to AppDock as a fully offline DApp. Guide the growing snake to food, increase your score, and avoid the borders and your own body.

## Controls

- Use the on-screen **LEFT**, **UP**, **DOWN**, and **RIGHT** controls, or the reader's directional keys, to steer.
- Tap **Play**, press **Press** or **Select**, or tap the arena to start and pause.
- Use **Restart** after a crash or a cleared board.

## E-Ink behavior

Only the local game arena is redrawn at each movement step. It requests KOReader's regional `fast` waveform and yields to the E-Ink controller; no movement frame requests a fullscreen refresh.

Snake begins at a calm cadence and gradually accelerates as the score grows. It pauses automatically when the pane is deactivated or closed.
