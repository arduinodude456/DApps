# Status Message 1.0.0

Status Message is a small reference DApp for AppDock 2.1.0 local notifications.

It creates one normal-priority local notification the first time its pane is opened and offers a visible **Send status message** control for additional deliberate test messages. Each message appears as an AppDock pop-up and is stored in the Quick Settings inbox.

The DApp uses only `context.notify(...)` and `context.requestRebuild("ui")`; it has no network access, no background timer, and no external side effects. AppDock 2.1.0 or later is required.
