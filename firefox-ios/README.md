# Floorp for iOS — Application Source

This directory contains the Floorp for iOS application source code.

For build prerequisites (Xcode, Swift, iOS versions) and project overview, see the root [README](../README.md).

## Quick Build

1. From the **project root**, install dependencies:

   ```shell
   ./bootstrap.sh
   ```

1. Open `Client.xcodeproj` in this folder with Xcode.

1. Select the **Fennec** scheme.

1. Build and run with `Cmd + R`.

> ⚠️ SPM issues? Try: Xcode → File → Packages → Reset Package Caches

## Getting Involved

Contributions are welcome! Visit the [Floorp iOS repository](https://github.com/Floorp-Projects/floorp-ios) to open issues or submit pull requests.

## Building User Scripts

User Scripts (JavaScript injected into the `WKWebView`) are compiled, concatenated, and minified using [webpack](https://webpack.js.org/). User Scripts to be aggregated are placed in the following directories:

```none
/Client
|-- /Frontend
    |-- /UserContent
        |-- /UserScripts
            |-- /AllFrames
            |   |-- /AtDocumentEnd
            |   |-- /AtDocumentStart
            |-- /MainFrame
                |-- /AtDocumentEnd
                |-- /AtDocumentStart
```

This reduces the total possible number of User Scripts down to four. Bootstrap generates the ignored compiled output in `/Client/Assets`, with names including:

- `AllFramesAtDocumentEnd.js`
- `AllFramesAtDocumentStart.js`
- `MainFrameAtDocumentEnd.js`
- `MainFrameAtDocumentStart.js`

These compiled files are build artifacts and are not committed. Run the root `bootstrap.sh` after a clean checkout; GitHub Actions and Xcode Cloud do this automatically.

To start a watcher that will compile the User Scripts on save, run the following `npm` command in the root directory of the project:

```shell
npm run dev
```

⚠️ Note: `npm run dev` will build the JS bundles in development mode with source maps, which allows tracking down lines in the source code for debugging.

To create a production build of the User Scripts, run the following `npm` command in the root directory of the project:

```shell
npm run build
```

## Updating License Acknowledgements

In the app, the Settings > Licenses screen credits open source packages we use to build Firefox for iOS.

If you add a new third party package or resource, please update the credits. Follow the instructions in our `license_plist_config.yml` file.
