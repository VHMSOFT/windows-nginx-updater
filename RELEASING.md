# Releasing & mirroring

The tool self-updates from **releases** on two mirrors:

- **Forgejo (primary/source):** https://git.jfs743.com/JFs743/windows-nginx-updater
- **GitHub (mirror):** https://github.com/JFs743/windows-nginx-updater

Each install checks a mirror's `releases/latest` on startup, and if the latest **tag** is newer than
the version it recorded locally in `<toolDir>\version.txt`, it downloads the `.zip` asset and offers
to apply it. On first run (no `version.txt`) it downloads once to establish the baseline. Per-install
mirror health is recorded so a mirror that last failed is only retried as a last resort.

**The release version lives only in the git tag** — it is never committed to source, and the
manifest's `ModuleVersion` is unrelated to it. That is what lets both mirrors stay identical without
any commit-back.

## Cutting a release

You release by **pushing to `main`** — the version is derived from your commit message; no manual
tagging or version edits:

1. Commit with a bump keyword and push:
   ```bash
   git commit -am "Add X"           # patch (default)
   git commit -am "minor: add Y"    # minor  (keyword: minor / feat)
   git commit -am "major: rework Z" # major  (keyword: major / BREAKING)
   git push origin main
   ```
2. [`.forgejo/workflows/release.yml`](.forgejo/workflows/release.yml) computes the next version from
   the latest tag + the commit keyword, creates the tag `vX.Y.Z`, builds
   `windows-nginx-updater-X.Y.Z.zip`, and publishes a Forgejo release whose notes are the commit
   subjects since the previous release (so batching several commits in one push is fine).
3. The new tag is replicated to GitHub by the push mirror, triggering
   [`.github/workflows/release.yml`](.github/workflows/release.yml) to build + publish the equivalent
   GitHub release. Either workflow can also be run manually from its Actions tab.

Build the zip locally any time:
```powershell
pwsh -File ./build/New-Release.ps1                 # names it from the manifest ModuleVersion
pwsh -File ./build/New-Release.ps1 -Version 1.4.2  # or an explicit version
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
