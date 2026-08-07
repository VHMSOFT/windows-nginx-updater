# Releasing & mirroring

The tool self-updates from **GitHub releases** on two mirrors:

- **Forgejo (primary/source):** https://git.jfs743.com/JFs743/windows-nginx-updater
- **GitHub (mirror):** https://github.com/JFs743/windows-nginx-updater

Each install checks a mirror's `releases/latest` on startup, downloads the `.zip` asset if it is
newer than the installed `ModuleVersion`, and offers to apply it. Per-install mirror health is
recorded so a mirror that last failed is only retried as a last resort.

## Cutting a release

1. Bump `ModuleVersion` in [`NginxUpdater/NginxUpdater.psd1`](NginxUpdater/NginxUpdater.psd1).
2. Commit, then tag it to match and push the tag:
   ```bash
   git commit -am "Release vX.Y.Z"
   git tag vX.Y.Z
   git push origin main --tags
   ```
3. On the tag push, each host builds the same zip and publishes its own release:
   - Forgejo Actions → [`.forgejo/workflows/release.yml`](.forgejo/workflows/release.yml)
   - GitHub Actions → [`.github/workflows/release.yml`](.github/workflows/release.yml)

The release **tag must equal `ModuleVersion`** (a leading `v` is fine — the updater strips it).
The asset is `windows-nginx-updater-<version>.zip`; the updater just picks the first `.zip` asset.

Build the zip locally any time:
```powershell
pwsh -File ./build/New-Release.ps1        # writes dist/windows-nginx-updater-<version>.zip
```

## One-time: mirror code + tags to GitHub

Forgejo replicates the repo (commits **and tags**) to GitHub via a **push mirror**; the mirrored
tag then triggers the GitHub release workflow. Set it up once (requires a GitHub token — do this
yourself, it is not in this repo):

1. Create the empty GitHub repo `JFs743/windows-nginx-updater`.
2. Create a GitHub **fine-grained PAT** with `Contents: read/write` on that repo.
3. In Forgejo: **Settings → Repository → Mirror Settings → Push Mirror**, add
   `https://github.com/JFs743/windows-nginx-updater.git`, authenticate with your GitHub username +
   the PAT, and enable **"Sync when new commits are pushed"** (and tags).
4. Add the same PAT as a GitHub Actions secret only if the workflow needs it (the default
   `GITHUB_TOKEN` is enough for `softprops/action-gh-release`).

Push mirroring covers git only — **releases are built independently on each host** by the two
workflows above, so both mirrors end up with equivalent release assets.

## Manual release fallback

If a host's Actions runner is unavailable, build locally and upload the zip to that host's release
for the tag through its web UI:

```powershell
pwsh -File ./build/New-Release.ps1
# then attach dist/windows-nginx-updater-<version>.zip to the vX.Y.Z release
```
