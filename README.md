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
      ├─ Operations.ps1  Menu.ps1
      └─ Mode.ps1  Manager.ps1       # manager mode: mode marker, instance registry, update-all
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

Every parameter is optional — the tool can be run with **no arguments**:

```powershell
powershell -ExecutionPolicy Bypass -File .\Update-Nginx.ps1
```

With no `-Root`, it resolves the nginx root in this order:

1. **Auto-detect `..\nginx.exe`** — the folder one level above the tool. Deploy the updater as a
   subfolder of the nginx root (e.g. `C:\nginx\updater\Update-Nginx.ps1`) and it finds
   `C:\nginx\nginx.exe` and uses `C:\nginx` as the root, no prompts.
2. If not found, it asks whether this is a **new install** that should be rooted at that `..`
   location (yes → scaffold there).
3. Otherwise it asks for the **path** to an nginx root elsewhere.

You can still pin the root (or anything else) explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\Update-Nginx.ps1 -Root C:\nginx
```

(`powershell.exe` is Windows PowerShell 5.1. `-ExecutionPolicy Bypass` avoids script-policy prompts
for this one run without changing machine policy.)

Handy switches (all optional — everything can also be set from the **Configure** menu):

| Switch          | Purpose                                                        |
|-----------------|----------------------------------------------------------------|
| `-Root`         | nginx root (auto-detected from `..\nginx.exe`, or asked, if omitted) |
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

The Managed menu also has **Test config** (`nginx -t` against the active binary) right next to
**Restart**. Every restart — the menu one *and* the post-upgrade prompt — **tests the config first**
and refuses if it fails: you get the failure output, then a *"force restart anyway?"* prompt that
**defaults to No**. Pass/fail is read from nginx's **exit code**, not its text, because `nginx -t`
prints `syntax is ok` on the first line even when a later error (e.g. a missing `events` section)
makes the overall test fail.

### Backup / restore conf & html

The **`b`** menu option snapshots and restores your content and configuration:

- **Back up** captures `conf\` **and** `html\` together into a timestamped snapshot under
  `<root>\backups\<yyyyMMdd-HHmmss>\`.
- **Restore** lists the snapshots (newest first) and lets you restore `conf`, `html`, or **both**
  from any of them. Restores are recursive (nested folders like `html\css\` come back intact).
- **Every restore takes a fresh `-pre-restore` backup of the current state first**, so a restore is
  always reversible. After a `conf` restore it offers to `nginx -s reload` so the change takes effect.

Backups live under `<root>\backups\` and never interfere with `versions\` or state detection; prune
old snapshots yourself whenever you like.

### The restart prompt

After an upgrade the new binary is linked but the running process is still on the old one. You get:

1. **Restart nginx now** — brief blip; new binary live immediately.
2. **Wait for the next natural restart** — zero action now; activates on the next service restart / reboot.
3. **Reload config only** (`nginx -s reload`) — re-reads `conf\` **without** swapping the binary.

> **Why not a true zero-downtime binary swap?** nginx's live binary upgrade (the Unix `USR2`/`WINCH`
> dance) is **not supported on Windows**. The symlink approach gives you the next best thing: all the
> disruptive work (download, extract, relink) happens with zero impact on the running server, and the
> only interruption is a single fast service restart you choose the timing of.

### Self-update

On startup the tool checks its own repo for a newer release and, if found, downloads it and shows a
banner with a **`u`** menu option to apply it (which replaces the tool files and relaunches). If the
check fails — offline, proxy, repo down — it **warns and continues**; nothing blocks.

- **Source:** GitHub releases of `VHMSOFT/windows-nginx-updater` (the mirror list in
  `NginxUpdater.psm1` can hold more than one; per-mirror health is recorded in
  `<toolDir>\.nginx-updater-selfupdate.json`).
- **What "newer" means:** the latest release **tag** (e.g. `v1.2.0`) vs the version this install
  recorded in `<toolDir>\version.txt` when it last updated. The release version is never committed
  to source — it lives only in the tag — so nothing has to be stamped or committed to ship.
- **First run:** with no `version.txt`, it downloads the latest once to establish the baseline (and
  records it silently if the files already match).
- **Skip it:** run with `-SkipUpdateCheck` on locked-down/offline servers.
- Staged downloads and a pre-update backup live under `<toolDir>\.update\`.

See [RELEASING.md](RELEASING.md) for cutting releases.

## Modes: managed and manager

The tool runs in one of two modes (`-Mode managed|manager`):

- **managed** (default) — everything described above: one install manages one nginx root.
- **manager** — one copy per server, at a fixed place of your choice, that keeps a **list of the
  managed installs** on that server (the list may be empty), keeps their *tool code* current and can
  update *nginx* on all of them at once.

**Choosing manager mode.** On first run with no nginx found, the prompt offers
`3) Run as the MANAGER` next to "new install" / "existing root". That choice is remembered in a
`.nginx-updater-mode` file in the tool folder (delete it, or pass `-Mode managed`, to undo). You can
also pass `-Mode manager` explicitly.

**The list** lives at `%ProgramData%\NginxUpdater\instances.json` (fixed per server, independent of
where the manager's files are). Each entry is an nginx root plus, optionally, the folder holding that
install's `Update-Nginx.ps1` (auto-suggested when it sits in or just under the root). Add/remove from
the manager menu (`a` / `d`); removing only stops tracking, nothing is deleted.

**Manager menu**

| Key | Action |
|-----|--------|
| 1 | List installs: nginx version, state, service status, channel, tool version |
| 2 | Update tool code on all installs (downloads the release once, backs up and replaces each install's files, records its `version.txt`) |
| 3 | Update nginx on all installs — stage, `nginx -t` with the new binary, repoint the link; **activates at each install's next natural restart** |
| 4 | Same as 3, then restart each service (config tested first) |
| 5 | Restart all installs now (config tested first) |

At startup it self-updates like any install and warns when tracked installs are behind the latest tool
release. For nginx updates each install stays on its own track: its saved channel (`stable`/`mainline`),
else the channel its running version belongs to (even minor = stable, odd = mainline). Only an install
with neither is skipped, unless you pick a channel for it (menu) or pass `-Channel` (CLI, overrides all). Unattended runs
never downgrade, never force a restart past a failed config test, and one install failing never stops
the others.

**Unattended (scheduled task)** — everything except `Menu` runs once without prompts and exits `0`
(ok) or `1` (something failed):

```powershell
Update-Nginx.ps1 -Mode manager -Action Status
Update-Nginx.ps1 -Mode manager -Action UpdateTools                    # tool code on all installs
Update-Nginx.ps1 -Mode manager -Action UpdateNginx                    # stage; activate on next restart
Update-Nginx.ps1 -Mode manager -Action UpdateNginx -Restart           # ...and restart now (admin)
Update-Nginx.ps1 -Mode manager -Action UpdateNginx -Channel mainline  # override every install's channel
Update-Nginx.ps1 -Mode manager -Action Restart                        # restart only (admin)
```

`UpdateNginx` and `Restart` need an elevated session.

## Deploying to ~12 servers

With manager mode: install the tool once per server in a fixed folder, run it as the manager, add each
managed install, and update everything from there (or schedule the unattended actions above).
Otherwise:

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
