# Rider development tasks

The shared Rider run configurations under `.run/` call `openasar-dev.ps1` through PowerShell 7 (`pwsh.exe`). Rider's bundled Shell Scripts plugin should discover them automatically after the branch is checked out.

## Configurations

- **OpenAsar | Build Local** builds `tmp/app.asar` with auto-update disabled and a `dev-<sha>` version.
- **OpenAsar | Build Rolling** builds a local rolling-channel artifact using the next patch prerelease line and the current GitHub `origin` as the update repository.
- **OpenAsar | Equicord - Build + Install** performs the full local test loop: verify the Equicord layout, stop Discord, confirm it is gone, build, back up the existing `_app.asar`, replace it, verify hashes, and relaunch Discord normally through `Update.exe --processStart Discord.exe`.
- **OpenAsar | Equicord - Install Existing** installs the existing `tmp/app.asar` without rebuilding it.
- **OpenAsar | Equicord - Restore Backup** restores `resources/_app.asar.backup` and relaunches Discord.
- **OpenAsar | Discord - Launch** starts the stable Discord install through its normal Squirrel updater launcher.
- **OpenAsar | Clean** removes local OpenAsar build output under `tmp/`.

## Equicord safety checks

The Equicord tasks target the numerically newest `%LOCALAPPDATA%\Discord\app-*\resources` directory. Before touching `_app.asar`, the script requires both `app.asar` and `_app.asar`, checks that the small `app.asar` loader references Equicord, and leaves Equilotl's `app.asar.backup` untouched.

Every install overwrites `resources/_app.asar.backup` with the currently installed `_app.asar` and verifies the backup hash before removing the old file. If replacement fails, the script attempts to restore that verified backup before returning an error.

The all-in-one Equicord task intentionally uses this order:

1. verify the target layout
2. stop Discord and wait until no `Discord` process remains
3. build the local OpenAsar artifact
4. back up and verify the existing `_app.asar`
5. remove `_app.asar`
6. copy and verify the new build
7. start Discord through `Update.exe`

If the build or install fails after Discord was stopped, the script attempts to relaunch Discord with the original/restored file.
