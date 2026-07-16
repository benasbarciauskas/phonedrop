# iOS transfer research spike

## Goal

Find a dependable way for PhoneDrop to send an EXIF/GPS-free copy of a photo from macOS to an iPhone. This document evaluates transfer routes only; it does not propose implementation code.

Every route starts the same way: copy each source into a private temporary directory and run `exiftool -overwrite_original -all= COPY`. The original remains untouched. Only the stripped copy may leave the Mac, and the temporary directory must be removed after success, failure, or cancellation.

## Evaluation criteria

- **Tap-free-ness:** interaction required on the iPhone after initial setup.
- **Reliability:** dependence on private APIs, UI coordinates, proximity, cloud sync, or a cable.
- **Destination:** whether the result reaches Photos or only Files/an app sandbox.
- **Observability:** whether the Mac can determine completion or failure.

## Routes

### 1. AirDrop with mirroring off

**How it works.** A small signed macOS helper would pass stripped file URLs to AppKit's `NSSharingService` for `sendViaAirDrop`, or show an `NSSharingServicePicker`. A spike should also test the system `sharingservicespicker`/AirDrop command-line approaches, but treat binaries or flags without Apple documentation as private and unstable. AppKit officially supports sending file URLs through the AirDrop sharing service, but the system UI still selects the recipient.

**Tap-free-ness.** Normally the sender selects the iPhone and the recipient taps Accept. Apple documents an important exception: transfer between devices signed in to the same Apple Account is automatically accepted and saved. That makes the phone side tap-free for the primary personal-device case, though Mac-side recipient selection remains unless a supported API gains a recipient parameter.

**Reliability.** High when both devices are nearby, Wi-Fi and Bluetooth are enabled, discoverability is correct, and they share an Apple Account. Lower for unattended or cross-account use because discovery and acceptance are interactive. Public AppKit is preferable to UI scripting or undocumented CLI tools.

**EXIF integration.** Strip the temporary copy before creating the file URL passed to the sharing service.

**Blockers.** There is no documented public API for silently choosing an AirDrop recipient. Cross-account recipients must accept; newer OS versions can also require an AirDrop code for non-contacts. Destination behavior depends on the item type and receiving context, so the spike must confirm that stripped JPEG/HEIC files arrive in Photos rather than Files.

### 2. Drop into the iPhone Mirroring window

**How it works.** On macOS 15 or later with iOS 18 or later, open iPhone Mirroring, navigate to Photos or another supported target, then drag the stripped copy into the docked mirroring window. Apple documents drag and drop between Mac and supported iPhone apps.

**Tap-free-ness.** No physical iPhone tap is needed after mirroring is configured with automatic authentication. A user still opens the target app and drops the file. Accessibility automation could reduce Mac interaction, but it would be UI automation rather than a stable transfer API.

**Reliability.** High for a manual workflow on supported devices; medium-to-low if automated because window position, app state, animations, and accessibility permissions are fragile. The iPhone must be nearby and locked. iPhone Mirroring is currently unavailable in the European Union.

**EXIF integration.** Strip before initiating the drag. The pasteboard/file promise must expose only the temporary copy.

**Blockers.** Platform and regional availability, supported-app behavior, no documented programmatic drop target, and uncertain completion feedback. Test Photos, Files, Messages, and Mail separately; Apple guarantees only supported-app drag and drop, not that every drop imports into Photos.

### 3. AFC with libimobiledevice or pymobiledevice3

**How it works.** Pair a USB-connected iPhone, then use `afcclient` from libimobiledevice or `pymobiledevice3 afc` to write the stripped copy through Apple's AFC service. Base AFC exposes the device media area; House Arrest/AFC can expose the Documents directory of an installed app that supports file sharing.

**Tap-free-ness.** Tap-free after the iPhone has trusted the Mac and remains unlocked/available as required by the connection. USB is the simplest target for the first spike; network pairing adds more state.

**Reliability.** Potentially high for transferring into a known Files-compatible app sandbox over USB. It relies on reverse-engineered third-party tooling and iOS protocol compatibility, so OS updates can break it. Completion is observable from command exit status and a follow-up listing.

**EXIF integration.** Strip before AFC upload, then verify the remote filename and size.

**Blockers.** AFC is file transport, not a supported Photos-library import API. Writing into DCIM does not guarantee that Photos registers the asset, and House Arrest is limited to apps that expose file sharing. This route likely needs a companion iOS app or Shortcut to import from its Files location into Photos. Licensing also needs review before bundling: libimobiledevice is LGPL-2.1 and pymobiledevice3 is GPL-3.0.

### 4. iCloud Drive drop folder plus Photos auto-import

**How it works.** The Mac writes stripped copies to a dedicated folder in iCloud Drive. They sync into the Files app on the iPhone. A second stage imports new files into Photos and archives or deletes processed inputs.

**Tap-free-ness.** The file transfer is tap-free after iCloud Drive setup. Photos import is not: iOS does not expose a documented folder-change trigger in Shortcuts. A time-based personal automation could periodically scan the folder and run without asking, but it is polling rather than true arrival-based automation.

**Reliability.** High for eventual delivery to Files, with variable latency and dependence on iCloud storage, connectivity, and sync state. Medium for a polling import workflow because duplicate detection, partial sync, retries, and cleanup must be designed carefully.

**EXIF integration.** Strip before copying into iCloud Drive. Use a unique staging filename and move it to a processed folder only after import succeeds.

**Blockers.** No immediate documented folder-arrival automation, no direct Photos auto-import from an ordinary iCloud Drive folder, cloud latency, duplicate handling, and storage cleanup.

### 5. Shortcuts-assisted import

**How it works.** Install an iPhone Shortcut that accepts images from the share sheet or reads a known Files/iCloud Drive folder, uses **Save to Photo Album**, then removes or archives successfully imported files. The Mac-side transfer could be AirDrop, AFC to a shared app container, or iCloud Drive.

**Tap-free-ness.** One tap when launched from a share sheet, Home Screen, widget, or URL; potentially tap-free on a time-of-day automation configured to run without asking. There is no documented file-arrival trigger, so fully automatic immediate import requires polling or a companion app.

**Reliability.** High for explicit user-run imports because `Save to Photo Album` is a supported Shortcuts action. Medium for scheduled polling because execution timing and background limits are controlled by iOS.

**EXIF integration.** Prefer stripping on the Mac before transfer. The Shortcut should reject unexpected file types and import only from the dedicated staging folder.

**Blockers.** Initial Shortcut installation and Photos permission, lack of an arrival trigger, user-visible automation, and careful idempotency/cleanup requirements.

## Recommendation

Run two small proof-of-concept spikes, in this order:

1. **Mirroring off: public AppKit AirDrop to the same user's iPhone.** This is the best balance of reliability, Photos-oriented behavior, and phone-side tap-free operation because same-Apple-Account transfers are automatically accepted. Keep recipient selection visible on the Mac and reject undocumented recipient-selection hacks. Validate JPEG and HEIC destinations and capture `NSSharingServiceDelegate` completion/error callbacks.
2. **Mirroring on: manual drag of the stripped copy into Photos through iPhone Mirroring.** This is the most direct no-phone-tap route when available. Treat it as a user-assisted path, not a background automation API. Only consider Accessibility automation after a manual compatibility matrix is stable.

Keep **iCloud Drive plus a Shortcut** as the fallback for regions or machines without iPhone Mirroring and for transfers when the phone is not nearby. It is the best eventual-delivery route but not immediate or fully automatic without polling. Use **AFC** only if Files delivery is acceptable or a companion iOS importer is in scope; do not promise direct Photos import from an AFC write.

## Proposed spike matrix

Test one JPEG and one HEIC containing known GPS/EXIF tags. For each candidate, verify the source checksum is unchanged, the transferred copy has no EXIF/GPS, the destination is Photos or Files as claimed, duplicate filenames are safe, cancellation cleans temporary files, and the Mac reports a clear terminal state.

| Route | Mirroring | Phone taps after setup | Expected destination | First-spike verdict |
|---|---:|---:|---|---|
| AppKit AirDrop, same Apple Account | Off | 0 | Photos or Files; verify | Recommended |
| iPhone Mirroring drag/drop | On | 0 | Supported target app | Recommended |
| AFC / House Arrest | Off | 0 | Files/app sandbox | Conditional |
| iCloud Drive + polling Shortcut | Off | 0 after setup | Photos eventually | Fallback |
| User-run import Shortcut | Either | 1 | Photos | Reliable assisted fallback |

## Primary sources

- Apple Developer: [`NSSharingService`](https://developer.apple.com/documentation/appkit/nssharingservice), [`sendViaAirDrop`](https://developer.apple.com/documentation/appkit/nssharingservice/name/sendviaairdrop), and [`NSSharingServicePicker`](https://developer.apple.com/documentation/appkit/nssharingservicepicker)
- Apple Support: [Use AirDrop to send items to nearby Apple devices](https://support.apple.com/en-gb/guide/mac-help/-mh35868/mac)
- Apple Support: [iPhone Mirroring requirements and drag and drop](https://support.apple.com/en-us/120421)
- Apple Support: [Sync files from a Mac to an iPhone app](https://support.apple.com/guide/mac-help/sync-files-to-your-device-mchl4bd77d3a/mac)
- libimobiledevice: [`afcclient` and AFC/House Arrest](https://github.com/libimobiledevice/libimobiledevice)
- pymobiledevice3: [AFC support and CLI](https://github.com/doronz88/pymobiledevice3)
- Apple Support: [Set up iCloud Drive](https://support.apple.com/en-euro/118443)
- Apple Shortcuts User Guide: [personal automation](https://support.apple.com/guide/shortcuts/intro-to-personal-automation-apd690170742/ios) and [`Save to Photo Album`](https://support.apple.com/en-au/guide/shortcuts/apdaf74d75a5/ios)

## Implementation (PhoneDrop multi-target)

AirDrop path is implemented via `scripts/phonedrop-airdrop.swift` (`NSSharingService` `.sendViaAirDrop`). Per-target `strip_metadata` controls whether `exiftool -all=` runs on a **copy** before send; sources are never modified in place.
