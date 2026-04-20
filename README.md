# Floorp for iOS

[![Xcode](https://img.shields.io/badge/Xcode-26.3-blue?logo=Xcode&logoColor=white)]()
[![Swift](https://img.shields.io/badge/Swift-6.2-red?logo=Swift&logoColor=white)]()
[![iOS](https://img.shields.io/badge/iOS-15.0+-green?logo=apple&logoColor=white)]()

A privacy-focused browser for iOS, based on [Firefox for iOS](https://github.com/mozilla-mobile/firefox-ios) by Mozilla.

Floorp is a community-driven project that aims to provide a customizable and privacy-respecting browsing experience. This is the iOS port of [Floorp Browser](https://floorp.app).

## Building the code

### Prerequisites

- **Xcode** (matching version used by upstream Firefox iOS)
- **Node.js** (LTS version, e.g. via Homebrew)
- **CocoaPods** or SPM (handled by Xcode)

### Quick Start

1. Clone the repository:

   ```shell
   git clone https://github.com/Floorp-Projects/floorp-ios.git
   cd floorp-ios
   ```

1. Install Node.js dependencies and bootstrap:

   ```shell
   sh ./bootstrap.sh
   ```

1. Open `Client.xcodeproj` under the `firefox-ios` folder in Xcode.

1. Select the **Fennec** scheme in Xcode.

1. Select a simulator (e.g. iPhone 17 Pro) and build with `Cmd + R`.

### Troubleshooting

- **SPM dependency issues**: Xcode → File → Packages → Reset Package Caches
- **Build errors after upstream merge**: Clean build folder (`Cmd + Shift + K`) and rebuild
- **SwiftLint not found on push**: Install via `brew install swiftlint` or push with `git push --no-verify`

## Upstream Sync

This repository tracks [mozilla-mobile/firefox-ios](https://github.com/mozilla-mobile/firefox-ios) as upstream. After merging upstream changes, the Floorp branding must be re-applied using the automated rebrand script.

### Merge Workflow

```shell
# 1. Fetch and merge upstream
git fetch upstream
git merge upstream/main

# 2. Resolve any merge conflicts

# 3. Re-apply Floorp branding (idempotent, safe to re-run)
./scripts/rebrand-to-floorp.sh

# 4. Verify the build succeeds

# 5. Commit and push
git add -A
git commit -m "feat: re-apply Floorp branding after upstream merge"
git push --no-verify origin main
```

### Rebrand Script

`scripts/rebrand-to-floorp.sh` automates all Firefox → Floorp branding changes across 44 files:

| Step | Category | Description |
|------|----------|-------------|
| 1 | Swift identifiers | Constant names (`logoFirefox` → `logoFloorp`, etc.) |
| 2 | Swift references | Usage sites across ~20 source files |
| 3 | Image set folders | xcassets `.imageset` directory renames (8 folders) |
| 4 | Contents.json | Image metadata filename references |
| 5 | Image files | PDF/PNG file renames |
| 6 | Swift files | File-level renames (`FirefoxURLBuilding.swift` → `FloorpURLBuilding.swift`) |

- **Idempotent** — already-applied changes are skipped
- **Dry-run** — `./scripts/rebrand-to-floorp.sh --dry-run` previews without modifying

> See [ADR-0007](adr/0007-upstream-merge-rebrand-strategy.md) for the full architectural decision record.

### Automatic Sync (GitHub Actions)

The [Upstream Sync](.github/workflows/upstream-sync.yml) workflow automates this process:

- **Schedule**: Every Monday at 09:00 UTC (18:00 JST)
- **Manual trigger**: Available via GitHub Actions → "Run workflow"
- **Process**: Fetches upstream → merges → runs rebrand script → creates a PR
- **Conflict handling**: If merge conflicts occur, the workflow fails and notifies maintainers

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
