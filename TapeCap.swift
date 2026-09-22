// TapeCap.swift — native single-window front-end for xingrz/tapecap
//
// A real AppKit app: a device picker, a format selector, action buttons, and a
// colored, streaming log pane — all in one window (Rom Dump / GopForge-style).
// It reimplements NONE of tapecap's logic: it runs the real `tapecap` binary
// (https://github.com/xingrz/tapecap) and streams its output. Colors are applied
// here from the ✓ ✗ ! » markers this app prints and from tapecap's own status
// and timecode lines, so tapecap needs no ANSI/tty tricks.
//
// Built by build-app.command with:  swiftc -O -o TapeCap TapeCap.swift -framework AppKit
// SPDX-License-Identifier: MIT

import AppKit

final class Controller: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var binaryBtn: NSButton!
    var binaryLabel: NSTextField!
    var format: NSSegmentedControl!
    var refreshBtn, infoBtn, captureBtn, stopBtn, cueBtn, jogBtn, windBtn, revealBtn: NSButton!
    var devicePopup: NSPopUpButton!
    var durationField: NSTextField!
    var spinner: NSProgressIndicator!
    var statusLabel: NSTextField!

    var tapecapPath: String?
    var guids: [String] = []
    var captureOut: URL?
    var proc: Process?
    var running = false
    var capturing = false
    var lineBuf = ""
    var lineSink: ((String) -> Void)?

    let mono = NSFont(name: "Menlo", size: 12) ?? NSFont.userFixedPitchFont(ofSize: 12)!

    // MARK: launch
    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildWindow()
        appendLine("TapeCap — a front-end for tapecap (raw DV / HDV FireWire capture).", .secondaryLabelColor)
        detectTapecap()
        setBinaryLabel()
        if tapecapPath == nil {
            appendLine("✗ tapecap not found on PATH. Click “tapecap…” to locate the binary.", .systemRed)
            appendLine("» Build it from https://github.com/xingrz/tapecap  (git clone && make).", .systemBlue)
        } else {
            appendLine("» Select a device with Refresh, then Info or Capture.", .systemBlue)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "Quit TapeCap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        NSApp.mainMenu = main
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "TapeCap"
        window.center()
        let content = NSView(frame: window.contentView!.bounds)
        window.contentView = content

        func button(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        func caption(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.textColor = .secondaryLabelColor
            t.translatesAutoresizingMaskIntoConstraints = false
            return t
        }

        // row 1: binary + format
        binaryBtn = button("tapecap…", #selector(chooseBinary))
        binaryLabel = NSTextField(labelWithString: "Locating tapecap…")
        binaryLabel.textColor = .secondaryLabelColor
        binaryLabel.lineBreakMode = .byTruncatingMiddle
        binaryLabel.translatesAutoresizingMaskIntoConstraints = false
        let formatCaption = caption("Format:")
        format = NSSegmentedControl(labels: ["Auto", "DV", "HDV"], trackingMode: .selectOne, target: nil, action: nil)
        format.selectedSegment = 0
        format.translatesAutoresizingMaskIntoConstraints = false

        // row 2: refresh + device + duration
        refreshBtn = button("Refresh Devices", #selector(refresh))
        devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        devicePopup.translatesAutoresizingMaskIntoConstraints = false
        devicePopup.addItem(withTitle: "No devices — click Refresh")
        devicePopup.isEnabled = false
        let durCaption = caption("Duration (s):")
        durationField = NSTextField(string: "")
        durationField.placeholderString = "all"
        durationField.translatesAutoresizingMaskIntoConstraints = false

        // row 3: actions
        infoBtn = button("Info", #selector(info))
        captureBtn = button("Capture…", #selector(capture))
        stopBtn = button("Stop", #selector(stop)); stopBtn.isEnabled = false
        cueBtn = button("Cue…", #selector(cue))
        jogBtn = button("Jog…", #selector(jog))
        windBtn = button("Wind…", #selector(wind))
        revealBtn = button("Reveal Output", #selector(reveal)); revealBtn.isEnabled = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // log
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = mono
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        for v in [binaryBtn!, binaryLabel!, formatCaption, format!,
                  refreshBtn!, devicePopup!, durCaption, durationField!,
                  infoBtn!, captureBtn!, stopBtn!, cueBtn!, jogBtn!, windBtn!,
                  spinner!, statusLabel!, revealBtn!, scroll] {
            content.addSubview(v)
        }

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            // row 1
            binaryBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            binaryBtn.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            binaryLabel.leadingAnchor.constraint(equalTo: binaryBtn.trailingAnchor, constant: 10),
            binaryLabel.centerYAnchor.constraint(equalTo: binaryBtn.centerYAnchor),
            formatCaption.centerYAnchor.constraint(equalTo: binaryBtn.centerYAnchor),
            format.leadingAnchor.constraint(equalTo: formatCaption.trailingAnchor, constant: 6),
            format.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            format.centerYAnchor.constraint(equalTo: binaryBtn.centerYAnchor),
            binaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: formatCaption.leadingAnchor, constant: -10),
            // row 2
            refreshBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            refreshBtn.topAnchor.constraint(equalTo: binaryBtn.bottomAnchor, constant: 10),
            devicePopup.leadingAnchor.constraint(equalTo: refreshBtn.trailingAnchor, constant: 10),
            devicePopup.centerYAnchor.constraint(equalTo: refreshBtn.centerYAnchor),
            durCaption.centerYAnchor.constraint(equalTo: refreshBtn.centerYAnchor),
            durationField.leadingAnchor.constraint(equalTo: durCaption.trailingAnchor, constant: 6),
            durationField.widthAnchor.constraint(equalToConstant: 70),
            durationField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            durationField.centerYAnchor.constraint(equalTo: refreshBtn.centerYAnchor),
            devicePopup.trailingAnchor.constraint(lessThanOrEqualTo: durCaption.leadingAnchor, constant: -10),
            // row 3
            infoBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            infoBtn.topAnchor.constraint(equalTo: refreshBtn.bottomAnchor, constant: 10),
            captureBtn.leadingAnchor.constraint(equalTo: infoBtn.trailingAnchor, constant: 8),
            captureBtn.centerYAnchor.constraint(equalTo: infoBtn.centerYAnchor),
            stopBtn.leadingAnchor.constraint(equalTo: captureBtn.trailingAnchor, constant: 8),
            stopBtn.centerYAnchor.constraint(equalTo: infoBtn.centerYAnchor),
            cueBtn.leadingAnchor.constraint(equalTo: stopBtn.trailingAnchor, constant: 18),
            cueBtn.centerYAnchor.constraint(equalTo: infoBtn.centerYAnchor),
            jogBtn.leadingAnchor.constraint(equalTo: cueBtn.trailingAnchor, constant: 8),
            jogBtn.centerYAnchor.constraint(equalTo: infoBtn.centerYAnchor),
            windBtn.leadingAnchor.constraint(equalTo: jogBtn.trailingAnchor, constant: 8),
            windBtn.centerYAnchor.constraint(equalTo: infoBtn.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: windBtn.trailingAnchor, constant: 14),
            spinner.centerYAnchor.constraint(equalTo: infoBtn.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: infoBtn.centerYAnchor),
            revealBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            revealBtn.centerYAnchor.constraint(equalTo: infoBtn.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: revealBtn.leadingAnchor, constant: -8),
            // log
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            scroll.topAnchor.constraint(equalTo: infoBtn.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
        ])

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: tapecap discovery
    func detectTapecap() {
        // 1. a tapecap binary bundled inside the .app (build-app.command copies
        //    one into Resources when it can find or build it) wins outright.
        if let b = Bundle.main.url(forResource: "tapecap", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: b.path) { tapecapPath = b.path; return }
        if let saved = UserDefaults.standard.string(forKey: "tapecapPath"),
           FileManager.default.isExecutableFile(atPath: saved) { tapecapPath = saved; return }
        // login-shell PATH lookup (do-shell-script uses a minimal PATH otherwise)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "command -v tapecap 2>/dev/null || true"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) { tapecapPath = out; return }
        for c in ["/usr/local/bin/tapecap", "/opt/homebrew/bin/tapecap",
                  NSHomeDirectory() + "/bin/tapecap", NSHomeDirectory() + "/.local/bin/tapecap"] {
            if FileManager.default.isExecutableFile(atPath: c) { tapecapPath = c; return }
        }
    }
    func setBinaryLabel() {
        if let p = tapecapPath {
            binaryLabel.stringValue = p
            binaryLabel.textColor = .labelColor
        } else {
            binaryLabel.stringValue = "tapecap not found"
            binaryLabel.textColor = .systemRed
        }
    }
    @objc func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowsOtherFileTypes = true
        panel.message = "Locate the tapecap binary (from xingrz/tapecap)"
        if panel.runModal() == .OK, let u = panel.url {
            tapecapPath = u.path
            UserDefaults.standard.set(u.path, forKey: "tapecapPath")
            setBinaryLabel()
            appendLine("✓ Using tapecap: \(u.path)", .systemGreen)
        }
    }
    func ensureBinary() -> Bool {
        if tapecapPath != nil { return true }
        appendLine("✗ tapecap not set — click “tapecap…” to locate it.", .systemRed)
        return false
    }
    func guidArgs() -> [String] {
        let i = devicePopup.indexOfSelectedItem
        if devicePopup.isEnabled, i >= 0, i < guids.count, !guids[i].isEmpty { return ["--guid", guids[i]] }
        return []
    }

    // MARK: actions
    @objc func refresh() {
        guard ensureBinary() else { return }
        appendLine("── Scanning FireWire devices (tapecap list) ──", .secondaryLabelColor)
        var lines: [String] = []
        lineSink = { lines.append($0) }
        run(["list"]) { _ in
            self.lineSink = nil
            self.populateDevices(from: lines)
        }
    }
    func populateDevices(from lines: [String]) {
        var labels: [String] = []; var g: [String] = []
        for l in lines {
            if let r = l.range(of: "0x[0-9A-Fa-f]{6,16}", options: .regularExpression) {
                labels.append(l.trimmingCharacters(in: .whitespaces))
                g.append(String(l[r]))
            }
        }
        guids = g
        devicePopup.removeAllItems()
        if labels.isEmpty {
            devicePopup.addItem(withTitle: "No devices — click Refresh")
            devicePopup.isEnabled = false
            appendLine("! No FireWire devices found.", .systemYellow)
        } else {
            devicePopup.addItems(withTitles: labels)
            devicePopup.isEnabled = true
            appendLine("✓ Found \(labels.count) device(s).", .systemGreen)
        }
    }

    @objc func info() {
        guard ensureBinary() else { return }
        appendLine("── Deck info ──", .secondaryLabelColor)
        run(["info"] + guidArgs() + ["--json"]) { _ in }
    }

    @objc func capture() {
        guard ensureBinary() else { return }
        let fmt = ["auto", "dv", "hdv"][format.selectedSegment]
        let save = NSSavePanel()
        save.nameFieldStringValue = fmt == "hdv" ? "capture.m2t" : "capture.dv"
        save.message = "Save captured video as:"
        guard save.runModal() == .OK, let out = save.url else { return }
        captureOut = out
        revealBtn.isEnabled = false
        var args = ["capture"] + guidArgs()
        if fmt != "auto" { args += ["--format", fmt] }
        let dur = durationField.stringValue.trimmingCharacters(in: .whitespaces)
        if !dur.isEmpty { args += ["--duration", dur] }
        // Wait 10s (not tapecap's 5s default) for the deck to spin up and deliver
        // data before auto-stopping on silence.
        args += ["--eot-timeout", "10000"]
        args += ["--verbose", out.path]
        appendLine("── Capturing → \(out.lastPathComponent)  (\(fmt)) ──", .secondaryLabelColor)
        appendLine("» Recording. Click Stop to finalize the file cleanly.", .systemBlue)
        run(args, capturing: true) { code in
            if code == 0 || code == 130 || code == 255 {
                self.revealBtn.isEnabled = true
                self.appendLine("✓ Capture saved: \(out.path)", .systemGreen)
            } else {
                self.appendLine("✗ Capture ended with an error (exit \(code)). See the log above.", .systemRed)
            }
        }
    }

    @objc func stop() {
        guard running, capturing, let p = proc else { return }
        appendLine("» Stopping capture (SIGINT)…", .systemBlue)
        p.interrupt()
    }

    @objc func cue() {
        guard ensureBinary() else { return }
        guard let tc = promptText("Cue to timecode", "HH:MM:SS, HH:MM:SS:FF, MM:SS, or seconds", "00:30:00") else { return }
        appendLine("── Cue → \(tc) ──", .secondaryLabelColor)
        run(["cue"] + guidArgs() + [tc]) { _ in }
    }

    @objc func jog() {
        guard ensureBinary() else { return }
        guard let s = promptText("Jog the tape", "Seconds — use a leading “-” to jog backward", "5") else { return }
        let back = s.hasPrefix("-")
        let secs = back ? String(s.dropFirst()) : s
        let dir = back ? "back" : "forward"
        appendLine("── Jog \(dir) \(secs)s ──", .secondaryLabelColor)
        run(["jog"] + guidArgs() + [dir, secs]) { _ in }
    }

    @objc func wind() {
        guard ensureBinary() else { return }
        let a = NSAlert()
        a.messageText = "Wind the tape"
        a.informativeText = "Fast-wind the deck to:"
        a.addButton(withTitle: "To start")
        a.addButton(withTitle: "To end")
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        let target: String
        if r == .alertFirstButtonReturn { target = "start" }
        else if r == .alertSecondButtonReturn { target = "end" }
        else { return }
        appendLine("── Wind to \(target) ──", .secondaryLabelColor)
        run(["wind"] + guidArgs() + [target]) { _ in }
    }

    @objc func reveal() {
        if let o = captureOut { NSWorkspace.shared.activateFileViewerSelecting([o]) }
    }

    func promptText(_ title: String, _ info: String, _ def: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.stringValue = def
        a.accessoryView = tf
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf
        if a.runModal() == .alertFirstButtonReturn {
            let v = tf.stringValue.trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    // MARK: run tapecap
    func run(_ args: [String], capturing cap: Bool = false, done: @escaping (Int32) -> Void) {
        if running { NSSound.beep(); return }
        guard let bin = tapecapPath else { appendLine("✗ tapecap binary not set.", .systemRed); return }
        setRunning(true, capturing: cap)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { return }
            let s = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.feed(s) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.flush()
                self?.proc = nil
                self?.setRunning(false, capturing: false)
                done(proc.terminationStatus)
            }
        }
        proc = p
        do { try p.run() } catch {
            proc = nil
            setRunning(false, capturing: false)
            appendLine("✗ failed to launch tapecap: \(error.localizedDescription)", .systemRed)
        }
    }

    func setRunning(_ on: Bool, capturing cap: Bool) {
        running = on
        capturing = on && cap
        if on { spinner.startAnimation(nil); statusLabel.stringValue = cap ? "Capturing…" : "Working…" }
        else { spinner.stopAnimation(nil); statusLabel.stringValue = "" }
        for b in [refreshBtn, infoBtn, captureBtn, cueBtn, jogBtn, windBtn, binaryBtn] { b?.isEnabled = !on }
        devicePopup.isEnabled = !on && !guids.isEmpty
        stopBtn.isEnabled = on && cap
    }

    // MARK: log rendering
    func feed(_ s: String) {
        lineBuf += s
        while let r = lineBuf.range(of: "\n") {
            let line = String(lineBuf[..<r.lowerBound])
            lineBuf = String(lineBuf[r.upperBound...])
            appendLine(line, color(for: line))
            lineSink?(line)
        }
    }
    func flush() {
        if !lineBuf.isEmpty { appendLine(lineBuf, color(for: lineBuf)); lineSink?(lineBuf); lineBuf = "" }
    }
    func color(for line: String) -> NSColor {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("✓") { return .systemGreen }
        if t.hasPrefix("✗") { return .systemRed }
        if t.hasPrefix("!") { return .systemYellow }
        if t.hasPrefix("»") { return .systemBlue }
        if t.hasPrefix("─") { return .tertiaryLabelColor }
        let low = t.lowercased()
        if low.contains("error") || low.contains("fail") { return .systemRed }
        if low.contains("warn") { return .systemYellow }
        if low.contains("timecode") || t.range(of: "[0-9]{2}:[0-9]{2}:[0-9]{2}", options: .regularExpression) != nil {
            return .systemBlue
        }
        return .labelColor
    }
    func appendLine(_ line: String, _ col: NSColor) {
        let attr = NSAttributedString(string: line + "\n", attributes: [.foregroundColor: col, .font: mono])
        textView.textStorage?.append(attr)
        textView.scrollToEndOfDocument(nil)
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
