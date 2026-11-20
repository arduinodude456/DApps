# DockUpdate 2.3.0

DockUpdate now updates the complete AppDock 9.12.0 package. The fixed, validated file list includes the GlassClock module (9.9.0), DockAI module and logo (9.10.0), profiler (9.11.0), and DockAI server-proxy module (9.12.0). Each addition is gated by its first AppDock release so older releases never request files that do not exist. The bounded release-file allowance was raised from 96 to 104. Regression tests cover the full 9.12.0 file set and verify that the later files are not requested for older tags.
