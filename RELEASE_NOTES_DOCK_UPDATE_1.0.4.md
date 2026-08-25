# DockUpdate 1.0.4

DockUpdate now requires and stages both additional AppDock core modules introduced after the original updater contract:

| Required module | Reason |
|---|---|
| `appdock_notifications.lua` | Provides AppDock 2.1.0 local notification pop-ups and inbox behavior. |
| `appdock_help.lua` | Provides AppDock 2.2.0 bilingual searchable offline Help. |

The update remains explicit-confirmation only. It downloads expected Lua files over HTTPS, checks syntax, stages the complete file set and swaps the plugin atomically while retaining a local rollback copy.
