# Hop

Reliable iPad <-> Windows file transfer over Wi-Fi.
The iPad app runs a local server and serves a web page; open the address in any PC browser.

## Build
Push to GitHub. The workflow in `.github/workflows/build.yml` generates the Xcode project
with XcodeGen, builds an unsigned `Hop.ipa`, and attaches it to a GitHub Release.
Sign and install it the same way as your other app.

## Use
1. Open Hop on the iPad, tap Start server.
2. On the PC (same Wi-Fi), open the address shown (or scan the QR code).
3. Drop files on the page to send them to the iPad, or click the arrow next to a file to download it.
Files live in the app's Documents folder (visible in the Files app under On My iPad > Hop).
