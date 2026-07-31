# nginx-updater (Windows)

A numbered-menu PowerShell tool that installs, upgrades, migrates and rolls back nginx on
Windows **without touching your `conf\` or `html\`**. The active `nginx.exe` is a symbolic link
pointing at a specific build under `versions\<version>\`. Upgrades are staged and the symlink is
repointed **while nginx keeps running**, so the new binary goes live on the **next restart** —
and the tool asks whether to restart now or wait for the next natural restart.

Run it locally on each server (matches your current manual per-server flow).

## Project layout

The logic lives in a PowerShell module; `Update-Nginx.ps1` is a thin launcher that imports it.

```
nginx-updater/
├─ Update-Nginx.ps1                  # launcher: imports the module and runs the menu
└─ NginxUpdater/                     # the module (ship this folder alongside the launcher)
   ├─ NginxUpdater.psd1              # manifest (exports only Invoke-NginxUpdater)
   ├─ NginxUpdater.psm1             # loader: module-scope state + dot-sources the files below
   ├─ Public/
   │  └─ Invoke-NginxUpdater.ps1    # the one public command (the menu entry point)
   └─ Private/                       # internal functions, grouped by area
      ├─ Console.ps1   Elevation.ps1  Config.ps1   State.ps1
      ├─ Download.ps1  Symlink.ps1    Service.ps1  Validation.ps1
      └─ Operations.ps1  Menu.ps1
```

Deploy by copying `Update-Nginx.ps1` **and** the `NginxUpdater\` folder together (keep them
side by side — the launcher finds the module via its own folder). You can also
`Import-Module .\NginxUpdater\NginxUpdater.psd1` and call `Invoke-NginxUpdater` directly.

## Managed layout

```
C:\nginx\                     <- root you point the tool at
├─ nginx.exe                  <- SYMLINK -> versions\1.30.4\nginx.exe   (the "active" binary)
├─ conf\                      <- YOUR config (never touched by upgrades)
├─ html\                      <- YOUR content (never touched by upgrades)
├─ logs\  temp\               <- shared, live
├─ versions\
│   ├─ 1.28.0\nginx.exe ...   <- previous build (kept for instant rollback)
│   └─ 1.30.4\nginx.exe ...   <- current build
└─ .nginx-updater.json        <- per-root settings (service name, nssm path, channel)
```

nginx is always launched with an explicit prefix — `nginx.exe -p "C:\nginx"` — so every version
uses the **root** `conf\` and `html\`, never the defaults bundled inside `versions\`.

## Requirements

- **Windows PowerShell 5.1** — the version built into Windows Server. Nothing to install. It also
  runs unchanged on PowerShell 7+ if you happen to have it.
- **Administrator** — needed to create symlinks and manage the service. The tool detects this and
  offers to relaunch elevated. (Alternatively, enabling Windows *Developer Mode* allows non-admin
  symlink creation, but service control still needs admin.)
- **NSSM** (`nssm.exe`) — only required to *create* a service during Scaffold. Restart/start/stop
  use the standard Windows Service APIs, so an already-installed NSSM (or any wrapper) service just
  works. Get it from https://nssm.cc (drop `nssm.exe` on the server and point the tool at it via
  the Configure menu if it isn't on `PATH`).

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\Update-Nginx.ps1 -Root C:\nginx
```

(`powershell.exe` is Windows PowerShell 5.1. `-ExecutionPolicy Bypass` avoids script-policy prompts
for this one run without changing machine policy.)

Handy switches (all optional — everything can also be set from the **Configure** menu):

| Switch          | Purpose                                                        |
|-----------------|----------------------------------------------------------------|
| `-Root`         | nginx root folder to manage (prompts if omitted)               |
| `-ServiceName`  | Windows service name (auto-detected/created if omitted)        |
| `-NssmPath`     | Path to `nssm.exe` (auto-detected if omitted)                  |
| `-Channel`      | `stable` \| `mainline` \| `ask` (default `ask`)                |
| `-Status`       | Print state + diagnostics and exit (no menu)                   |

The menu adapts to what it finds in the root:

- **Empty folder → Scaffold.** Downloads the chosen version, lays down the managed layout, seeds
  `conf\`/`html\` from nginx's defaults, links `nginx.exe`, and optionally creates the NSSM service.
- **Manual install → Migrate.** Detects the running version (`nginx -v`), moves the existing
  `nginx.exe` into `versions\<ver>\`, drops a symlink in its place, and **leaves `conf\`/`html\`/
  `logs\` exactly where they are**. Adopts an existing service if it finds one. The move works even
  while nginx is running (Windows lets you rename a running `.exe` on the same volume).
- **Managed install → Update / Rollback.** Stages a new version, validates your live config against
  the *new* binary (`nginx -t`), repoints the symlink, then prompts for restart. "Switch active
  version" repoints to any already-staged build for instant rollback.

### The restart prompt

After an upgrade the new binary is linked but the running process is still on the old one. You get:

1. **Restart nginx now** — brief blip; new binary live immediately.
2. **Wait for the next natural restart** — zero action now; activates on the next service restart / reboot.
3. **Reload config only** (`nginx -s reload`) — re-reads `conf\` **without** swapping the binary.

> **Why not a true zero-downtime binary swap?** nginx's live binary upgrade (the Unix `USR2`/`WINCH`
> dance) is **not supported on Windows**. The symlink approach gives you the next best thing: all the
> disruptive work (download, extract, relink) happens with zero impact on the running server, and the
> only interruption is a single fast service restart you choose the timing of.

## Deploying to ~12 servers

Copy `Update-Nginx.ps1` to each server (or a share) and run it locally per your current workflow —
e.g. `\\share\tools\Update-Nginx.ps1 -Root C:\nginx`. Settings persist per-root in
`.nginx-updater.json`, so after the first run each server remembers its service name, nssm path, and
channel.

## Safety notes

- Upgrades **never** write to `conf\` or `html\`. Only `versions\` and the `nginx.exe` symlink change.
- Old versions stay under `versions\` until you delete them — rollback is instant via **Switch active version**.
- Downloads come over HTTPS from `nginx.org`. If `gpg` is on PATH, the tool also verifies nginx's
  PGP signature (best-effort; import the nginx signing key to make it authoritative).
- Version discovery reads `nginx.org/en/download.html`: **stable = highest even-minor** (e.g. 1.30.x),
  **mainline = highest odd-minor** (e.g. 1.31.x).
