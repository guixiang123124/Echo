# Claude Settings (Team)

- `settings.shared.json`: shared team-safe baseline permissions.
- `settings.local.json`: personal machine-specific permissions (keep your own).

Recommended workflow for collaborators:
1. Copy `settings.shared.json` and merge needed entries into local settings.
2. Keep path-specific and personal rules only in `settings.local.json`.
