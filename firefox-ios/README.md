# Floorp for iOS — Application Source

This directory contains the Floorp for iOS application source code.

For build prerequisites (Xcode, Swift, iOS versions) and project overview, see the root [README](../README.md).

## Quick Build

1. From the **project root**, install dependencies:

   ```shell
   sh ./bootstrap.sh
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

This reduces the total possible number of User Scripts down to four. The compiled output from concatenating and minifying the User Scripts placed in these folders resides in `/Client/Assets` and is named accordingly:

- `AllFramesAtDocumentEnd.js`
- `AllFramesAtDocumentStart.js`
- `MainFrameAtDocumentEnd.js`
- `MainFrameAtDocumentStart.js`

To simplify the build process, these compiled files are checked-in to this repository.

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
