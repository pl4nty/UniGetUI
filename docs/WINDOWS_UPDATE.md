# Windows Update integration

On Windows 11 build 26100.9168 / 26200.9168 or later, UniGetUI can register as a provider for the [Windows Update Orchestration Platform (UOP)](https://github.com/microsoft/windows-uop). Windows Update then decides when package updates are installed, with the logic it uses for its own updates: device idle, plugged in, on a suitable network, outside active hours, and within Windows Update policies.

Enable it in **Settings > Package update preferences > Windows Update integration** (a UAC prompt follows). The card only appears on a machine-wide installation, since the orchestrator requires the provider to belong to an installed product.

## How it works

Everything lives in `Assets\WindowsUpdateProvider`:

- `provider.json` declares the provider. At release, `scripts/prepare-windows-update-provider.ps1` adds the SHA-256 hash of every file and generates `UniGetUI.cat` for it, which is then code-signed.
- `UniGetUI-provider.ps1` is run by Windows Update with `-Scan` and `-Deploy <package>`, and by UniGetUI (elevated) with `-Register`, `-Unregister` and `-Refresh`. It calls `UniGetUI.exe --uop-scan` or `--uop-update`, which load the package engine without a window and list or update packages as the Software Updates page would, then reports the result through `Windows.Management.Update`.

Registering copies the folder to `%ProgramData%\USOPrivate\Providers\Registered\UniGetUI_<version>`, and Windows Update runs the scripts from there as `SYSTEM`, one deploy at a time. The installer refreshes that copy after an upgrade and unregisters it on uninstall.

## Limitations

- Updates run as `SYSTEM`: they use that account's UniGetUI settings and only cover machine-wide packages.
- The orchestrator requires every update to name an installed product, and packages from most managers have none, so all updates are attributed to UniGetUI's `ProductCode`.
- Windows refuses to unregister a provider while one of its updates is installing (`0x8024A304`), so disabling the integration can fail until that update finishes.
- Windows only surfaces app updates in **Settings > Apps > Installed apps** when they need the user, to approve them or to restart the device. UniGetUI never reports a required restart yet, and only reports progress at the start and end of each update.

## Testing a development build

Run the prepare script on the build output, sign `UniGetUI.cat` with a certificate trusted in `LocalMachine\Root`, make sure the `{889610CC-4337-4BDB-AC3B-4F21806C0BDE}_is1` uninstall key exists, then run `UniGetUI-provider.ps1 -Register` from an elevated Windows PowerShell. Errors are the `0x8024A3xx` codes documented in [UOPReturnCodes.md](https://github.com/microsoft/windows-uop/blob/main/docs/UOPReturnCodes.md).
