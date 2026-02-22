# Legacy Index

This folder tracks files moved out of runtime source during cleanup.

## Legacy Client Scripts

- `Temp/LegacyClient/PowerupEffectRenderer.client.lua`
  - From: `src/StarterPlayer/StarterPlayerScripts/PowerupEffectRenderer.client.lua`
  - Reason: Disabled placeholder renderer (`return nil`), not part of active gameplay.

- `Temp/LegacyClient/TeamsGUIBackup/Backup/`
  - From: `src/Teams/GUI/Backup/`
  - Reason: Legacy backup tree retained for reference only; removed from runtime mapping.

## Workspace Artifacts

- `Temp/Artifacts/oldgamereference.rbxlx`
- `Temp/Artifacts/surviveeee sync.rbxlx`
- `Temp/Artifacts/temp.rbxlx`
- `Temp/Artifacts/UltimateBarFrame`

Reason: Non-runtime reference artifacts moved out of project root to reduce workspace clutter.
