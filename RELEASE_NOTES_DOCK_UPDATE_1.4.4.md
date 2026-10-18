# DockUpdate 1.4.4

DockUpdate includes `features.adf` in its fixed, required AppDock release file list. The file is downloaded from the plugin package, size-limited, checked for the expected AppDock page structure, staged as inert data (never executed as Lua), verified again from disk, and atomically installed beside the core modules. A release missing this file is rejected before it can replace the active plugin.

The DockUpdate regression test now verifies catalog version 1.4.4 and confirms that a valid packaged `features.adf` survives the complete staged install.
