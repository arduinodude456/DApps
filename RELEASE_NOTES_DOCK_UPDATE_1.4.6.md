# DockUpdate 1.4.6

DockUpdate now installs the complete current AppDock 8.3.5 plugin tree: all 44 Lua modules, all 23 bundled PNG assets, `appdock_suggestions.db`, and `features.adf` (69 files total). The previous 65-file ceiling rejected the current package, and four newer modules were absent from the allowlist: Bluetooth, sleep-screen weather, transfers, and YouTube Shorts.

The updater now gates modules by their first AppDock release so older AppDock tags are not asked for files that did not exist yet. The bounded package ceiling is 80 files, and the 16 MiB cumulative download limit is now enforced during staging. Existing per-file validation, explicit confirmation, atomic replacement, and rollback behavior remain in place.

Regression coverage installs a complete 8.3.5 fixture and verifies every source, data file, and asset, while retaining compatibility checks for earlier tags.
