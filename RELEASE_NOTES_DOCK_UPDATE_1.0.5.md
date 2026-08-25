# DockUpdate 1.0.5

DockUpdate 1.0.5 extends its fixed AppDock core update contract with:

| Required module | Reason |
|---|---|
| `appdock_boot.lua` | Provides the AppDock 2.3.0 two-frame E-Ink start sequence and the new AppDock rabbit brand mark handoff. |

The updater continues to load only expected files over HTTPS, validate Lua syntax, stage the entire required set and atomically swap the plugin folder after explicit confirmation.
