#!/usr/bin/swift
// PhoneDrop AirDrop transport
// Uses AppKit NSSharingService(named: .sendViaAirDrop) — the public API path
// recommended by docs/ios-transfer-spike.md.
//
// Usage:
//   phonedrop-airdrop.swift [--recipient "Device Name"] file1 [file2 ...]
//
// Notes:
// - Same-Apple-Account devices typically auto-accept on the iPhone.
// - The iPhone should be awake/unlocked nearby, Wi-Fi + Bluetooth on, and
//   AirDrop set to Contacts Only or Everyone (or same Apple Account).
// - Optional --recipient uses Accessibility (System Events) to click the named
//   peer in the AirDrop browser after the share sheet opens. Grant Accessibility
//   to Terminal/the caller if recipient selection should be automated.

import AppKit
import Foundation

final class ShareDelegate: NSObject, NSSharingServiceDelegate {
    private let lock = NSLock()
    private var finished = false
    var error: Error?

    func markDone(error: Error? = nil) {
        lock.lock()
        self.error = error
        finished = true
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        markDone(error: error)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        markDone()
    }

    // Older/alternate delegate signatures used by some SDK versions
    @objc func sharingService(_ sharingService: NSSharingService!, didFailToShareItems items: [Any]!, error: NSError!) {
        markDone(error: error)
    }

    @objc func sharingService(_ sharingService: NSSharingService!, didShareItems items: [Any]!) {
        markDone()
    }
}

func usageAndExit() -> Never {
    fputs("Usage: phonedrop-airdrop.swift [--recipient NAME] <file> [file ...]\n", stderr)
    exit(2)
}

var recipient: String?
var files: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    if a == "--recipient" || a == "-r" {
        i += 1
        guard i < args.count else { usageAndExit() }
        recipient = args[i]
    } else if a == "--help" || a == "-h" {
        usageAndExit()
    } else if a.hasPrefix("-") {
        fputs("Unknown option: \(a)\n", stderr)
        usageAndExit()
    } else {
        files.append(a)
    }
    i += 1
}

guard !files.isEmpty else { usageAndExit() }

var urls: [URL] = []
for path in files {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
        fputs("phonedrop-airdrop: not a file: \(path)\n", stderr)
        exit(1)
    }
    urls.append(url)
}

guard let service = NSSharingService(named: .sendViaAirDrop) else {
    fputs("phonedrop-airdrop: AirDrop sharing service unavailable\n", stderr)
    exit(1)
}

// Bring a minimal app context online so the share UI can present.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = ShareDelegate()
service.delegate = delegate

// Kick off AirDrop UI on the main thread.
DispatchQueue.main.async {
    app.activate(ignoringOtherApps: true)
    if !service.canPerform(withItems: urls) {
        fputs("phonedrop-airdrop: cannot AirDrop these items\n", stderr)
        delegate.markDone(error: NSError(domain: "phonedrop", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "canPerform(withItems:) returned false"
        ]))
        return
    }
    service.perform(withItems: urls)

    // Optional: click the named recipient in the AirDrop browser via System Events.
    // Requires Accessibility permission. Best-effort; same-account auto-accept still
    // applies once the peer is selected.
    if let recipient, !recipient.isEmpty {
        DispatchQueue.global(qos: .userInitiated).async {
            // Give the AirDrop browser a moment to appear.
            Thread.sleep(forTimeInterval: 0.8)
            let script = """
            on run argv
              set peerName to item 1 of argv
              set deadline to (current date) + 15
              repeat while (current date) < deadline
                try
                  tell application "System Events"
                    -- AirDrop UI can appear under several process names across macOS versions
                    set procs to {"SharingUIService", "sharingd", "ViewBridgeAuxiliary", "Finder"}
                    repeat with procName in procs
                      if exists process procName then
                        tell process procName
                          set uiElems to entire contents
                          repeat with el in uiElems
                            try
                              set en to name of el
                              if en is peerName or en contains peerName then
                                try
                                  click el
                                  return "clicked:" & en
                                end try
                              end if
                            end try
                          end repeat
                        end tell
                      end if
                    end repeat
                  end tell
                end try
                delay 0.4
              end repeat
              return "not-found"
            end run
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-", recipient]
            let inPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                if let data = script.data(using: .utf8) {
                    inPipe.fileHandleForWriting.write(data)
                    inPipe.fileHandleForWriting.closeFile()
                }
            } catch {
                // Best-effort only.
            }
        }
    }
}

// Spin the main run loop until the share completes, fails, or times out.
let timeout: TimeInterval = 180
let started = Date()
while !delegate.isDone {
    if Date().timeIntervalSince(started) > timeout {
        fputs("phonedrop-airdrop: timed out waiting for AirDrop completion\n", stderr)
        exit(1)
    }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
}

if let error = delegate.error {
    fputs("phonedrop-airdrop: \(error.localizedDescription)\n", stderr)
    exit(1)
}

fputs("phonedrop-airdrop: sent \(urls.count) file(s)\n", stderr)
exit(0)
