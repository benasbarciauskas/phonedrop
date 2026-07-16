<div align="center">

# PhoneDrop

Drag photos into a per-phone drop folder (or onto a Dock droplet) and send them to Android or iOS — optionally metadata-free.

![macOS](https://img.shields.io/badge/macOS-13%2B-black)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

</div>

PhoneDrop is a multi-target macOS drop system. Each phone gets its own watched folder under `~/PhoneDrop/<name>/`. Drop a photo into that folder and PhoneDrop auto-sends it to the right device, then archives (or deletes) the source. Android targets use wireless `adb` over Tailscale; iOS targets use AirDrop via AppKit `NSSharingService`. Metadata stripping is per-target and always runs on a **copy** — originals in the drop folder are never edited in place.

## Requirements

- macOS
- [Homebrew](https://brew.sh/)
- **Android phones:** [Tailscale](https://tailscale.com/download/android) + Wireless debugging + `adb`
- **iOS phones:** same Apple Account (auto-accept) or AirDrop set to Contacts/Everyone; iPhone awake/unlocked nearby
- Optional: [ExifTool](https://exiftool.org/) (required only when a target has `strip_metadata=true`)

Install CLI dependencies:

```bash
brew install android-platform-tools exiftool
brew install --cask tailscale   # Android path only
```

## Install

```bash
scripts/phonedrop.sh install
```

The installer:

1. Writes global config to `~/.config/phonedrop/config` (legacy single-host fields + tool paths)
2. Uses / migrates `~/.config/phonedrop/targets.conf` for named phones
3. Creates per-target drop folders (`~/PhoneDrop/<name>/` + `sent/`)
4. Installs a launchd **WatchPaths** agent per target (`com.phonedrop.watch.<name>`)
5. Installs the wireless adb auto-arm agent (Android)
6. Copies the logic script + AirDrop helper into `~/Library/Application Support/PhoneDrop`
7. Compiles the optional Dock droplet to `~/Applications/PhoneDrop.app`

```bash
scripts/phonedrop.sh uninstall   # removes launchd agents; keeps config + folders
```

## Multi-target model

### Config

Phones live in `~/.config/phonedrop/targets.conf` (and optional `targets.d/*.conf`):

```ini
[pixel]
platform=android
phone_host=android-phone
adb_port=5555
dest=/sdcard/DCIM/PhoneDrop/
strip_metadata=true
drop_folder=~/PhoneDrop/pixel
on_send=archive

[iphone]
platform=ios
airdrop_recipient=Benas’s iPhone
strip_metadata=true
drop_folder=~/PhoneDrop/iphone
on_send=archive
```

| Field | Meaning |
|---|---|
| `platform` | `android` or `ios` |
| `phone_host` / `adb_port` / `dest` / `serial` | Android adb transport |
| `airdrop_recipient` | iOS AirDrop device/contact name |
| `strip_metadata` | `true` (default) or `false` |
| `drop_folder` | Watched inbox for this phone |
| `on_send` | `archive` → `drop_folder/sent/` (default) or `delete` |

**Backward compatible:** a lone `PHONE_HOST` in `~/.config/phonedrop/config` is still treated as a single Android target (`default`). `install` can migrate it into `targets.conf`.

### Manage phones

```bash
scripts/phonedrop.sh add-phone --name pixel --platform android --host android-phone
scripts/phonedrop.sh add-phone --name iphone --platform ios --recipient "Benas’s iPhone"
scripts/phonedrop.sh add-phone --name raw --platform android --host phone --no-strip
scripts/phonedrop.sh remove-phone pixel
scripts/phonedrop.sh list
scripts/phonedrop.sh config            # global + all targets
scripts/phonedrop.sh config iphone     # one target
```

`add-phone` / `remove-phone` refresh that target’s WatchPaths launchd agent when PhoneDrop is installed.

### Per-phone drop folders (primary UX)

```
~/PhoneDrop/pixel/     → auto-sends to Android target "pixel"
~/PhoneDrop/iphone/    → auto-sends to iOS target "iphone" via AirDrop
```

Drop a photo in; launchd fires `phonedrop.sh watch <name>`; the file is sent and then moved to `sent/` (or deleted). Different folders → different phones.

### CLI + Dock droplet

```bash
scripts/phonedrop.sh push --target pixel "path/to/photo.jpg"
scripts/phonedrop.sh push --target iphone "My Photos/vacation.heic"
scripts/phonedrop.sh push "photo.jpg"   # single target or legacy PHONE_HOST
```

The Dock droplet (`PhoneDrop.app`) still works for the default/legacy Android path: drag photos onto the icon.

## Android path (adb)

Same as before: strip (if enabled) on a temp copy, `adb push` into `DEST`, media-scan broadcast. Prefers `phone_host:adb_port` over Tailscale; falls back to a single USB device.

One-time phone setup:

1. Tailscale on Mac + phone, same tailnet, always-on VPN on Android.
2. Developer options → **Wireless debugging** → pair with code (`adb pair …`).
3. `adb connect PHONE_IP:DEBUG_PORT` then `adb tcpip 5555`.
4. Put the MagicDNS name in the target’s `phone_host` (or legacy `PHONE_HOST`).
5. `scripts/phonedrop.sh connect` / `rearm` after reboots. Auto-arm helps when USB is plugged in.

## iOS path (AirDrop)

For `platform=ios`, PhoneDrop:

1. Copies each file to a private temp dir
2. Optionally strips metadata on that copy (`strip_metadata=true`)
3. Hands the copy to **`NSSharingService(named: .sendViaAirDrop)`** via `scripts/phonedrop-airdrop.swift`
4. If `airdrop_recipient` is set, best-effort System Events scripting clicks that peer in the AirDrop browser (Accessibility permission may be required)

**Same-Apple-Account devices auto-accept** on the iPhone (Apple’s documented exception). Cross-account transfers need an Accept tap (and may show an AirDrop code).

Practical requirements:

- iPhone nearby, awake/unlocked (or recently unlocked)
- Wi-Fi + Bluetooth on
- AirDrop: same Apple Account, or Contacts Only / Everyone
- First run may prompt for Automation/Accessibility if recipient auto-click is used

There is no documented public API to silently pick an AirDrop recipient; the spike recommendation is public AppKit AirDrop with same-account auto-accept. See [docs/ios-transfer-spike.md](docs/ios-transfer-spike.md).

## Toggleable metadata strip

Per target, `strip_metadata=true|false` (default **true**).

When **true**, PhoneDrop copies the source, runs:

```bash
exiftool -overwrite_original -all= COPY
```

and sends only the copy. When **false**, the untouched copy is sent as-is. The file in the drop folder (or CLI path) is **never** modified in place; after a successful folder send it is archived or deleted according to `on_send`.

## Other commands

```bash
scripts/phonedrop.sh status
scripts/phonedrop.sh connect [name]
scripts/phonedrop.sh rearm [name]
scripts/phonedrop.sh check
scripts/phonedrop.sh watch [name]    # used by launchd; safe to run by hand
```

## Tests

```bash
bash tests/phonedrop_test.sh
```

No phone required. Stubs cover adb + AirDrop. Assertions include multi-target `targets.conf` parsing, per-target strip on/off, arg/path quoting with spaces, folder→target routing, and EXIF/GPS strip behaviour.

## License

Apache-2.0. See [LICENSE](LICENSE).
