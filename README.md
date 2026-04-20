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

This repository tracks [mozilla-mobile/firefox-ios](https://github.com/mozilla-mobile/firefox-ios) as upstream. To merge the latest upstream changes:

```shell
git fetch upstream
git merge upstream/main
# Resolve any branding conflicts, then:
git push origin main
```

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
