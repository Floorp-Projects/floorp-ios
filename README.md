# Floorp for iOS

[![Xcode](https://img.shields.io/badge/Xcode-26.5-blue?logo=Xcode&logoColor=white)]()
[![Swift](https://img.shields.io/badge/Swift-6.2-red?logo=Swift&logoColor=white)]()
[![iOS](https://img.shields.io/badge/iOS-15.0+-green?logo=apple&logoColor=white)]()

A privacy-focused browser for iOS, based on [Firefox for iOS](https://github.com/mozilla-mobile/firefox-ios) by Mozilla.

Floorp is a community-driven project that aims to provide a customizable and privacy-respecting browsing experience. This is the iOS port of [Floorp Browser](https://floorp.app).

## Building the code

### Prerequisites

- **Xcode 26.5** (the canonical version is declared in `.xcode-version`)
- **Node.js 24.18.1** (the canonical version is declared in `.nvmrc`)
- **Swift Package Manager** (the pinned packages are resolved by Xcode)
- **SwiftLint 0.62.2** for the pre-push check (`brew install swiftlint`)

### Quick Start

Ensure `xcode-select -p` points to the intended Xcode installation. Mozilla's
[automated FXIOS setup guide](https://github.com/mozilla-mobile/firefox-ios/wiki/Automated-Project-Setup-with-FXIOS)
is also useful when working with the inherited upstream toolchain.

1. Clone the repository:

   ```shell
   git clone https://github.com/Floorp-Projects/floorp-ios.git
   cd floorp-ios
   ```

1. Install Node.js dependencies and bootstrap:

   ```shell
   ./bootstrap.sh
   ```

1. Open `Client.xcodeproj` under the `firefox-ios` folder in Xcode.

1. Select the **Fennec** scheme in Xcode.

1. Select a simulator (e.g. iPhone 17 Pro) and build with `Cmd + R`.

### Troubleshooting

- **SPM dependency issues**: Xcode → File → Packages → Reset Package Caches
- **Build errors after upstream merge**: Clean build folder (`Cmd + Shift + K`) and rebuild
- **SwiftLint not found on push**: Install it with `brew install swiftlint`; do not bypass the hook for normal changes

## CI/CD

Pull requests and pushes to `main` are checked by the Floorp iOS GitHub Actions workflow. It uses the pinned Xcode and Node.js versions, builds the `Fennec` scheme without code signing, and runs the `FloorpCI` baseline test plan.

The release and TestFlight foundation, current signing blockers, and Apple account setup checklist are documented in [docs/ci-cd.md](docs/ci-cd.md). Inherited Mozilla/Focus automation was removed from the active workflow directory; it remains recoverable from Git history if a Floorp-owned replacement is needed.

## Development Roadmap

Product work proceeds through small, testable milestones beginning with
Floorp Notes Local v1. See [docs/roadmap.md](docs/roadmap.md) for scope,
ordering, and exit criteria.

## Upstream Sync

This repository tracks [mozilla-mobile/firefox-ios](https://github.com/mozilla-mobile/firefox-ios) as upstream. After merging upstream changes, the Floorp branding must be re-applied using the automated rebrand script.

### Merge Workflow

```shell
# 1. Fetch and merge upstream
git fetch upstream
git merge upstream/main

# 2. Resolve ordinary conflicts. The reviewed localization resolver may handle
#    covered .strings conflicts; it refuses every path outside its policy.
node scripts/l10n/floorp-l10n-overlay.mjs resolve-merge --write --stage

# 3. Re-apply code, asset, and reviewed localization branding
./scripts/rebrand-to-floorp.sh
node scripts/l10n/floorp-l10n-overlay.mjs apply --source-ref upstream/main --write
node scripts/l10n/floorp-l10n-overlay.mjs verify --source-ref upstream/main

# 4. Verify the build succeeds

# 5. Commit, push a branch, and open a pull request
git add -A
git commit -m "feat: re-apply Floorp branding after upstream merge"
git push -u origin HEAD
```

### Rebrand Script

`scripts/rebrand-to-floorp.sh` automates all Firefox → Floorp branding changes across 44 files:

| Step | Category          | Description                                                                 |
| ---- | ----------------- | --------------------------------------------------------------------------- |
| 1    | Swift identifiers | Constant names (`logoFirefox` → `logoFloorp`, etc.)                         |
| 2    | Swift references  | Usage sites across ~20 source files                                         |
| 3    | Image set folders | xcassets `.imageset` directory renames (8 folders)                          |
| 4    | Contents.json     | Image metadata filename references                                          |
| 5    | Image files       | PDF/PNG file renames                                                        |
| 6    | Swift files       | File-level renames (`FirefoxURLBuilding.swift` → `FloorpURLBuilding.swift`) |

- **Idempotent** — already-applied changes are skipped
- **Dry-run** — `./scripts/rebrand-to-floorp.sh --dry-run` previews without modifying

> See [ADR-0007](adr/0007-upstream-merge-rebrand-strategy.md) for the full architectural decision record.

Localized product names use a separate, reviewed overlay. It changes only 4,032 allowlisted semantic values in 844 resources, protects Mozilla service names, and fails closed when upstream text no longer matches the approved transformation. See [docs/l10n-overlay.md](docs/l10n-overlay.md) for extraction, verification, and merge-resolution commands. Generated localization resources remain tracked so Xcode and translation tooling continue to see ordinary Apple resources.

### Automatic Sync (GitHub Actions)

The [Upstream Sync](.github/workflows/upstream-sync.yml) workflow automates this process:

- **Schedule**: Every Monday at 09:00 UTC (18:00 JST)
- **Manual trigger**: Available via GitHub Actions → "Run workflow"
- **Process**: Fetches upstream → validates the reviewed localization policy → merges → restores Floorp-owned automation → reapplies both branding layers → opens a draft PR → dispatches CI
- **Conflict handling**: Protected automation is restored from Floorp; covered localization conflicts are regenerated from upstream; every other conflict aborts with a diagnostic artifact
- **Generated branch**: `automation/upstream-sync` is replaced by each run, so fixes belong on a normal branch or in the sync tooling—not directly on the generated branch

## Contributing

We welcome contributions! Please feel free to submit Pull Requests or open Issues.

- [Report a bug](https://github.com/Floorp-Projects/floorp-ios/issues/new?template=bug_report.md)
- [Request a feature](https://github.com/Floorp-Projects/floorp-ios/issues/new?template=feature_request.md)

## Project Structure

```
floorp-ios/
├── README.md          # This file
├── .gitignore
├── bootstrap.sh       # Project setup script
├── firefox-ios/       # Main application source
│   ├── Client/        # App code, assets, configuration
│   ├── Shared/        # Shared libraries (Strings.swift, etc.)
│   ├── WidgetKit/     # Home screen widgets
│   ├── Extensions/    # Share & Action extensions
│   └── ...
└── focus-ios/         # Focus browser (upstream, not actively modified)
```

## License

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/
