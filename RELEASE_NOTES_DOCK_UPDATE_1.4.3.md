# DockUpdate 1.4.3

DockUpdate does not request or stage `assets/wallpaper/appdock_default.svg` anymore. AppDock updates now succeed when the optional bundled default wallpaper is absent from a release.

The updater continues to fetch only explicitly allowlisted AppDock Lua modules, PNG assets, and the validated suggestion database over HTTPS, then verifies the staged files before the atomic installation step. A regression test covers the update flow with no wallpaper file available.
