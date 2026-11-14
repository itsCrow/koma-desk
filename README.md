# Koma Desk

A Mac app for reading comics and writing against the pages. It opens cbz, cbr, cb7, zip, and rar archives, and folders of them, and groups a library into series. A project is a script linked to the pages on screen, with a shot list and saved panel captures.

Requires macOS 14 or later.

## Download

Grab [KomaDesk-1.1.1.zip](https://github.com/itsCrow/koma-desk/releases/download/v1.1.1/KomaDesk-1.1.1.zip). Unzip it and move **Koma Desk** to Applications.

macOS blocks the app the first time you open it, because this build is not notarized:

1. Try to open Koma Desk. macOS will refuse.
2. Open **System Settings → Privacy & Security**.
3. Click **Open Anyway**, then confirm **Open**.

That approval is only needed once. After that it launches like any other app.

## Build it yourself

Xcode or the Swift 6 command line tools are the only requirement.

```sh
git clone https://github.com/itsCrow/koma-desk.git
cd koma-desk
./build-app.sh
```

The script builds a release app at `build/Koma Desk.app` and writes `build/KomaDesk-1.1.1.zip` next to it. Open the app with:

```sh
open "build/Koma Desk.app"
```

An app you build on your own Mac is not a download, so Gatekeeper does not ask for Open Anyway.

## License

[MIT](LICENSE)
