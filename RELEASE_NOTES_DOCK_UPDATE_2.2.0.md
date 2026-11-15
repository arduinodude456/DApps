# DockUpdate 2.2.0

DockUpdate now supports the complete 92-file AppDock 9.7.0 package. The fixed allowlist includes six new Lua modules and five Cyber skin PNG assets, all gated so older AppDock tags do not request files they do not contain. The bounded release-file limit is raised to 96 while the existing per-file, asset, and total-download limits remain in force. Regression coverage includes a complete simulated 9.7.0 installation, PNG validation, and checks that the new files are not requested for 9.6.0.
