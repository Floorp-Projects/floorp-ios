# 7. Upstream Merge & Rebrand Strategy

Date: 2026-04-21

## Status

Accepted

## Context

Floorp for iOS is a fork of [Mozilla Firefox for iOS](https://github.com/mozilla-mobile/firefox-ios). The upstream repository is actively developed and receives frequent updates (new features, bug fixes, security patches). To keep Floorp iOS up-to-date, we need a reliable strategy to merge upstream changes while preserving our custom branding.

The branding changes (Firefox → Floorp) span multiple layers:

- **Swift identifiers** — constant names, variable names, method names, protocol/struct/class names
- **Swift source references** — usage sites across ~20 source files
- **xcassets image sets** — folder renames (e.g. `faviconFox.imageset` → `floorpFavicon.imageset`)
- **Contents.json references** — filename entries inside image set metadata
- **Image file renames** — actual PDF/PNG file renames
- **Swift file renames** — file-level renames (e.g. `FirefoxURLBuilding.swift` → `FloorpURLBuilding.swift`)

These changes are spread across 44 files in 5 top-level directories (`BrowserKit/`, `firefox-ios/`, `focus-ios/`, `SampleComponentLibraryApp/`, `scripts/`). Without automation, manually re-applying branding after each upstream merge would be error-prone and time-consuming.

## Decision

We adopt a **script-based idempotent rebrand strategy** using `scripts/rebrand-to-floorp.sh`.

### Git Remote Setup

```
origin    → https://github.com/Floorp-Projects/floorp-ios/
upstream  → https://github.com/mozilla-mobile/firefox-ios.git
```

### Merge Workflow

```shell
# 1. Fetch latest upstream
git fetch upstream

# 2. Merge upstream into main
git merge upstream/main

# 3. Resolve any merge conflicts (if any)

# 4. Re-apply branding
./scripts/rebrand-to-floorp.sh

# 5. Verify the build
# (Build via Xcode or MCP)

# 6. Commit and push
git add -A
git commit -m "feat: re-apply Floorp branding after upstream merge"
git push --no-verify origin main
```

### Script Design Principles

1. **Idempotent** — Safe to run multiple times. Already-renamed items are skipped with `≈` markers.
2. **Ordered steps** — Operations execute in dependency order (identifiers → references → folder renames → file renames).
3. **Dry-run support** — `--dry-run` flag previews all changes without modifying files.
4. **Progress feedback** — Each step reports `✓` (success), `≈` (already done), or `⚠` (not found).

### What the Script Covers (6 Steps)

| Step | Category | Files |
|------|----------|-------|
| 1 | Swift identifier constants | `StandardImageIdentifiers.swift`, `ImageIdentifiers.swift`, `OnboardingImageIdentifiers.swift` |
| 2 | Swift source references | 19 source files across BrowserKit, firefox-ios, focus-ios, tests |
| 3 | xcassets image set folder renames | 8 folders (faviconFox, logoFirefoxLarge, firefoxLoader, firefox-jp, open_in_firefox_icon) |
| 4 | Contents.json filename references | 6 metadata files |
| 5 | Image file renames | 6 PDF/PNG files |
| 6 | Swift file renames | 2 files (FirefoxURLBuilding.swift, FirefoxURLBuilderTests.swift) |

## Consequences

### Positive

- **Reproducible branding** — Every upstream merge produces identical branding changes.
- **Reduced merge friction** — No need to manually track which files need renaming.
- **Easy verification** — `--dry-run` allows previewing changes before applying.
- **Tested** — The script was verified against a clean upstream checkout (44 files, 66 insertions, 66 deletions) and produced a successful build.

### Negative

- **Maintenance burden** — If upstream adds new Firefox-branded identifiers or assets, the script must be updated.
- **No conflict detection** — The script blindly replaces; it does not detect merge conflicts in renamed files.
- **Dry-run limitation** — Steps 4-5 show false-positive warnings in dry-run mode because folder renames (Step 3) are not executed, so subsequent file operations cannot find the new paths.

### Mitigations

- Always build the project after running the script to catch any missed renames.
- Review `git diff` output before committing.
- Update the script promptly when upstream introduces new branding-related code.
