---
title: MOFA Community Scripts
description: Standalone Microsoft application reset, removal, repair, and reinstall scripts for Jamf Pro.
---

These scripts were originally sourced from package files like `Microsoft_Office_Reset_2.0.0.pkg` from *Office-Reset.com*, created by Paul Bowden. Since *Office-Reset.com* is no longer maintained, the MOFA and Mac Admin communities have taken over their maintenance, ensuring continued updates and improvements.

Contribute improvements through this checkout's repository review process.
The [packages directory](../packages/README.md) contains documentation only.

## Jamf Pro deployment

Upload the script source directly to a Jamf Pro Script object; no sibling files are required. Run the policy as root and use a login or Self Service trigger because user-data reset scripts require a valid console user with a home under `/Users`.

Only upload scripts from `mofa_community_maintained/scripts/`. Files under
`office_reset_archived/` are historical references and are not deployment
artifacts. Active scripts use `/bin/zsh --no-rcs` and system macOS tools only.

- AutoUpdate, Excel, OneDrive, OneNote, Outlook, PowerPoint, and Word reset
  scripts read `$4` as `reset` (default), `repair`, `reinstall`, or `force`;
  `MODE=value` is also accepted. Any other value exits with status 2.
  - `repair` and `reinstall` reinstall the app only when it is missing,
    damaged, not signed by Microsoft, differs from a custom-manifest pinned
    version, or (AutoUpdate and OneDrive) is older than the script's minimum.
  - `force` always downloads and reinstalls the app.
  - For Word, Excel, PowerPoint, OneNote, and Outlook, a successful reinstall
    exits without removing configuration data. AutoUpdate and OneDrive reset
    their configuration and then reinstall.
- `MOFA_Community_Microsoft_Teams_Removal_Reinstall.zsh` accepts `KEY=value`
  arguments beginning at `$4`; unsupported keys are ignored.
  - `MODE=reinstall` (default; `repair` and `force` are aliases) removes
    Teams for all users (`CLEAN_ALL_USERS=true`) and reinstalls it.
  - `MODE=reset` removes only the console user's Teams data, shared OneAuth
    sign-in data, and retired Teams app bundles. It keeps the installed app
    and does not download anything.
  - In both modes, custom backgrounds are copied to `~/Teams_Backgrounds_Backup`.
- Office license/sign-in reset, Office factory reset, Office removal, and
  Outlook data removal have no custom Jamf parameters.
- Repair and reinstall modes download the Microsoft package into a private
  temporary folder. The package must pass `pkgutil` (Microsoft Developer ID,
  team `UBF8T346G9`) and Gatekeeper checks before the installed app is
  touched. Assign these modes to Self Service or a dedicated maintenance
  policy because the policy remains active until installation finishes.
- Download, signature, cleanup, and installer failures return nonzero so Jamf
  marks the policy failed.
- Teams removal/reinstall logs to
  `/var/log/MOFA_Community_Microsoft_Teams_Removal_Reinstall.log`. Other scripts
  write to the Jamf policy log.

Do not pass shell expressions or secrets as parameters. No parameter is
treated as shell code.

## Retired scripts

These scripts were removed from the active set. Their Office-Reset.com
originals remain under `office_reset_archived/` for reference.

| Removed script | Reason | Replacement |
| --- | --- | --- |
| `MOFA_Community_Microsoft_Teams_Reset.zsh` | Superseded | `MOFA_Community_Microsoft_Teams_Removal_Reinstall.zsh` with `MODE=reset` (reset) or `MODE=reinstall` (repair/force) |
| `MOFA_Community_Microsoft_License_Reset.zsh` | Strict subset of the sign-in reset | `MOFA_Community_Microsoft_OfficeLicenseSignIn_Reset.zsh` |
| `MOFA_Community_Microsoft_SkypeForBusiness_Removal.zsh` | Skype for Business Online was retired in 2021 | None |
| `MOFA_Community_WebExPT_Removal.zsh` | WebEx Productivity Tools is retired, and the script also deleted current Webex Meetings data | Outlook reset still removes the legacy WebEx plugin folder |
| `MOFA_Community_ZoomPlugin_Removal.zsh` | The Zoom Outlook plugin is retired in favor of the Zoom for Outlook add-in | Outlook reset still removes the legacy Zoom plugin folders |
