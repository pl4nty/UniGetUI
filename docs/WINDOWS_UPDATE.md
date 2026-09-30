# Windows Update integration

On Windows 11 with the August 2026 cumulative update or later (build 26100.9168 / 26200.9168+), UniGetUI can register itself as a provider for the [Windows Update Orchestration Platform (UOP)](https://github.com/microsoft/windows-uop). Windows Update then decides when package updates are installed, using the same logic it uses for its own updates: device idle, plugged in, on a suitable network, outside active hours, and within any Windows Update policies. Progress shows up in **Settings > Apps > Installed apps**.

This is an alternative to UniGetUI's own scheduled maintenance, not a replacement: both can be enabled, in which case whichever runs first installs the update.

## Enabling it

**Settings > Package update preferences > Windows Update integration > Enable.** A UAC prompt follows, since registering a provider requires administrator rights.

The card only appears when:

- the OS build supports UOP;
- UniGetUI is installed for all users (the orchestrator requires the provider to belong to a product registered under `HKLM\...\Uninstall`, and per-user or portable installs are not);
- the provider files are present in the installation folder.

Registration state is kept in `HKLM\SOFTWARE\Devolutions\UniGetUI`, value `WindowsUpdateProviderRegistered`. The installer re-registers an enabled provider after every upgrade, because the orchestrator validates the provider files at registration time, and unregisters it on uninstall.

## How it works

```
Windows Update orchestrator
  │  every 22 h: scan                     │  when it is a good time: deploy
  ▼                                       ▼
Assets\WindowsUpdateProvider\UniGetUI-scan.ps1     UniGetUI-action.ps1 -Request <package>
  │  UniGetUI.exe --uop-scan                        │  UniGetUI.exe --uop-update
  ▼                                                 ▼
State\scan-result.json  ──► SetScanResult()        State\action-*.json ──► SetActionResult()
```

- `provider.json` declares the provider (`Id` `UniGetUI`, type `Powershell`) and the SHA-256 hash of every script in the folder. `UniGetUI.cat`, generated and code-signed by the release pipeline, vouches for `provider.json`.
- The scan script runs `UniGetUI.exe --uop-scan`, which loads the package managers headlessly and lists the available updates exactly as the **Software Updates** page would (ignored updates and the minimum update age apply). Each one is reported as a `Deploy` action.
- For each update it chose to install, the orchestrator runs the action script, which runs `UniGetUI.exe --uop-update` for that package and reports the outcome. Updates always run non-interactively.
- Logs and intermediate results are written to the `State` subfolder, the only place the orchestrator lets a provider write to.

The `--uop-scan` and `--uop-update` arguments are internal to this integration and not part of the public CLI.

## Known limitations

- **Update identity.** The orchestrator requires every update to name an installed product (MSI/ARP `ProductCode` or MSIX `PackageFamilyName`). Packages from most managers have no such identity, so all updates are attributed to UniGetUI's own `ProductCode`.
- **Account.** The orchestrator runs providers from a system service, so UniGetUI is expected to run under that account: it uses that account's UniGetUI settings (enabled managers, ignored updates) and only sees packages installed machine-wide. Per-user installs from the signed-in user's WinGet, Scoop, npm, etc. are not covered.
- **Reboots and running apps.** Installers that need a reboot or need the app closed are reported as plain successes or failures; UniGetUI does not yet report `RestartReason`s or provide close-and-install actions.
- **Progress.** Only the start and the end of each update are reported.
- **Sizes.** Download and install sizes are reported as 0 because most managers do not expose them.

## Development

After editing any file in `src/SharedAssets/Assets/WindowsUpdateProvider`, refresh the hashes in `provider.json` (the files must keep CRLF line endings, which `.gitattributes` enforces):

```powershell
./scripts/prepare-windows-update-provider.ps1 src/SharedAssets/Assets/WindowsUpdateProvider -SkipCatalog
```

`WindowsUpdateProviderTests` fails if the hashes are stale.

To test registration on a development machine, generate the catalog in the build output with the same script (without `-SkipCatalog`, needs the Windows SDK), sign `UniGetUI.cat` with a code-signing certificate trusted in `LocalMachine\Root`, make sure the `{889610CC-4337-4BDB-AC3B-4F21806C0BDE}_is1` uninstall key exists, and run from an elevated Windows PowerShell:

```powershell
.\Assets\Utilities\unigetui_uop_registration.ps1 -Action Register
```

Registration errors are HRESULTs in the `0x8024A3xx` range, documented in [UOPReturnCodes.md](https://github.com/microsoft/windows-uop/blob/main/docs/UOPReturnCodes.md).
