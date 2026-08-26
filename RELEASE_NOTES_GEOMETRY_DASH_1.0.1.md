# Geometry Dash 1.0.1 — Smoother Fast Refresh

Geometry Dash now runs its arena animation at a **20 Hz** cadence instead of 12.5 Hz. This makes scrolling, jumping, and obstacle approach visibly smoother on compatible E-Ink hardware.

The rendering discipline remains unchanged: every frame repaints and requests KOReader's `fast` waveform only for the local game arena. No moving frame requests a fullscreen refresh.

The regression test now verifies the 20 Hz cadence and that each successful game frame queues the next bounded tick.
