# Releasing

The tool self-updates from **GitHub releases**: https://github.com/VHMSOFT/windows-nginx-updater

Each install checks `releases/latest` on startup, and if the latest **tag** is newer than the version
it recorded locally in `<toolDir>\version.txt`, it downloads the `.zip` asset and offers to apply it.
On first run (no `version.txt`) it downloads once to establish the baseline.

**The release version lives only in the git tag** - it is never committed to source, and the
manifest's `ModuleVersion` is unrelated to it.

## Cutting a release

You release by **pushing to `main`** - the version is derived from your commit message; no manual
tagging or version edits:

```bash
git commit -am "Add X"           # patch (default)
git commit -am "minor: add Y"    # minor  (keyword: minor / feat)
git commit -am "major: rework Z" # major  (keyword: major / BREAKING)
git push origin main
```

[`.github/workflows/release.yml`](.github/workflows/release.yml) computes the next version from the
latest tag + the keyword in the latest commit message, builds `windows-nginx-updater-X.Y.Z.zip`,
creates the tag `vX.Y.Z` and publishes a release whose notes are the commit subjects since the
previous release (so batching several commits in one push is fine). It can also be run manually from
the Actions tab.

Build the zip locally any time:
```powershell
pwsh -File ./build/New-Release.ps1                 # names it from the manifest ModuleVersion
pwsh -File ./build/New-Release.ps1 -Version 1.4.2  # or an explicit version
```

## Action pinning

Third-party actions are pinned to full commit SHAs (with the version in a trailing comment). To
update one, look up the new tag's commit SHA and replace both:
```bash
gh api repos/actions/checkout/git/ref/tags/<tag> --jq .object.sha   # if type is "tag", dereference it
```
For an org-wide guarantee, enable **Settings -> Actions -> General -> Require actions to be pinned
to a full-length commit SHA**.
