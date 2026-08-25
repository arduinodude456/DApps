# AppDock Store Widgets 1.0.0

Three passive, local-first Homescreen widgets are now available through AppStore.

| Widget | Data source | Display behavior | Boundary |
|---|---|---|---|
| Reading Stats | The currently active KOReader document, when it exposes a current page and page count. | Book filename, page position and percentage when available. | It does not scan a reading-history database or fabricate lifetime statistics. Without an active document it shows a clear empty state. |
| Analog Clock | Local device clock at Homescreen rebuild time. | Drawn clock face, current time and date. | It owns no timer or animation; it updates only with AppDock’s existing limited Homescreen rebuild. |
| Calendar | The existing local `appdock_calendar/events.lua` store written by the Calendar DApp. | Up to three upcoming local appointments, sorted by date. | It does not contact a system calendar, cloud service or network source. Install and use Calendar DApp to add appointments. |

All three are ordinary AppStore widgets, so installation requires confirmation and visibility can be controlled under **Manage apps and widgets → Store widgets**. They perform no network access, background jobs, animation loops or forced full refreshes.
