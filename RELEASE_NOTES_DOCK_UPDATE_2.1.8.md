# DockUpdate 2.1.8

DockUpdate is verified against the AppDock 9.5.2 release. The fixed allowlist still covers all 78 files; the updated `appdock_dapps.lua` is now 299,656 bytes and remains within the existing bounded 512 KiB per-source limit. Regression tests exercise detection and installation of AppDock 9.5.2 while retaining explicit confirmation and the existing file-count and total-size limits.
