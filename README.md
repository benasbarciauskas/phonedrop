<div align="center">

# PhoneDrop

Drag photos to your Dock and send metadata-free copies to an Android phone.

![macOS](https://img.shields.io/badge/macOS-13%2B-black)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

</div>

PhoneDrop is a small macOS Dock droplet. Drop photos onto it and PhoneDrop copies them to a temporary directory, removes EXIF and GPS metadata, then pushes them into the phone gallery with `adb`. It prefers wireless ADB over Tailscale and falls back to a connected USB device.

## Requirements

- macOS
- [Homebrew](https://brew.sh/)
- An Android phone with [Tailscale](https://tailscale.com/download/android) and Wireless debugging

Install the command-line dependencies:

```bash
brew install android-platform-tools exiftool
brew install --cask tailscale
```

## Install

Clone the repository, then run:

```bash
scripts/phonedrop.sh install
```

The installer creates `~/Applications/PhoneDrop.app`, stores its runtime script in `~/Library/Application Support/PhoneDrop`, writes configuration to `~/.config/phonedrop/config`, and enables an auto-arm LaunchAgent. Edit `PHONE_HOST` in the config if the installer could not detect it, then drag `PhoneDrop.app` to the Dock.

## One-time phone setup

1. Install Tailscale on the Mac and phone, sign in to the same tailnet, and enable always-on VPN for Tailscale on Android.
2. On Android, enable Developer options, then enable **Wireless debugging**.
3. In Wireless debugging, choose **Pair device with pairing code**. On the Mac, run the command shown by the phone:

   ```bash
   adb pair PHONE_IP:PAIRING_PORT
   ```

4. Connect once using the Wireless debugging address shown on the phone, then switch ADB to PhoneDrop's stable port:

   ```bash
   adb connect PHONE_IP:DEBUG_PORT
   adb tcpip 5555
   ```

5. Put the phone's Tailscale MagicDNS name in `~/.config/phonedrop/config` as `PHONE_HOST` and run:

   ```bash
   scripts/phonedrop.sh connect
   ```

Wireless ADB may reset after the phone reboots. Plug in one phone over USB and run `scripts/phonedrop.sh rearm`; the installed auto-arm agent will also re-enable wireless ADB when it sees that USB connection.

## Usage

Drag one or more photos onto the PhoneDrop icon in the Dock. Successful transfers appear in `DCIM/PhoneDrop` and are indexed by the Android gallery.

The script can also be used directly:

```bash
scripts/phonedrop.sh status
scripts/phonedrop.sh connect
scripts/phonedrop.sh rearm
scripts/phonedrop.sh check
scripts/phonedrop.sh push "path/to/photo.jpg" "path with spaces/another photo.heic"
```

- `status` shows configuration, dependency, auto-arm, and ADB state.
- `connect` connects to the configured phone over Tailscale.
- `rearm` uses one USB-connected phone to restore wireless ADB on port 5555.
- `check` runs local configuration and EXIF-strip checks; a phone is optional.
- `push` strips supported image files and transfers them. A reachable USB device is used if the configured wireless target is unavailable.

## Metadata removal

PhoneDrop never edits the original. For each dropped image it creates a temporary copy, runs:

```bash
exiftool -overwrite_original -all= COPY
```

and pushes only that copy. `-all=` removes EXIF, GPS, and other writable metadata. Temporary files are deleted when the command exits. Non-image files can be pushed from the CLI but are not passed through ExifTool.

## Tests

```bash
bash tests/phonedrop_test.sh
```

No phone is needed. The suite uses ADB stubs and checks configuration parsing, paths containing spaces, safe filenames, transport selection, wireless re-arming, and EXIF/GPS removal. Install ExifTool to run the real metadata assertions.

## iOS

iOS transfer is not implemented. See [the iOS transfer research spike](docs/ios-transfer-spike.md) for evaluated routes and a proposed next experiment.

## License

Apache-2.0. See [LICENSE](LICENSE).
