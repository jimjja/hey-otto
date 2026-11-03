// Otto: a voice assistant for your Mac, powered by Claude Code. Say "Hey Otto" (or press ⌃⌥Space), then a request.
// A fast voice answers and hands real work to Claude Code agents in the background: the shell, AppleScript, your
// browser through the Claude in Chrome extension, and the desktop helper below. Build and install: ./build.sh.
// The same binary is that helper: Otto screenshot | ui | click | type | key | window | history | …

import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import Speech
import SwiftUI
import WebKit

// MARK: - Desktop helper (runs instead of the app when given a subcommand)

let helperCommands: Set<String> = ["screenshot", "ui", "click", "move", "drag", "scroll", "type", "key", "front", "window", "history", "session", "ask", "help"]

enum Ctl {
    static let usage = """
        Otto screenshot [display]        capture a display (1 = main); prints the PNG path. Image pixels = screen points.
        Otto ui [app]                    the front window's controls (or that app's) with the point to click
        Otto front                       the frontmost app and window title
        Otto window [--picture]          the front window's text (and selected text), read through accessibility
        Otto click X Y [right|double]    click at screen point X,Y
        Otto move X Y                    move the pointer
        Otto drag X1 Y1 X2 Y2            drag with the left button
        Otto scroll DY [DX]              scroll where the pointer is, in lines (positive = up / left)
        Otto type TEXT                   type text into the focused field
        Otto key COMBO...                press keys, e.g. cmd+t, return, cmd+shift+4, esc, left, f5
        Otto history [--search WORDS] [--deep] [--days N] [--limit N] [--all]
                                              the user's recent Cowork and Claude Code sessions, newest first, with ids
                                              (--deep searches whole transcripts, not just titles and folders;
                                              --all includes Otto's own past conversations)
        Otto session ID [--full]         one session as a readable conversation (the last part unless --full)
        Otto ask REQUEST                 run one request through Claude Code from the terminal (for testing)
        """

    static func run(_ args: [String]) -> Int32 {
        let rest = Array(args.dropFirst())
        switch args[0] {
        case "screenshot": return screenshot(rest)
        case "ui": return ui(rest.first)
        case "front": print(frontDescription()); return 0
        case "window":
            guard let shot = Appshot.capture(text: true, image: rest.contains("--picture")) else { return fail("No front window to read.") }
            print(shot.context(includeText: true).isEmpty ? "\(shot.label): no readable text." : shot.context(includeText: true))
            return 0
        case "click": return click(rest)
        case "move":
            guard let p = point(rest) else { return fail(usage) }
            mouse(.mouseMoved, p); return 0
        case "drag": return drag(rest)
        case "scroll": return scroll(rest)
        case "type": return type(rest.joined(separator: " "))
        case "key": return keys(rest)
        case "history": return WorkHistory.list(rest)
        case "session": return WorkHistory.show(rest)
        default: print(usage); return args[0] == "help" ? 0 : 2
        }
    }

    static func fail(_ message: String) -> Int32 { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); return 2 }

    static func point(_ a: [String], at i: Int = 0) -> CGPoint? {
        guard a.count >= i + 2, let x = Double(a[i]), let y = Double(a[i + 1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    // Mouse and keyboard

    static func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: clicks)
        e?.post(tap: .cghidEventTap)
    }

    static func click(_ a: [String]) -> Int32 {
        guard let p = point(a) else { return fail(usage) }
        let mode = a.count > 2 ? a[2] : ""
        mouse(.mouseMoved, p); usleep(40_000)
        if mode == "right" {
            mouse(.rightMouseDown, p, .right); mouse(.rightMouseUp, p, .right)
            return 0
        }
        for n in 1...(mode == "double" ? 2 : 1) {
            mouse(.leftMouseDown, p, clicks: Int64(n)); mouse(.leftMouseUp, p, clicks: Int64(n)); usleep(40_000)
        }
        return 0
    }

    static func drag(_ a: [String]) -> Int32 {
        guard let from = point(a), let to = point(a, at: 2) else { return fail(usage) }
        mouse(.mouseMoved, from); usleep(40_000)
        mouse(.leftMouseDown, from); usleep(60_000)
        for i in 1...20 {
            let t = CGFloat(i) / 20
            mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)); usleep(12_000)
        }
        mouse(.leftMouseUp, to)
        return 0
    }

    static func scroll(_ a: [String]) -> Int32 {
        guard let dy = Int32(a.first ?? "") else { return fail(usage) }
        let dx = Int32(a.count > 1 ? a[1] : "0") ?? 0
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
        return 0
    }

    static func type(_ text: String) -> Int32 {
        let source = CGEventSource(stateID: .hidSystemState)
        var rest = Substring(text)
        while !rest.isEmpty {   // short chunks: some apps drop characters from long unicode events
            let chunk = Array(String(rest.prefix(16)).utf16)
            rest = rest.dropFirst(16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
            usleep(15_000)
        }
        return 0
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static func keys(_ combos: [String]) -> Int32 {
        guard !combos.isEmpty else { return fail(usage) }
        let source = CGEventSource(stateID: .hidSystemState)
        for combo in combos {
            var flags = CGEventFlags(), code: CGKeyCode?
            for part in combo.lowercased().split(separator: "+").map(String.init) {
                switch part {
                case "cmd", "command": flags.insert(.maskCommand)
                case "shift": flags.insert(.maskShift)
                case "ctrl", "control": flags.insert(.maskControl)
                case "opt", "option", "alt": flags.insert(.maskAlternate)
                case "fn": flags.insert(.maskSecondaryFn)
                default: code = keyCodes[part]
                }
            }
            guard let code else { return fail("Unknown key in \(combo)") }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                e?.flags = flags
                e?.post(tap: .cghidEventTap)
            }
            usleep(60_000)
        }
        return 0
    }

    // Screen

    @discardableResult
    static func exec(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func screenshot(_ a: [String]) -> Int32 {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let index = Int(a.first ?? "1") ?? 1
        guard index >= 1, index <= Int(count) else { return fail("There are \(count) display(s).") }
        let bounds = CGDisplayBounds(ids[index - 1])
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("otto-screen-\(index)-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        guard exec("/usr/sbin/screencapture", ["-x", "-D", "\(index)", path]) == 0, FileManager.default.fileExists(atPath: path) else {
            return fail("Screenshot failed. Give Otto Screen Recording access in System Settings → Privacy & Security.")
        }
        exec("/usr/bin/sips", ["--resampleWidth", "\(Int(bounds.width))", path])   // Retina pixels → points, so coordinates match clicks
        print("\(path)  (display \(index) of \(count), \(Int(bounds.width))×\(Int(bounds.height)) points; image x,y = screen point x+\(Int(bounds.minX)), y+\(Int(bounds.minY)))")
        return 0
    }

    // Accessibility

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin); AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    static func frontDescription() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "unknown" }
        var text = app.localizedName ?? app.bundleIdentifier ?? "unknown"
        if AXIsProcessTrusted() {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.5)
            if let window = element(root, kAXFocusedWindowAttribute), let title = attr(window, kAXTitleAttribute) as? String, !title.isEmpty {
                text += ", window “\(title)”"
            }
        }
        return text
    }

    static let interactive: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXPopUpButton", "AXMenuButton",
                                           "AXComboBox", "AXLink", "AXSlider", "AXMenuItem", "AXDisclosureTriangle", "AXIncrementor", "AXCell", "AXRow"]
    static let containers: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXSplitter", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXWindow"]

    static func ui(_ name: String?) -> Int32 {
        guard AXIsProcessTrusted() else { return fail("Give Otto Accessibility access in System Settings → Privacy & Security.") }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let wanted = name?.lowercased()
        guard let app = wanted.map({ w in apps.first { $0.localizedName?.lowercased() == w } ?? apps.first { $0.localizedName?.lowercased().contains(w) == true } })
                ?? NSWorkspace.shared.frontmostApplication else { return fail("No running app matches \(name ?? "").") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.5)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)   // Electron apps expose their UI only when asked
        guard let window = element(root, kAXFocusedWindowAttribute) ?? (attr(root, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            return fail("\(app.localizedName ?? "That app") has no open window.")
        }
        print("\(app.localizedName ?? "?"), window “\(attr(window, kAXTitleAttribute) as? String ?? "")”. Click the point after @.")
        var printed = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard printed < 400, depth < 60 else { return }
            let role = attr(el, kAXRoleAttribute) as? String ?? ""
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXPlaceholderValue", kAXHelpAttribute]
                .lazy.compactMap { (attr(el, $0) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            if interactive.contains(role) || (!label.isEmpty && !containers.contains(role)), let f = frame(el), f.width > 1, f.height > 1 {
                let short = label.count > 90 ? label.prefix(90) + "…" : Substring(label)
                print("\(role.dropFirst(2)) “\(short.replacingOccurrences(of: "\n", with: " "))” @ \(Int(f.midX)),\(Int(f.midY))")
                printed += 1
            }
            for child in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
        }
        walk(window, 0)
        if printed >= 400 { print("… (truncated; take a screenshot for the rest)") }
        return 0
    }
}

// MARK: - The user's work with Claude: Cowork and Claude Code sessions on this Mac

/// Reads the sessions the Claude desktop app (Cowork, and Claude Code in the app) and the Claude Code CLI keep on disk,
/// so Otto knows what the user has been working on: the desktop app's, and the terminal's on Otto's own
/// account only. claude.ai chats and Projects live on the server, not here.
enum WorkHistory {
    struct Session {
        let id: String, kind: String, title: String, place: String, last: Date, archived: Bool
        let transcript: URL?
    }

    static let home = NSHomeDirectory()
    static let appSupport = home + "/Library/Application Support/Claude"

    static func json(_ path: String) -> [String: Any]? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func files(_ dir: String, depth: Int, matching: (String) -> Bool) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: dir) else { return [] }
        var found: [String] = []
        while let rel = walker.nextObject() as? String {
            if walker.level > depth { walker.skipDescendants(); continue }
            if matching((rel as NSString).lastPathComponent) { found.append(dir + "/" + rel) }
        }
        return found
    }

    /// A session's id: its own field, or the file's name, without the app's "local_" prefix.
    static func id(_ d: [String: Any], _ path: String) -> String {
        let named = (d["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return named.hasPrefix("local_") ? String(named.dropFirst(6)) : named
    }

    /// The transcripts containing every word, found by grep (much faster than reading them in).
    static func containing(_ words: [String], in paths: [String]) -> Set<String> {
        var remaining = Set(paths)
        for word in words where !remaining.isEmpty {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            p.arguments = ["-l", "-i", "-F", "-e", word, "--"] + remaining.sorted()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let listed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            remaining = Set(listed.split(separator: "\n").map(String.init))
        }
        return remaining
    }

    static func date(_ ms: Any?) -> Date? { (ms as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }

    static func shortPath(_ path: String) -> String {
        let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : Substring(path)
        let parts = p.split(separator: "/")
        return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : String(p)
    }

    /// The text of a message's content: a string, or the text blocks of a list.
    static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return ((content as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    /// The Claude account whose terminal sessions count: the one Otto runs on (Claude Code passes it to this helper
    /// as CLAUDE_CONFIG_DIR), else the app's setting. Sessions of other accounts (e.g. work, in ~/.claude) are left out.
    static func accountDir() -> String {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return (dir as NSString).expandingTildeInPath }
        let setting = UserDefaults(suiteName: "io.github.jimjja.otto")?.string(forKey: "claudeConfig") ?? ""
        let resolved = ClaudeSession.resolveConfigDir(setting)
        return resolved.isEmpty ? home + "/.claude" : resolved
    }

    static func sessions() -> [Session] {
        var all: [Session] = []
        // Claude Code transcripts, keyed by session id: the account's own, and (below) the desktop app's.
        let account = accountDir()
        var transcripts: [String: URL] = [:], ownAccount = Set<String>()
        for dir in ClaudeSession.configDirs().map({ ($0 as NSString).expandingTildeInPath }) {
            for path in files(dir + "/projects", depth: 2, matching: { $0.hasSuffix(".jsonl") }) {
                let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                transcripts[id] = URL(fileURLWithPath: path)
                if dir == account { ownAccount.insert(id) }
            }
        }
        // Cowork
        for path in files(appSupport + "/local-agent-mode-sessions", depth: 3, matching: { $0.hasPrefix("local_") && $0.hasSuffix(".json") }) {
            guard let d = json(path), let last = date(d["lastActivityAt"]) else { continue }
            let folders = (d["userSelectedFolders"] as? [Any])?.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["path"] as? String) } ?? []
            let audit = URL(fileURLWithPath: (path as NSString).deletingPathExtension + "/audit.jsonl")
            all.append(Session(id: id(d, path), kind: "Cowork", title: (d["title"] as? String) ?? "Untitled", place: folders.first.map(shortPath) ?? "",
                               last: last, archived: d["isArchived"] as? Bool ?? false,
                               transcript: FileManager.default.fileExists(atPath: audit.path) ? audit : nil))
        }
        // Claude Code in the desktop app (signed in like Cowork): titled there; it keeps transcripts in ~/.claude whatever the account
        var claimed = Set<String>()
        for path in files(appSupport + "/claude-code-sessions", depth: 3, matching: { $0.hasPrefix("local_") && $0.hasSuffix(".json") }) {
            guard let d = json(path), let last = date(d["lastActivityAt"]) else { continue }
            let cli = d["cliSessionId"] as? String ?? ""
            claimed.insert(cli)
            all.append(Session(id: id(d, path), kind: "Claude Code (app)", title: (d["title"] as? String) ?? "Untitled",
                               place: shortPath((d["originCwd"] as? String) ?? (d["cwd"] as? String) ?? ""), last: last,
                               archived: d["isArchived"] as? Bool ?? false, transcript: transcripts[cli]))
        }
        // Claude Code in the terminal on this account (and Otto's own conversations)
        for (id, url) in transcripts where ownAccount.contains(id) && !claimed.contains(id) {
            guard let head = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? head.read(upToCount: 262_144)) ?? Data(); try? head.close()
            var cwd = "", prompt = ""
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if cwd.isEmpty, let c = d["cwd"] as? String { cwd = c }
                if prompt.isEmpty, d["type"] as? String == "user", d["isSidechain"] as? Bool != true,
                   let m = d["message"] as? [String: Any] {
                    let t = text(m["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty && !t.hasPrefix("<") { prompt = t }
                }
                if !cwd.isEmpty && !prompt.isEmpty { break }
            }
            guard !prompt.isEmpty else { continue }
            let own = prompt.hasPrefix("[Context:")   // Otto's own conversations start with its context line
            if own { prompt = prompt.split(separator: "\n").dropFirst().joined(separator: " ") }
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            let firstLine = prompt.split(separator: "\n").first.map(String.init) ?? prompt
            all.append(Session(id: id, kind: own ? "Otto" : "Claude Code", title: String(firstLine.prefix(90)),
                               place: shortPath(cwd), last: modified, archived: false, transcript: url))
        }
        return all.sorted { $0.last > $1.last }
    }

    static func list(_ args: [String]) -> Int32 {
        var search: [String] = [], days = 30.0, limit = 25, deep = false, everything = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--search": i += 1; while i < args.count, !args[i].hasPrefix("--") { search += Listener.words(args[i]); i += 1 }; continue
            case "--days": i += 1; days = Double(args.count > i ? args[i] : "") ?? days
            case "--limit": i += 1; limit = Int(args.count > i ? args[i] : "") ?? limit
            case "--deep": deep = true
            case "--all": everything = true
            default: search += Listener.words(args[i])
            }
            i += 1
        }
        let since = Date().addingTimeInterval(-days * 86400)
        let recent = sessions().filter { $0.last >= since && (everything || $0.kind != "Otto") }   // its own past voice chats only on request
        let inside = deep && !search.isEmpty ? containing(search, in: recent.compactMap { $0.transcript?.path }) : []
        let found = recent.filter { s in
            guard !search.isEmpty else { return true }
            let hay = (s.title + " " + s.place).lowercased()
            return search.allSatisfy { hay.contains($0) } || s.transcript.map { inside.contains($0.path) } == true
        }
        guard !found.isEmpty else { print("No sessions" + (search.isEmpty ? "" : " matching \(search.joined(separator: " "))") + " in the last \(Int(days)) days."); return 0 }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
        for s in found.prefix(limit) {
            print("\(f.string(from: s.last)) · \(s.kind) · “\(s.title)”" + (s.place.isEmpty ? "" : " · \(s.place)") + (s.archived ? " · archived" : "") + " · id \(s.id.prefix(8))")
        }
        if found.count > limit { print("… \(found.count - limit) more (use --limit or --search)") }
        return 0
    }

    static func show(_ args: [String]) -> Int32 {
        guard let wanted = args.first(where: { !$0.hasPrefix("--") }) else { return Ctl.fail(Ctl.usage) }
        let full = args.contains("--full")
        guard let s = sessions().first(where: { $0.id.hasPrefix(wanted) }) else { return Ctl.fail("No session with id \(wanted).") }
        guard let url = s.transcript, let body = try? String(contentsOf: url, encoding: .utf8) else {
            return Ctl.fail("“\(s.title)” has no transcript on this Mac.")
        }
        var out = "\(s.kind) · “\(s.title)”" + (s.place.isEmpty ? "" : " · \(s.place)") + "\n"
        for line in body.split(separator: "\n") {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = d["type"] as? String, type == "user" || type == "assistant",
                  d["isSidechain"] as? Bool != true, d["isReplay"] as? Bool != true, !(d["parent_tool_use_id"] is String),
                  let m = d["message"] as? [String: Any] else { continue }
            if type == "user" {
                var t = text(m["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("[Context:") { t = t.split(separator: "\n").dropFirst().joined(separator: "\n") }
                if !t.isEmpty && !t.hasPrefix("<") { out += "\nYou: " + t + "\n" }
            } else {
                for block in (m["content"] as? [[String: Any]]) ?? [] {
                    if block["type"] as? String == "text", let t = block["text"] as? String, !t.isEmpty { out += "\nClaude: " + t + "\n" }
                    if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                        out += "  [" + ClaudeSession.describe(name, block["input"] as? [String: Any] ?? [:]) + "]\n"
                    }
                }
            }
        }
        let limit = 15_000
        print(full || out.count <= limit ? out : "… (earlier part left out; --full for all)\n" + out.suffix(limit))
        return 0
    }
}

// MARK: - Window context ("appshots"): what the user is looking at

/// The front window as context for a request: its selected text, its text (read through accessibility, including what's
/// scrolled out of view), and optionally a picture of just that window.
struct Appshot {
    var app = "", title = "", selected = "", text = "", imagePath = ""

    var label: String { app + (title.isEmpty ? "" : " — “\(title)”") }

    /// Lines to put before the user's words.
    func context(includeText: Bool) -> String {
        var lines: [String] = []
        if !selected.isEmpty { lines.append("[Selected text in \(app)]\n\(selected)\n[End of selected text]") }
        if includeText && !text.isEmpty { lines.append("[Window \(label)]\n\(text)\n[End of window]") }
        if !imagePath.isEmpty { lines.append("[A picture of that window: \(imagePath)]") }
        return lines.joined(separator: "\n")
    }

    /// Requests that point at what's on screen ("summarize this", "reply to that email", "what's on this page").
    static let pointsAtScreen = try! NSRegularExpression(
        pattern: #"\b(this|these|that one|here|screen|window|page|tab|article|email|message|document|doc|selected|highlighted|above|below)\b"#,
        options: [.caseInsensitive])

    static func capture(text wantText: Bool, image wantImage: Bool) -> Appshot? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        var shot = Appshot(app: app.localizedName ?? "the front app")
        guard AXIsProcessTrusted() else { return shot }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)   // Chromium and Electron apps
        if let focused = Ctl.element(root, kAXFocusedUIElementAttribute),
           let selected = Ctl.attr(focused, kAXSelectedTextAttribute) as? String {
            shot.selected = String(selected.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        }
        let window = Ctl.element(root, kAXFocusedWindowAttribute) ?? (Ctl.attr(root, kAXWindowsAttribute) as? [AXUIElement])?.first
        if let window {
            shot.title = Ctl.attr(window, kAXTitleAttribute) as? String ?? ""
            if wantText { shot.text = windowText(window) }
        }
        if wantImage { shot.imagePath = picture(of: app.processIdentifier) }
        return shot
    }

    /// The window's readable text in order: static text, text fields and areas, headings, links.
    static func windowText(_ window: AXUIElement, limit: Int = 8000) -> String {
        var out: [String] = [], size = 0
        let started = Date()
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard size < limit, depth < 80, Date().timeIntervalSince(started) < 1.5 else { return }
            let role = Ctl.attr(el, kAXRoleAttribute) as? String ?? ""
            var piece = ""
            switch role {
            case "AXStaticText", "AXTextArea", "AXTextField", "AXComboBox":
                piece = (Ctl.attr(el, kAXValueAttribute) as? String) ?? ""
            case "AXHeading", "AXLink":
                piece = (Ctl.attr(el, kAXTitleAttribute) as? String) ?? (Ctl.attr(el, kAXDescriptionAttribute) as? String) ?? ""
            default: break
            }
            piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty && piece != out.last {
                out.append(piece); size += piece.count + 1
            }
            if role == "AXStaticText" || role == "AXTextArea" { return }   // its children repeat its text
            for child in (Ctl.attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
        }
        walk(window, 0)
        let text = out.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }

    /// A PNG of the app's front window (not the whole screen), scaled down; "" if it can't be taken.
    static func picture(of pid: pid_t) -> String {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        guard let id = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 })?[kCGWindowNumber as String] as? Int
        else { return "" }
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("otto-window-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        guard Ctl.exec("/usr/sbin/screencapture", ["-x", "-o", "-l\(id)", path]) == 0, FileManager.default.fileExists(atPath: path) else { return "" }
        Ctl.exec("/usr/bin/sips", ["--resampleHeightWidthMax", "1400", path])
        return path
    }
}

/// Both Command keys pressed together, anywhere: attach the front window to the next request (like ChatGPT's appshots).
final class DoubleCommand {
    private var monitors: [Any] = []
    private var last = Date.distantPast

    init(_ action: @escaping () -> Void) {
        let handler: (NSEvent) -> Void = { [weak self] event in
            let raw = event.modifierFlags.rawValue
            guard let self, raw & 0x08 != 0, raw & 0x10 != 0, Date().timeIntervalSince(self.last) > 1 else { return }   // left and right ⌘
            self.last = Date()
            action()
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(local) }
    }
}

func contextLine() -> String {
    let f = DateFormatter()
    f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
    return "[Context: front app \(Ctl.frontDescription()); \(f.string(from: Date()))]"
}

// MARK: - Claude Code session

let speakingGuide = """
    You are running inside Otto, a voice assistant on the user's Mac. The user speaks requests out loud, and your \
    final reply is read aloud by text-to-speech.

    Replying:
    - Keep the final reply short and natural to hear: one to three sentences of plain text. No markdown, lists, tables, \
    code or URLs unless the user asks for them.
    - Do the task first, then say what you did or give the answer. Don't narrate a plan before acting.
    - Speech recognition mishears words. Interpret requests sensibly.
    - Don't mention connectors, MCP servers or their setup status unless the request is about them.
    - Each message starts with a [Context: …] line naming the app that was in front when the user spoke. "This", "here" \
    and "it" usually mean that app or window.
    """

let toolGuide = """
    You have full access to this Mac and nobody approves your steps, so act without asking unless the request is genuinely ambiguous.
    - Shell: run anything with Bash. Open apps, files and links with `open -a "App"`, `open path` and `open URL`. \
    Control apps with `osascript` (AppleScript or JXA).
    - Browser: use the Claude in Chrome tools (mcp__claude-in-chrome__*) for anything on the web that needs a page, a \
    login or clicking. They drive the user's real Chrome. Call tabs_context_mcp first and open a new tab rather than \
    taking over the user's tabs. For quick facts, WebSearch and WebFetch are fine.
    - Screen and desktop: "$OTTO_CTL" is a helper (always quote it):
      "$OTTO_CTL" screenshot [display]   prints a PNG path; look at it with Read. Image pixels equal screen points.
      "$OTTO_CTL" ui [app]               the front window's controls, each with the point to click
      "$OTTO_CTL" click X Y [right|double], move X Y, drag X1 Y1 X2 Y2, scroll DY (positive = up)
      "$OTTO_CTL" type "text"            types into the focused field
      "$OTTO_CTL" key cmd+t              presses keys: cmd/shift/ctrl/opt combos, return, tab, esc, arrows, f1…f12
      "$OTTO_CTL" front                  the frontmost app and window
      Prefer AppleScript, then `ui` coordinates, over guessing positions from a screenshot. Bring an app forward before \
    typing or clicking into it, and check the result with a screenshot when it matters.
    - The user's work with Claude: "$OTTO_CTL" history [--search words] [--deep] [--days N] lists their recent \
    Cowork sessions and Claude Code sessions (terminal and the desktop app) with titles, folders and ids, and \
    "$OTTO_CTL" session ID prints one as a conversation. Use them when the user asks what they've been working \
    on, refers to an earlier chat or task, or a request needs that context. Their claude.ai chats and Projects aren't \
    on this Mac: open https://claude.ai/recents or https://claude.ai/projects in the browser and read or search them there.
    """

/// The single-agent mode: one Claude Code that talks and works.
let systemPrompt = speakingGuide + "\n\n" + toolGuide

/// A background worker started by the voice layer: nobody hears it directly.
let workerPrompt = """
    You are a background worker for Otto, a voice assistant on the user's Mac. The voice assistant gave you this \
    task and will relay your final message to the user out loud; the user isn't watching you work.
    - Do the task fully, without asking questions unless it truly can't be done otherwise (then say what you need in your report).
    - End with a short plain-text report: what you did or found, with the specifics the user would want (times, names, \
    numbers, where you saved things). A few sentences; no tables or headings.
    - The task may start with lines in brackets: [Context …] (the app in front when the user asked, the time), \
    [Selected text …] and [Window …] (what the user was looking at). "This" or "here" usually means that.
    - You may get follow-up instructions for the same task later; continue from where you left off.
    """ + "\n\n" + toolGuide

/// The voice layer: fast, talks, and delegates all real work to background workers through tags.
let voicePrompt = """
    You are Otto, the voice of an assistant on the user's Mac. You talk with the user. Background workers — full \
    Claude Code agents with the shell, the user's browser, files, apps, and their Claude work history — do the actual work.

    Everything you write is spoken aloud, except the tags below. Keep it short, warm and natural: usually one sentence, \
    two at most. No markdown, lists or URLs.

    Answer directly only for conversation, simple knowledge, and questions about tasks in the [Tasks] list. Anything \
    that needs the computer, the web, files, apps, email, calendar, up-to-date information, or more than a few seconds \
    of thought: start a task, and in the same reply tell the user briefly that you're on it. You can't see the screen or \
    use tools yourself, so never pretend to have done something a task hasn't done.

    Tags (never spoken; put them after your spoken words, so the user hears you right away):
    <task title="Short title">A complete instruction for the worker, with everything relevant the user said.</task>
    <steer id="N">What to change, add or do next in task N (works on finished tasks too).</steer>
    <cancel id="N"/>
    Start several tasks at once when the user asks for independent things. Don't wait for results: you'll get a message \
    when a task finishes. Then tell the user the gist in a sentence or two, and ask if a decision is needed.

    Messages may start with bracketed lines: [Context …] (front app, time), [Tasks …] (background tasks and their \
    status), [Selected text …], [Window …] (what the user is looking at). Use them; the worker receives the same \
    context automatically, so refer to it ("the selected text", "the window") rather than copying it out.
    Speech recognition mishears words; interpret requests sensibly.
    """

final class ClaudeSession {
    /// agent: talks and works (single-agent mode). worker: a background task. voice: the fast talking layer, no tools.
    enum Role { case agent, worker, voice }
    var role = Role.agent
    var onStep: (String) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }
    var onDone: (_ text: String, _ failed: Bool) -> Void = { _, _ in }
    /// Claude Code asks before an action it considers risky (Ask Before Risky Actions): answer with answer(_:allow:).
    var onPermission: (PermissionRequest) -> Void = { _ in }
    var fullAccess = true   // false: Claude Code's auto mode, with what it would ask about sent to onPermission
    var model = ""
    var configDir = ""   // CLAUDE_CONFIG_DIR, i.e. which Claude account and settings; empty: Claude Code's default (~/.claude)
    var freshAfter: TimeInterval = 15 * 60   // a new conversation after this long without asking anything
    private(set) var busy = false
    private var process: Process?
    private var input: FileHandle?
    private var sessionID: String?
    private var lastUse = Date.distantPast
    private var pending = Data()
    private var errorTail = ""
    private var answer = ""
    private var stopping = false

    func send(_ text: String, image: String = "") {
        if !busy, Date().timeIntervalSince(lastUse) > freshAfter { reset() }
        lastUse = Date()
        if process?.isRunning != true { launch() }
        guard let input else {
            return onDone("I couldn't start Claude Code. Check that it's installed and signed in (run claude in Terminal).", true)
        }
        var content: Any = text
        if !image.isEmpty, let png = FileManager.default.contents(atPath: image) {   // the model sees the picture itself
            content = [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]],
                       ["type": "text", "text": text]]
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(0x0A)
        busy = true; answer = ""
        do { try input.write(contentsOf: line) } catch {
            busy = false
            onDone("I couldn't reach Claude Code: \(error.localizedDescription)", true)
        }
    }

    /// Ends the running turn. The next request resumes the same conversation.
    func stop() {
        guard busy else { return }
        busy = false; stopping = true
        process?.terminate()
    }

    /// Actions that ask first even when the user asked for them (Ask Before Risky Actions): they can't be undone.
    static let alwaysAsk = ["Bash(rm:*)", "Bash(rmdir:*)", "Bash(trash:*)", "Bash(srm:*)", "Bash(shred:*)", "Bash(unlink:*)",
                            "Bash(sudo:*)", "Bash(git push:*)", "Bash(git reset --hard:*)", "Bash(git clean:*)",
                            "Bash(diskutil:*)", "Bash(dd:*)", "Bash(*rm -rf*)", "Bash(*rm -r *)"]

    /// Answers a permission request: the action runs, or the agent is told the user said no.
    func answer(_ request: PermissionRequest, allow: Bool) {
        let decision: [String: Any] = allow ? ["behavior": "allow", "updatedInput": request.input]
                                            : ["behavior": "deny", "message": "The user said no to this. Don't retry it; find another way or report back."]
        let reply: [String: Any] = ["type": "control_response",
                                    "response": ["subtype": "success", "request_id": request.id, "response": decision]]
        guard let input, var line = try? JSONSerialization.data(withJSONObject: reply) else { return }
        line.append(0x0A)
        try? input.write(contentsOf: line)
    }

    /// Lets an idle conversation's process go; the next message resumes it.
    func suspend() {
        guard !busy, process != nil else { return }
        stopping = true
        process?.terminate()
        process = nil; input = nil
    }

    /// Forgets the conversation.
    func reset() {
        busy = false; stopping = true
        process?.terminate()
        process = nil; input = nil; sessionID = nil
    }

    /// Claude Code config folders in the home folder: ~/.claude and any ~/.claude-something (one per account).
    static func configDirs() -> [String] {
        let home = NSHomeDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { $0 == ".claude" || $0.hasPrefix(".claude-") }.sorted().filter {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: home + "/" + $0, isDirectory: &dir) && dir.boolValue
        }.map { "~/" + $0 }
    }

    /// The configured account folder as CLAUDE_CONFIG_DIR, or "" for the default (also when the folder is gone).
    static func resolveConfigDir(_ setting: String) -> String {
        let path = (setting as NSString).expandingTildeInPath
        guard !setting.isEmpty, setting != "~/.claude", FileManager.default.fileExists(atPath: path) else { return "" }
        return path
    }

    static func claudePath() -> String? {
        if let custom = UserDefaults.standard.string(forKey: "claudePath"), FileManager.default.isExecutableFile(atPath: custom) { return custom }
        let home = NSHomeDirectory()
        for path in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        let p = Process(), out = Pipe()   // last resort: the login shell's PATH
        p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "whence -p claude"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init).last { $0.hasPrefix("/") }
        return found.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    private func launch() {
        guard let claude = Self.claudePath() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        switch role {
        case .voice:   // small and fast: Haiku, no tools, no MCP servers, its own short system prompt
            args += ["--model", "haiku", "--effort", "low", "--tools", "", "--strict-mcp-config", "--system-prompt", voicePrompt]
        case .agent, .worker:
            args += ["--chrome", "--append-system-prompt", role == .worker ? workerPrompt : systemPrompt]
            // Full access: nothing is asked. Otherwise Claude Code's own judgment: its auto mode approves routine actions
            // and sends the risky ones here ("stdio": this app is the host that answers them).
            args += fullAccess ? ["--permission-mode", "bypassPermissions"] : ["--permission-mode", "auto", "--permission-prompt-tool", "stdio"]
            // Auto mode lets through what the user asked for. Speech gets misheard, so what can't be undone asks anyway.
            if !fullAccess, let rules = try? JSONSerialization.data(withJSONObject: ["permissions": ["ask": Self.alwaysAsk]]) {
                args += ["--settings", String(decoding: rules, as: UTF8.self)]
            }
            if !model.isEmpty { args += ["--model", model] }
        }
        if let sessionID { args += ["--resume", sessionID] }
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["OTTO_CTL"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // Set explicitly: inherited from whatever launched the app, it would differ between a Terminal launch and login.
        if configDir.isEmpty { env.removeValue(forKey: "CLAUDE_CONFIG_DIR") } else { env["CLAUDE_CONFIG_DIR"] = configDir }
        p.environment = env
        let out = Pipe(), inp = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardInput = inp; p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.errorTail = String((self.errorTail + String(decoding: data, as: UTF8.self)).suffix(1500))
            }
        }
        p.terminationHandler = { [weak self] ended in DispatchQueue.main.async { self?.ended(ended) } }
        guard (try? p.run()) != nil else { return }
        process = p; input = inp.fileHandleForWriting
        stopping = false; errorTail = ""; pending = Data()
    }

    private func ended(_ p: Process) {
        guard p === process else { return }
        process = nil; input = nil
        if busy && !stopping {
            busy = false
            sessionID = nil   // a conversation that can't be resumed must not break every later request
            let detail = errorTail.split(separator: "\n").suffix(3).joined(separator: " ")
            onDone("Claude Code stopped unexpectedly." + (detail.isEmpty ? "" : " " + detail), true)
        }
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = obj["type"] as? String else { return }
        let nested = obj["parent_tool_use_id"] is String   // a subagent's own messages
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let id = obj["session_id"] as? String { sessionID = id }
        case "stream_event":
            guard !nested, let event = obj["event"] as? [String: Any] else { return }
            let kind = event["type"] as? String
            if kind == "content_block_start", (event["content_block"] as? [String: Any])?["type"] as? String == "tool_use" {
                answer = ""   // text before a tool call is narration; the answer is what comes after the last one
                onText("")
            } else if kind == "content_block_delta", let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                answer += text
                onText(answer)
            }
        case "assistant":
            guard !nested, let message = obj["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_use" {
                onStep(Self.describe(block["name"] as? String ?? "", block["input"] as? [String: Any] ?? [:]))
            }
        case "control_request":
            guard let id = obj["request_id"] as? String, let request = obj["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool" else { return }
            let tool = request["tool_name"] as? String ?? "a tool", input = request["input"] as? [String: Any] ?? [:]
            let about = (request["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.describe(tool, input)
            onPermission(PermissionRequest(id: id, tool: tool, input: input, description: about, session: self))
        case "result":
            busy = false; lastUse = Date()
            let failed = obj["is_error"] as? Bool == true || (obj["subtype"] as? String ?? "success") != "success"
            let result = (obj["result"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? answer
            onDone(result.isEmpty ? (failed ? "Something went wrong." : "Done.") : result, failed)
        default: break
        }
    }

    static func describe(_ name: String, _ input: [String: Any]) -> String {
        func s(_ key: String) -> String { input[key] as? String ?? "" }
        let chrome = "mcp__claude-in-chrome__"
        switch name {
        case "Bash":
            let command = s("command").replacingOccurrences(of: "\"$OTTO_CTL\"", with: "ctl").replacingOccurrences(of: "$OTTO_CTL", with: "ctl")
            return "$ " + (command.split(separator: "\n").first.map(String.init) ?? "")
        case "Read": return "Reading " + (s("file_path") as NSString).lastPathComponent
        case "Write", "Edit": return "Writing " + (s("file_path") as NSString).lastPathComponent
        case "WebSearch": return "Searching “\(s("query"))”"
        case "WebFetch": return "Fetching " + (URL(string: s("url"))?.host ?? s("url"))
        case _ where name.hasPrefix(chrome):
            let tool = String(name.dropFirst(chrome.count))
            if tool == "navigate" { return "Chrome → " + s("url") }
            if tool == "computer" { return "Chrome: " + s("action") + (s("text").isEmpty ? "" : " “\(s("text").prefix(40))”") }
            return "Chrome: " + tool.replacingOccurrences(of: "_mcp", with: "").replacingOccurrences(of: "_", with: " ")
        default: return name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: ": ")
        }
    }
}

/// An action Claude Code wants the user's OK for.
struct PermissionRequest {
    let id: String, tool: String, input: [String: Any], description: String
    weak var session: ClaudeSession?
    var taskID: Int?   // set when it comes from a background task

    /// "Run a command: rm -rf ~/x", or Claude Code's own description of it.
    var spoken: String {
        let what = description.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return what.prefix(1).lowercased() + what.dropFirst()
    }
}

// MARK: - Background tasks: the voice layer's tags, and the workers they start

enum Directive: Equatable {
    case start(title: String, instruction: String)
    case steer(id: Int, text: String)
    case cancel(id: Int)
}

/// Splits the voice layer's streamed reply into what's spoken and the tags it contains, holding back anything that
/// might still turn into a tag, so no part of a tag is ever read aloud.
struct DirectiveFilter {
    private var buffer = ""
    private static let openers = ["<task", "<steer", "<cancel"]
    private static let task = try! NSRegularExpression(pattern: #"^<task(?:\s+title\s*=\s*"([^"]*)")?\s*>([\s\S]*?)</task\s*>"#)
    private static let steer = try! NSRegularExpression(pattern: #"^<steer\s+id\s*=\s*"?#?(\d+)"?\s*>([\s\S]*?)</steer\s*>"#)
    private static let cancel = try! NSRegularExpression(pattern: #"^<cancel\s+id\s*=\s*"?#?(\d+)"?\s*/?>(?:\s*</cancel\s*>)?"#)

    mutating func feed(_ text: String) -> (speech: String, directives: [Directive]) {
        buffer += text
        return drain(final: false)
    }

    /// The reply is complete: whatever is left is speech, except an unfinished tag, which is dropped.
    mutating func finish() -> (speech: String, directives: [Directive]) { drain(final: true) }

    private mutating func drain(final: Bool) -> (speech: String, directives: [Directive]) {
        var speech = "", found: [Directive] = []
        while !buffer.isEmpty {
            guard let lt = buffer.firstIndex(of: "<") else { speech += buffer; buffer = ""; break }
            speech += buffer[..<lt]
            buffer = String(buffer[lt...])
            if let (directive, rest) = Self.match(buffer) {
                found.append(directive); buffer = rest; continue
            }
            let mightBeTag = Self.openers.contains { buffer.count < $0.count ? $0.hasPrefix(buffer) : buffer.hasPrefix($0) }
            if mightBeTag && !final && buffer.count < 8000 { break }   // wait for the rest of it
            if mightBeTag && final { buffer = ""; break }
            speech += "<"; buffer.removeFirst()   // an ordinary "<" ("3 < 5")
        }
        return (speech, found)
    }

    private static func match(_ text: String) -> (Directive, String)? {
        let range = NSRange(text.startIndex..., in: text)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String {
            Range(m.range(at: i), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
        func rest(_ m: NSTextCheckingResult) -> String { String(text[Range(m.range, in: text)!.upperBound...]) }
        if let m = task.firstMatch(in: text, range: range) {
            let instruction = group(m, 2)
            let title = group(m, 1)
            return (.start(title: title.isEmpty ? String(instruction.prefix(40)) : title, instruction: instruction), rest(m))
        }
        if let m = steer.firstMatch(in: text, range: range), let id = Int(group(m, 1)) { return (.steer(id: id, text: group(m, 2)), rest(m)) }
        if let m = cancel.firstMatch(in: text, range: range), let id = Int(group(m, 1)) { return (.cancel(id: id), rest(m)) }
        return nil
    }
}

final class AgentTask {
    enum Status: String { case running, finished, failed, cancelled }
    let id: Int, title: String
    var status = Status.running
    var steps: [String] = []
    var result = ""
    var waiting: String?   // what it's waiting for the user's OK to do
    var started = Date(), ended: Date?
    let session = ClaudeSession()
    init(id: Int, title: String) { self.id = id; self.title = title }

    var elapsed: String {
        let seconds = Int((ended ?? Date()).timeIntervalSince(started))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

/// The background workers: each task is its own Claude Code conversation, running in parallel.
final class TaskBoard {
    var onChange: () -> Void = {}
    var onStep: (AgentTask, String) -> Void = { _, _ in }
    var onFinished: (AgentTask) -> Void = { _ in }
    var onPermission: (PermissionRequest) -> Void = { _ in }
    var configure: (ClaudeSession) -> Void = { _ in }   // account, model and access, set by the app
    private(set) var tasks: [AgentTask] = []
    private var nextID = 1
    private var reaper: Timer?

    var running: [AgentTask] { tasks.filter { $0.status == .running } }

    init() {
        reaper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in   // idle workers let their process go
            self?.tasks.filter { $0.status != .running && Date().timeIntervalSince($0.ended ?? Date()) > 600 }.forEach { $0.session.suspend() }
        }
    }

    @discardableResult
    func start(title: String, instruction: String, image: String = "") -> AgentTask {
        let task = AgentTask(id: nextID, title: title)
        nextID += 1
        task.session.role = .worker
        task.session.freshAfter = .infinity   // a task keeps its conversation for follow-ups
        configure(task.session)
        task.session.onStep = { [weak self, weak task] step in
            guard let self, let task else { return }
            task.steps.append(step)
            self.onStep(task, step); self.onChange()
        }
        task.session.onPermission = { [weak self, weak task] request in
            guard let self, let task else { return }
            var request = request
            request.taskID = task.id
            task.waiting = request.spoken
            self.onChange(); self.onPermission(request)
        }
        task.session.onDone = { [weak self, weak task] text, failed in
            guard let self, let task, task.status == .running else { return }
            task.waiting = nil
            task.status = failed ? .failed : .finished
            task.result = text; task.ended = Date()
            self.onChange(); self.onFinished(task)
        }
        tasks.append(task)
        task.session.send(instruction, image: image)
        onChange()
        return task
    }

    @discardableResult
    func steer(_ id: Int, _ text: String) -> Bool {
        guard let task = tasks.first(where: { $0.id == id }), task.status != .cancelled else { return false }
        task.status = .running; task.ended = nil
        task.session.send(text)
        onChange()
        return true
    }

    @discardableResult
    func cancel(_ id: Int) -> Bool {
        guard let task = tasks.first(where: { $0.id == id }), task.status == .running else { return false }
        task.status = .cancelled; task.ended = Date()
        task.session.stop()
        onChange()
        return true
    }

    func shutdown() { tasks.forEach { $0.session.reset() } }

    /// The [Tasks] lines for the voice layer: what's running, and what finished recently.
    func summary(now: Date = Date()) -> String {
        let recent = tasks.filter { $0.status == .running || now.timeIntervalSince($0.ended ?? now) < 1800 }
        guard !recent.isEmpty else { return "" }
        let lines = recent.map { t -> String in
            switch t.status {
            case .running: return "#\(t.id) “\(t.title)”: running for \(t.elapsed)"
                + (t.waiting.map { "; waiting for the user's OK to \($0)" } ?? t.steps.last.map { "; now: \($0)" } ?? "")
            case .finished: return "#\(t.id) “\(t.title)”: finished \(Int(now.timeIntervalSince(t.ended ?? now) / 60)) min ago: \(t.result.prefix(300))"
            case .failed: return "#\(t.id) “\(t.title)”: failed: \(t.result.prefix(200))"
            case .cancelled: return "#\(t.id) “\(t.title)”: cancelled"
            }
        }
        return "[Tasks]\n" + lines.joined(separator: "\n") + "\n[End of tasks]"
    }
}

// MARK: - Listening: wake word, then the request until a pause

final class Listener {
    var onWake: () -> Void = {}
    var onFollowUp: () -> Void = {}
    var onPartial: (String) -> Void = { _ in }
    var onCommand: (String) -> Void = { _ in }
    var onGiveUp: () -> Void = {}
    var onNote: (String) -> Void = { _ in }   // diagnostics for the log
    var onBargeIn: () -> Void = {}   // the user started talking over the spoken answer
    var onVoiceDuringSpeech: () -> Void = {}   // a voice while an answer plays: pause it until words confirm an interruption
    var onFalseAlarm: () -> Void = {}   // that voice said nothing (a cough, a door): carry on
    var onEngineReset: () -> Void = {}   // the audio engine was rebuilt: whatever was playing on the old one is gone
    var echoCancellation = true   // Settings: Echo Cancellation; applies to the next engine build
    var echoCancelling = false   // whether the running engine removes the app's own voice from the microphone (settable for tests)
    var pauseToEnd: TimeInterval = 1.8   // silence that ends an unclear request (Settings: Pause Before Sending); less after a finished sentence
    var wakeEnabled = false {
        didSet { wakeEnabled ? start() : stopIfIdle() }
    }
    private(set) var capturing = false
    var micEnabled = true   // tests turn the microphone off and feed transcripts to heard() instead
    private(set) var followingUp = false   // listening for a reply after an answer, without the wake phrase
    var wakePhrase = "Hey Otto" {
        didSet { wakeWords = Self.words(wakePhrase) }
    }
    private var wakeWords = Listener.words("Hey Otto")

    // One engine for the microphone and the spoken answers: voice processing can only cancel the echo of audio it plays itself.
    // Rebuilt whenever the audio input changes: a used engine keeps the old device's format.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var skipVoiceProcessing = false   // it failed on this Mac's current devices; listen without it
    private var startedAt = Date.distantPast
    private var voiceSince: Date?   // start of the current stretch of voice (guarded by lock)
    private var pausedForVoiceAt: Date?   // when the answer was paused because a voice was heard
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var viaWake = false
    private var command = ""
    private var skipWords = 0   // transcript words before the request: the wake phrase, or echo before an interruption
    private var carried = ""   // the request so far, when recognition restarted in the middle of it
    private var fresh = ""   // the part of the request heard in the current transcript
    private var speechWords: Set<String>?   // while an answer is spoken: its words, to tell the echo from the user talking
    // Audio level, from the microphone tap (guarded by lock): when sound that looks like a voice was last heard.
    private var voiceAt = Date.distantPast, noiseFloor: Float = 0.01
    private var recent: [AVAudioPCMBuffer] = [], recentFrames: AVAudioFrameCount = 0   // the last ~2 s, replayed after a restart
    private var transcript = ""
    private var lastChange = Date(), captureStart = Date(), taskStart = Date(), lastHeard = Date()
    private var timer: Timer?
    private var configObserver: NSObjectProtocol?
    private var rebuildWork: DispatchWorkItem?
    private var lastRebuild = Date.distantPast

    private var quietLimit: TimeInterval = 8   // seconds of silence before giving up on a request that never started
    private static let token = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
    // How speech recognition tends to mishear these words; any other word may be off by a letter or two.
    private static let soundsLike: [String: Set<String>] = [
        "hey": ["hi", "hay", "he", "a", "okay", "ok", "hate"],
        "okay": ["ok", "okey", "hey"],
        "hi": ["hey", "high"],
        "otto": ["auto", "otter", "oto", "odo", "otto's", "auto's", "otta", "ottoh"],
        "claude": ["cloud", "clyde", "claud", "clod", "clawed", "claudia", "clode", "clued", "plod"],
    ]
    // Requests that end on these words are probably not finished yet ("check my", "open the", "and").
    private static let unfinished: Set<String> = ["and", "or", "but", "so", "the", "a", "an", "my", "your", "our", "their", "this", "that",
        "to", "of", "for", "with", "in", "on", "at", "from", "about", "into", "can", "could", "would", "should", "will", "please",
        "is", "are", "was", "what", "which", "who", "how", "when", "where", "if", "then", "because", "like", "um", "uh", "other", "some", "any"]
    private static let interruptions: Set<String> = ["stop", "wait", "cancel", "enough", "quiet", "pause", "hold"]

    init() { observe() }

    private var audioHeld = false   // the speaker needs the engine (for playback) even if nothing else does
    private var shouldListen: Bool { wakeEnabled || capturing || audioHeld }

    /// Keeps the engine running while an answer is being spoken.
    func holdAudio(_ on: Bool) {
        audioHeld = on
        on ? start() : stopIfIdle()
    }

    private func observe() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        // Delivered on the engine's own thread (queue nil) and handed to the main thread without waiting. Observing on
        // .main made the engine's thread wait for the main thread, which deadlocked the app when the main thread was
        // releasing that same engine (that waits for the engine's thread).
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.configurationChanged() }
        }
    }

    /// The microphone changed (AirPods connecting, another input picked). macOS sends several of these per switch,
    /// so wait for it to settle, then start over on a new engine. Starting with voice processing reconfigures the
    /// devices too; those changes aren't the user's.
    private func configurationChanged() {
        guard shouldListen else { return }
        if Date().timeIntervalSince(startedAt) <= 2 {   // our own start reconfigured the device and stopped it: just start again
            if !engine.isRunning { try? engine.start() }
            return
        }
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild("Audio input changed") }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// A fresh engine and player. The old engine is released off the main thread: releasing it waits for its thread.
    private func replaceEngine() {
        let old = engine
        engine = AVAudioEngine(); player = AVAudioPlayerNode()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { withExtendedLifetime(old) {} }
    }

    private func rebuild(_ why: String) {
        rebuildWork = nil
        guard shouldListen else { return }
        lastRebuild = Date()
        onNote(why + "; restarting the microphone")
        let wasCapturing = capturing
        shutdown()
        replaceEngine()
        onEngineReset()
        observe()
        start()
        if wasCapturing { viaWake = false; skipWords = 0; carried = command; fresh = "" }   // the new transcript starts after what was heard
    }

    /// Echo cancellation was switched in Settings: start over with or without it.
    func restartAudio() {
        skipVoiceProcessing = false
        if engine.isRunning { rebuild("Echo cancellation \(echoCancellation ? "on" : "off")") }
    }

    /// The player for spoken answers, on the running engine (nil if the microphone isn't running).
    func output() -> AVAudioPlayerNode? { engine.isRunning ? player : nil }

    static func words(_ phrase: String) -> [String] {
        phrase.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Push-to-talk: listen for a request now, without the wake word. Pressing again while listening sends what was heard.
    /// followUp: after an answer, listen quietly for a reply; silence just ends it.
    func beginCapture(followUp: Bool = false) {
        if capturing && followingUp && !followUp {   // the hotkey during a follow-up: the user means to talk now
            followingUp = false; quietLimit = 8; captureStart = Date()
            return onWake()
        }
        if capturing {
            if !followUp { command.isEmpty ? giveUp() : finish() }
            return
        }
        start()
        newTask()
        capturing = true; viaWake = false; followingUp = followUp; command = ""; carried = ""; fresh = ""; skipWords = 0
        quietLimit = followUp ? 7 : 8
        captureStart = Date(); lastChange = Date()
        followUp ? onFollowUp() : onWake()
    }

    /// Where the request starts: just after the last place the wake phrase was heard, as a UTF-16 offset
    /// and as the number of transcript words up to there. Nil when the phrase isn't in the text.
    private func wakeEnd(in text: String) -> (offset: Int, words: Int)? {
        let ns = text as NSString
        let tokens = Self.token.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let n = wakeWords.count
        guard n > 0, tokens.count >= n else { return nil }
        for first in stride(from: tokens.count - n, through: 0, by: -1)
        where (0..<n).allSatisfy({ Self.similar(ns.substring(with: tokens[first + $0].range).lowercased(), wakeWords[$0]) }) {
            let last = tokens[first + n - 1].range
            return (last.location + last.length, first + n)
        }
        return nil
    }

    /// The offset just after the first `words` words of the text, or nil if it has fewer.
    private static func offset(afterWords words: Int, in text: String) -> Int? {
        guard words > 0 else { return 0 }
        let tokens = token.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        guard tokens.count >= words else { return nil }
        let last = tokens[words - 1].range
        return last.location + last.length
    }

    private static func similar(_ heard: String, _ wanted: String) -> Bool {
        if heard == wanted || soundsLike[wanted]?.contains(heard) == true { return true }
        guard wanted.count >= 4 else { return false }   // short words must match exactly, or everything would wake it
        return distance(heard, wanted) <= (wanted.count >= 7 ? 2 : 1)
    }

    private static func distance(_ a: String, _ b: String) -> Int {   // Levenshtein
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]; row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    private func start() {
        guard micEnabled else { return }
        if timer == nil {   // first, so the watchdog in tick() retries if the microphone can't start now
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        }
        if !engine.isRunning {
            // The player has to be connected before voice processing is switched on, or the engine fails to start.
            if player.engine == nil { engine.attach(player) }
            engine.connect(player, to: engine.mainMixerNode, format: Speaker.format)
            echoCancelling = false
            if echoCancellation && !skipVoiceProcessing {
                do {
                    try engine.inputNode.setVoiceProcessingEnabled(true)   // echo cancellation, noise suppression, level control
                    engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)   // keep music loud
                    echoCancelling = true
                } catch { onNote("Echo cancellation unavailable: \(error.localizedDescription)") }
            }
            let node = engine.inputNode, format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return onNote("No microphone input available") }
            // Voice processing delivers several channels; the first is the cleaned-up voice.
            let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self, let voice = Self.firstChannel(buffer, mono) else { return }
                let level = Self.rms(voice), now = Date()
                self.lock.lock()
                let r = self.request
                // A slowly rising floor follows the room's noise; speech is well above it.
                if level < self.noiseFloor { self.noiseFloor = max(level, 0.0005) } else { self.noiseFloor += (level - self.noiseFloor) * 0.002 }
                if level > max(self.noiseFloor * 3, 0.006) {
                    self.voiceAt = now
                    if self.voiceSince == nil { self.voiceSince = now }
                } else if now.timeIntervalSince(self.voiceAt) > 0.25 {
                    self.voiceSince = nil
                }
                self.recent.append(voice); self.recentFrames += voice.frameLength
                while self.recentFrames > AVAudioFrameCount(format.sampleRate * 2), self.recent.count > 1 {
                    self.recentFrames -= self.recent.removeFirst().frameLength
                }
                self.lock.unlock()
                r?.append(voice)
            }
            engine.prepare()
            startedAt = Date()
            do { try engine.start() } catch {
                if echoCancelling {   // some device combinations can't do it: start again without
                    onNote("Couldn't start with echo cancellation (\(error.localizedDescription)); trying without")
                    skipVoiceProcessing = true
                    shutdown(); replaceEngine(); observe()
                    return start()
                }
                return onNote("Microphone failed to start: \(error.localizedDescription)")
            }
            onNote("Listening on \(format.channelCount == 1 ? "the microphone" : "\(format.channelCount)-channel input")" + (echoCancelling ? " with echo cancellation" : ""))
            newTask()
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    /// A copy of the buffer's first channel (the tap's buffer is reused, and the recognizer wants mono).
    private static func firstChannel(_ buffer: AVAudioPCMBuffer, _ mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let from = buffer.floatChannelData, let to = c.floatChannelData else { return nil }
        c.frameLength = buffer.frameLength
        to[0].update(from: from[0], count: Int(buffer.frameLength))
        return c
    }

    private func shutdown() {
        timer?.invalidate(); timer = nil
        lock.lock(); recent = []; recentFrames = 0; voiceSince = nil; lock.unlock()
        generation += 1
        task?.cancel(); task = nil
        lock.lock(); request = nil; lock.unlock()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func stopIfIdle() {
        if !shouldListen { shutdown() }
    }

    /// While an answer is read aloud: listen for the user talking over it. The microphone also hears the answer itself,
    /// so only words that aren't in it count.
    /// While an answer is audible: listen for the user talking over it, on a fresh transcript.
    func listenDuringSpeech(_ text: String) {
        speechWords = Set(Self.words(text))
        pausedForVoiceAt = nil
        if !capturing { newTask() }
    }

    /// More of a streamed answer is about to be spoken.
    func speaking(more text: String) { speechWords?.formUnion(Self.words(text)) }

    func speechEnded() {
        speechWords = nil; pausedForVoiceAt = nil
    }

    /// Where the user's own words begin in a transcript heard during speech (as a word count to skip), or nil if it's all echo.
    private func interruption(in text: String, _ spoken: Set<String>) -> Int? {
        let all = Self.words(text)
        // "Stop", "wait" and the like count at once, even as the newest word.
        if let i = all.firstIndex(where: { Self.interruptions.contains($0) && !spoken.contains($0) }) { return i }
        func echo(_ w: String) -> Bool { w.count <= 2 || spoken.contains(w) || spoken.contains { Self.soundsAlike(w, $0) } }
        // Paused because a voice was heard: nothing is playing, so any unfamiliar word is the user's.
        if pausedForVoiceAt != nil { return all.firstIndex { !echo($0) } }
        // The newest word is often cut off mid-way ("pro" for "protests"), so it's judged on the next update.
        let heard = all.dropLast()
        // The user's words start where enough words in a row are unfamiliar. With echo cancellation little of the
        // app's own voice gets through: two in four. Without it, the voice is heard misheard a word or two at a time
        // ("Tchoupitoulas Street" → "chop it to less street"): three in five.
        let (needed, window) = echoCancelling ? (2, 4) : (3, 5)
        for i in heard.indices where !echo(heard[i]) && heard[i..<min(i + window, heard.endIndex)].filter({ !echo($0) }).count >= needed {
            return i
        }
        return nil
    }

    /// Whether two words could be the same spoken word, as recognition hears the app's own voice:
    /// cut off, shortened or split ("pro"/"protests", "report"/"reported", "toulas"/"tchoupitoulas"), a letter or two off ("our"/"or", "Sophia"/"Sofia"),
    /// or the same consonants ("Sophie"/"Sofia").
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 3 && long.hasPrefix(short) { return true }
        if short.count >= 4 && long.contains(short) { return true }   // a fragment: "toulas" in "tchoupitoulas"
        if distance(a, b) <= max(1, long.count / 3) { return true }
        let ka = skeleton(a), kb = skeleton(b)
        return ka.count >= 2 && ka == kb
    }

    private static func skeleton(_ word: String) -> String {
        let w = word.replacingOccurrences(of: "ph", with: "f").replacingOccurrences(of: "ck", with: "k")
        guard let first = w.first else { return "" }
        var out = String(first)
        for c in w.dropFirst() where !"aeiouy".contains(c) && c != out.last { out.append(c) }
        return out
    }

    /// Where the request starts when the wake phrase is no longer in the transcript (recognition rewrote or dropped it):
    /// where the words already heard of the request now are, or else after the leading words that still sound like the phrase.
    private func requestStart(in text: String) -> Int? {
        let ns = text as NSString
        let tokens = Self.token.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let words = tokens.map { ns.substring(with: $0.range).lowercased() }
        let earlier = Array(Self.words(fresh).prefix(3))
        func same(_ a: String, _ b: String) -> Bool { a == b || Self.soundsAlike(a, b) }
        if !earlier.isEmpty {
            for i in words.indices where (0..<min(earlier.count, words.count - i)).allSatisfy({ same(words[i + $0], earlier[$0]) }) {
                return tokens[i].range.location
            }
        }
        var skip = 0
        while skip < min(skipWords, words.count),
              wakeWords.contains(where: { Self.similar(words[skip], $0) || Self.soundsAlike(words[skip], $0) }) { skip += 1 }
        if skip == 0 { return 0 }
        let last = tokens[skip - 1].range
        return last.location + last.length
    }

    private func newTask(replay: Bool = false) {
        task?.cancel()
        transcript = ""
        generation += 1
        let gen = generation
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition == true   // audio stays on this Mac when it can
        r.contextualStrings = [wakePhrase] + wakeWords
        r.taskHint = .dictation
        r.addsPunctuation = true   // a final "." or "?" is the recognizer's own sign that a sentence is complete
        lock.lock()
        if replay { recent.forEach { r.append($0) } }   // words spoken while recognition restarted aren't lost
        request = r
        lock.unlock()
        taskStart = Date()
        task = recognizer?.recognitionTask(with: r) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let result { self.heard(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true { self.taskEnded() }
            }
        }
    }

    func heard(_ text: String) {   // internal for tests/
        lastHeard = Date()
        let ns = text as NSString
        transcript = text
        let wake = wakeEnd(in: text)
        if !capturing {
            if wakeEnabled, wake != nil {
                capturing = true; viaWake = true; followingUp = false; command = ""; carried = ""; fresh = ""
                quietLimit = 8; captureStart = Date(); lastChange = Date()
                onNote("Woke on “\(text)”")
                onWake()
            } else if let spoken = speechWords, let at = interruption(in: text, spoken) {
                capturing = true; viaWake = false; followingUp = false; command = ""; carried = ""; fresh = ""; skipWords = at
                speechWords = nil; pausedForVoiceAt = nil
                quietLimit = 8; captureStart = Date(); lastChange = Date()
                onNote("Interrupted on “\(text)”")
                onBargeIn()
            } else { return }
        }
        // Recognition revises earlier words as it goes, so look for the wake phrase again on every update. If the
        // rewrite no longer matches it ("Hey Otto" → "Hey order"), skip as many words as the phrase took.
        // Said anyway after the hotkey or during a follow-up, it is still left out of the request.
        if let wake { skipWords = wake.words }
        let start = wake?.offset ?? (viaWake ? requestStart(in: text) : Self.offset(afterWords: skipWords, in: text))
        guard let start, start <= ns.length else { return }
        fresh = ns.substring(from: start).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?\n"))
        let heardCommand = [carried, fresh].filter { !$0.isEmpty }.joined(separator: " ")
        if heardCommand != command {
            command = heardCommand; lastChange = Date()
            onPartial(heardCommand)
        }
    }

    func taskEnded() {   // internal for tests/
        guard capturing else { return newTask() }
        // Recognition stopped in the middle of a request: keep what was heard and go on listening, replaying the last
        // moments of audio so nothing said during the restart is lost. Silence, not the restart, ends the request.
        onNote("Recognition restarted mid-request after “\(transcript)”")
        let replay = command.isEmpty   // nothing heard yet: replaying can't repeat words already in the request
        carried = command; fresh = ""; viaWake = false; skipWords = 0
        newTask(replay: replay)
    }

    /// How long a silence ends this request: longer when it sounds unfinished.
    /// How long a silence ends this request. Like a person: quickly after a finished sentence ("…tomorrow?"), longer
    /// when it trails off ("…check my", "…and") or is only a word or two.
    func pauseNeeded(for request: String) -> TimeInterval {   // internal for tests/
        let words = Self.words(request)
        if let last = words.last, Self.unfinished.contains(last) { return pauseToEnd + 1.2 }
        if words.count <= 2 { return pauseToEnd + 0.8 }
        let finished = request.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false
        return finished ? max(0.7, pauseToEnd * 0.45) : pauseToEnd
    }

    private func tick() {
        let now = Date()
        if shouldListen, !engine.isRunning, rebuildWork == nil, now.timeIntervalSince(lastRebuild) > 5 {
            return rebuild("Microphone isn't running")   // watchdog: a failed start or a missed device change
        }
        if speechWords != nil, echoCancelling, !capturing {
            // Like a person: stop as soon as someone starts talking, and carry on if they didn't say anything.
            lock.lock(); let since = voiceSince; lock.unlock()
            if let paused = pausedForVoiceAt {
                if since == nil, now.timeIntervalSince(paused) > 1.5 {
                    pausedForVoiceAt = nil
                    onNote("Heard a sound but no words; carrying on")
                    onFalseAlarm()
                }
            } else if let since, now.timeIntervalSince(since) >= 0.3 {
                pausedForVoiceAt = now
                onVoiceDuringSpeech()
            }
        }
        if capturing {
            lock.lock(); let voice = voiceAt; lock.unlock()
            let quiet = now.timeIntervalSince(max(lastChange, voice))   // no new words and no voice-level sound
            if !command.isEmpty, quiet > pauseNeeded(for: command) { finish() }
            else if command.isEmpty, now.timeIntervalSince(captureStart) > quietLimit { giveUp() }
        } else if now.timeIntervalSince(taskStart) > 45, now.timeIntervalSince(lastHeard) > 1.5 {
            newTask()   // keep the transcript short; recognition tasks also stop on their own after a while
        }
    }

    private func finish() {
        let heardCommand = command
        onNote("Heard “\(transcript)” → sent “\(heardCommand)”")
        capturing = false; followingUp = false; command = ""; carried = ""; fresh = ""; skipWords = 0
        newTask(); stopIfIdle()
        onCommand(heardCommand)
    }

    private func giveUp() {
        if !followingUp { onNote("Woke but heard no request" + (transcript.isEmpty ? "" : "; last transcript: “\(transcript)”")) }
        capturing = false; followingUp = false; command = ""; carried = ""; fresh = ""; skipWords = 0
        newTask(); stopIfIdle()
        onGiveUp()
    }
}

// MARK: - Speaking

/// Reads answers aloud. Each sentence is rendered by macOS's `say`, so it's in the System Voice from System Settings →
/// Accessibility → Spoken Content (including the free Siri and Premium voices, which apps can't use directly), and played
/// through the listener's audio engine, so echo cancellation can keep it out of the microphone. Streams: sentences are
/// spoken as the answer arrives, the next one rendering while the current one plays.
final class Speaker {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    var onStart: () -> Void = {}
    var onAudible: (Bool) -> Void = { _ in }   // sound starts or stops (streaming can go quiet while Claude works)
    var onFinish: (_ completed: Bool) -> Void = { _ in }   // false: stopped or interrupted
    var onError: (String) -> Void = { _ in }
    var output: () -> AVAudioPlayerNode? = { nil }   // the player on the listener's running engine
    var voice = ""   // a `say -v` name; empty: the System Voice
    private(set) var speaking = false   // from begin() until everything has played, or it's stopped
    private(set) var paused = false
    private var open = false   // more text may still arrive
    private var pending = ""   // text that isn't a whole sentence yet
    private var queue: [String] = []   // sentences waiting to be rendered
    private var renderer: Process?
    private var playing = 0   // rendered sentences scheduled and not yet heard
    private var started = false
    private var generation = 0   // bumped on stop: late callbacks from the old speech are ignored

    static let novelty: Set<String> = ["Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Good News", "Jester", "Junior",
                                       "Organ", "Ralph", "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox", "Fred", "Kathy"]

    /// Installed voices for the system language, as `say -v ?` names.
    static func voices() -> [String] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = ["-v", "?"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let language = String((Locale.preferredLanguages.first ?? "en").prefix(2))
        let line = try! NSRegularExpression(pattern: #"^(.+?)\s+([a-z]{2,3})_[A-Za-z0-9]+\s+#"#, options: [.anchorsMatchLines])
        var names: [String] = []
        for m in line.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let ns = text as NSString
            let name = ns.substring(with: m.range(at: 1)), lang = ns.substring(with: m.range(at: 2))
            if lang == language && !novelty.contains(name) && !names.contains(name) { names.append(name) }
        }
        return names
    }

    func say(_ text: String) { begin(); feed(text); end() }

    /// Starts a spoken answer; text follows with feed() and end().
    func begin() {
        halt()
        speaking = true; open = true; started = false
    }

    func feed(_ text: String) {
        guard speaking, open else { return }
        pending += text
        queue += Self.sentences(from: &pending, first: !started && queue.isEmpty && renderer == nil)
        pump()
    }

    /// The text so far was narration cut short by a tool call: its unfinished sentence won't be completed.
    func dropUnfinished() { pending = "" }

    func end() {
        guard speaking, open else { return }
        open = false
        let rest = Self.spoken(pending).trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        if !rest.isEmpty { queue.append(rest) }
        pump(); finishIfDone()
    }

    func pause() {
        guard speaking, !paused else { return }
        paused = true
        output()?.pause()
    }

    func resume() {
        guard paused else { return }
        paused = false
        if playing > 0 { output()?.play() }
    }

    func stop() {
        guard speaking else { return }
        halt()
        onFinish(false)
    }

    private func halt() {
        generation += 1
        renderer?.terminate(); renderer = nil
        queue = []; pending = ""
        if playing > 0 { output()?.stop() }
        playing = 0; paused = false; speaking = false
    }

    /// Renders the next sentence while the previous one plays.
    private func pump() {
        guard renderer == nil, !queue.isEmpty else { return }
        let sentence = queue.removeFirst(), gen = generation
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("otto-\(UUID().uuidString).caf")
        let p = Process(), input = Pipe(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // Text on stdin, last: nothing in it can be read as an option (and stopOrphans() recognizes the command).
        p.arguments = (voice.isEmpty ? [] : ["-v", voice]) + ["--data-format=LEF32@24000", "-o", file.path, "-f", "-"]
        p.standardInput = input; p.standardError = errors; p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] ended in
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: file) }
                guard let self, gen == self.generation else { return }
                self.renderer = nil
                if ended.terminationReason == .exit && ended.terminationStatus == 0 {
                    self.play(file, gen)
                } else if ended.terminationReason == .exit {
                    self.onError("say exited \(ended.terminationStatus): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                self.pump(); self.finishIfDone()
            }
        }
        do { try p.run() } catch { onError("couldn't run say: \(error.localizedDescription)"); return }
        renderer = p
        input.fileHandleForWriting.write(Data(sentence.utf8))
        try? input.fileHandleForWriting.close()
    }

    private func play(_ file: URL, _ gen: Int) {
        guard let audio = try? AVAudioFile(forReading: file), audio.processingFormat == Self.format,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: buffer)) != nil else { return onError("couldn't read the rendered speech") }
        guard let player = output() else { return onError("the audio engine isn't running") }
        if playing == 0 { onAudible(true) }
        playing += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.playing -= 1
                if self.playing == 0 { self.onAudible(false) }
                self.finishIfDone()
            }
        }
        if !paused && !player.isPlaying { player.play() }
        if !started { started = true; onStart() }
    }

    private func finishIfDone() {
        guard speaking, !open, queue.isEmpty, renderer == nil, playing == 0 else { return }
        speaking = false
        onFinish(true)
    }

    /// Takes the whole sentences off the front of the text, cleaned up for speaking; what's left stays in `text`.
    /// `first`: nothing has been spoken yet, so a long opening clause ("Your next meeting is at three,") goes on its own
    /// to start talking sooner.
    static func sentences(from text: inout String, first: Bool = false) -> [String] {
        let end = try! NSRegularExpression(pattern: #"[.!?…]+["')\]]*\s+|\n+"#)
        var found: [String] = []
        if first, end.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil,
           let clause = try! NSRegularExpression(pattern: #"^.{30,}?[,;:—–]\s+"#).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(clause.range, in: text) {
            found.append(spoken(String(text[..<r.upperBound])).trimmingCharacters(in: .whitespacesAndNewlines))
            text = String(text[r.upperBound...])
        }
        while let m = end.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range, in: text) {
            let sentence = spoken(String(text[..<r.upperBound])).trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[r.upperBound...])
            if !sentence.isEmpty { found.append(sentence) }
        }
        return found
    }

    /// Speech left playing by an earlier run that crashed: `say` reading from stdin, orphaned to launchd.
    static func stopOrphans() {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "pid=,ppid=,command="]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), parts[1] == "1",
                  parts[2].hasPrefix("/usr/bin/say "), parts[2].hasSuffix(" -f -") else { continue }
            kill(pid, SIGTERM)
        }
    }

    static func spoken(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "the link", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_#`>|]"#, with: "", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

// MARK: - Panel

struct TaskRow: Equatable {
    let id: Int, title: String, status: AgentTask.Status, detail: String
}

final class UIState: ObservableObject {
    enum Phase { case listening, working, answered, failed }
    @Published var phase = Phase.listening
    @Published var heard = ""
    @Published var steps: [String] = []
    @Published var answer = ""
    @Published var speaking = false
    @Published var followUp = false   // listening for a reply to the answer on screen
    @Published var attachment = ""   // a window attached to the next request (both ⌘ keys)
    @Published var tasks: [TaskRow] = []   // background tasks: running, and just finished
    @Published var question = ""   // a permission being asked: shown with Allow and Deny
    var respond: (Bool) -> Void = { _ in }
}

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// The animated orb: the thinking-orbs engine (orbs.js, MIT, Jakub Antalik) drawing on a canvas.
/// The web view only draws. It has no script handlers, loads nothing, refuses every navigation and ignores clicks and drops.
final class OrbWebView: WKWebView {
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class OrbNavigation: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
}

struct OrbView: NSViewRepresentable {
    enum Mode: String { case listening, working, searching, composing, breathing }   // thinking-orbs state names
    var mode: Mode
    static let navigation = OrbNavigation()

    static let engine: String? = Bundle.main.resourcePath
        .flatMap { try? String(contentsOfFile: $0 + "/orbs.js", encoding: .utf8) }
        .map { $0.replacingOccurrences(of: "</script", with: "<\\/script") }

    func makeNSView(context: Context) -> NSView {
        guard let engine = Self.engine else {   // a bare binary without the bundle's resources: a plain symbol instead
            return NSImageView(image: NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) ?? NSImage())
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = OrbWebView(frame: NSRect(x: 0, y: 0, width: 44, height: 44), configuration: config)
        web.unregisterDraggedTypes()
        web.navigationDelegate = Self.navigation
        web.setValue(false, forKey: "drawsBackground")
        web.loadHTMLString("""
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
            <style>html,body{margin:0;background:transparent;overflow:hidden}canvas{display:block;width:44px;height:44px}</style>
            </head><body><canvas id="orb" width="128" height="128"></canvas>
            <script>\(engine)</script>
            <script>
            const E = window.Orbs, ctx = document.getElementById('orb').getContext('2d'), S = 64;
            const reduced = matchMedia('(prefers-reduced-motion: reduce)');
            let state = '\(mode.rawValue)', preset = E.r(state, S), t = 0, prev = performance.now();
            window.setOrb = s => { if (s !== state) { state = s; preset = E.r(s, S); } };
            (function frame(now) {
              t += Math.min(0.05, (now - prev) / 1000) * preset.speed * (reduced.matches ? 0 : 1);
              prev = now;
              ctx.setTransform(2, 0, 0, 2, 0, 0); ctx.clearRect(0, 0, S, S);
              E.p(ctx, E.M[preset.mode](S, t, preset.opts), true, null);
              requestAnimationFrame(frame);
            })(prev);
            </script></body></html>
            """, baseURL: nil)
        return web
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? WKWebView)?.evaluateJavaScript("window.setOrb && setOrb('\(mode.rawValue)')")   // a fixed state name, never outside text
    }
}

/// The status line beside the orb, with a light sweeping across it while Claude listens or works.
struct StatusText: View {
    let text: String
    let live: Bool
    @State private var sweep: CGFloat = -0.6

    var body: some View {
        let label = Text(text).font(.system(size: 12.5)).lineLimit(1)
        label.foregroundStyle(Color(white: 0.78))
            .overlay {
                if live {
                    LinearGradient(colors: [.clear, .white, .clear], startPoint: UnitPoint(x: sweep, y: 0.5), endPoint: UnitPoint(x: sweep + 0.6, y: 0.5))
                        .mask(label)
                        .onAppear {
                            sweep = -0.6
                            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { sweep = 1.2 }
                        }
                }
            }
    }
}

struct PanelView: View {
    @ObservedObject var state: UIState
    var onTap: () -> Void

    var live: Bool { state.phase == .listening || state.phase == .working }

    var title: String {
        switch state.phase {
        case .listening: return state.followUp ? "Listening for a reply…" : "Listening…"
        case .working: return "Working…"
        case .answered: return state.speaking ? "Speaking" : "Done"
        case .failed: return "That didn't work"
        }
    }

    var orb: OrbView.Mode {
        switch state.phase {
        case .listening: return .listening
        case .working:
            let browsing = state.steps.last.map { $0.hasPrefix("Chrome") || $0.hasPrefix("Searching") || $0.hasPrefix("Fetching") } ?? false
            return browsing ? .searching : .working
        case .answered: return state.speaking ? .composing : .breathing
        case .failed: return .breathing
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                OrbView(mode: orb).frame(width: 44, height: 44).padding(.leading, -4)
                StatusText(text: title, live: live)
                Spacer(minLength: 0)
            }
            .frame(height: 44)

            if !state.attachment.isEmpty {
                Label(state.attachment, systemImage: "macwindow")
                    .font(.system(size: 11.5)).foregroundStyle(Color(white: 0.8)).lineLimit(1).truncationMode(.middle)
                    .padding(.vertical, 4).padding(.horizontal, 9)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .padding(.top, 4)
            }

            if !state.heard.isEmpty {   // what you said, as a chat bubble on the right
                HStack {
                    Spacer(minLength: 80)
                    Text(state.heard)
                        .font(.system(size: state.phase == .listening ? 15 : 13.5))
                        .foregroundStyle(state.phase == .listening ? Color.white : Color(white: 0.9))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 9).padding(.horizontal, 14)
                        .background(
                            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.09))
                                .overlay(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                        )
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }

            if !state.steps.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(state.steps.suffix(4).enumerated()), id: \.offset) { index, step in
                        let current = state.phase == .working && index == min(state.steps.count, 4) - 1
                        HStack(spacing: 7) {
                            Circle().fill(current ? Color.white : Color(white: 0.5)).frame(width: 4, height: 4)
                            Text(step).font(.system(size: 12)).foregroundStyle(Color(white: current ? 0.9 : 0.7))
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .padding(.top, 12)
            }

            if !state.question.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label(state.question, systemImage: "hand.raised")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Allow") { state.respond(true) }.keyboardShortcut(.defaultAction)
                        Button("Deny") { state.respond(false) }
                        Text("or say yes / no").font(.system(size: 11)).foregroundStyle(Color(white: 0.6))
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.16)))
                .padding(.top, 14)
            }

            if !state.answer.isEmpty {
                Text(state.answer)
                    .font(.system(size: 15))
                    .foregroundStyle(state.phase == .failed ? Color(red: 1, green: 0.62, blue: 0.5) : Color.white)
                    .lineSpacing(5)
                    .lineLimit(16)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                    .transition(.opacity)
            }

            if !state.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(state.tasks, id: \.id) { task in
                        HStack(spacing: 7) {
                            Image(systemName: task.status == .running ? "circle.dotted" : task.status == .finished ? "checkmark.circle.fill"
                                  : task.status == .failed ? "exclamationmark.circle" : "xmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(task.status == .finished ? Color.green.opacity(0.8) : task.status == .failed ? Color.orange : Color(white: 0.7))
                                .symbolEffect(.pulse, isActive: task.status == .running)
                            Text("#\(task.id) \(task.title)").font(.system(size: 12, weight: .medium)).foregroundStyle(Color(white: 0.9)).lineLimit(1)
                            Text(task.detail).font(.system(size: 11)).foregroundStyle(Color(white: 0.6)).lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                .padding(.top, 14)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 440, alignment: .leading)
        .background(Blur().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: state.heard.isEmpty)
        .animation(.easeOut(duration: 0.25), value: state.answer.isEmpty)
        .contentShape(Rectangle())
        .onTapGesture { if state.question.isEmpty { onTap() } }   // not while a question waits for its answer
    }
}

final class Panel {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init(state: UIState) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 80), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        let host = NSHostingController(rootView: PanelView(state: state, onTap: {}))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        host.rootView = PanelView(state: state, onTap: { [weak self] in self?.hide(after: 0) })
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in self?.anchor() }
    }

    private func anchor() {   // top right, under the menu bar, growing downward
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame, size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 12))
    }

    func show() {
        hideWork?.cancel()
        anchor()
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    }

    func hide(after seconds: TimeInterval, unless keep: @escaping () -> Bool = { false }) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !keep() else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.panel.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                                                     guard let self, self.panel.alphaValue == 0 else { return }   // shown again meanwhile
                                                     self.panel.orderOut(nil)
                                                 })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - Global hotkey (⌃⌥Space)

var hotkeyAction: (() -> Void)?
var hotkeyRef: EventHotKeyRef?

func registerHotkey(_ action: @escaping () -> Void) {
    hotkeyAction = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { hotkeyAction?() }
        return noErr
    }, 1, &spec, nil, nil)
    let id = EventHotKeyID(signature: OSType(0x4843_4C44), id: 1)   // "HCLD"
    RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotkeyRef)
}

// MARK: - Log

final class Log {
    let url: URL
    private let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Otto")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("Otto.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    }

    func write(_ text: String) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((stamp.string(from: Date()) + " " + text + "\n").utf8))
    }
}

// MARK: - App

final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = UIState()
    lazy var panel = Panel(state: state)
    let listener = Listener()
    let claude = ClaudeSession()
    let speaker = Speaker()
    let log = Log()
    let defaults = UserDefaults.standard
    var statusItem: NSStatusItem!
    var actions: [MenuAction] = []
    var replyExpected = false   // the answer being spoken invites a reply: listen once it ends
    // Speaking the answer while it streams in: this turn's answer may be spoken; whether speech has begun; how much is fed.
    var speakingTurn = false, streamStarted = false, streamedChars = 0
    var speechText = ""   // everything fed to the speaker for this answer: the listener tells echo from the user with it
    var wakePhrase: String { defaults.string(forKey: "wakePhrase") ?? "Hey Otto" }

    // Two layers (like ChatGPT's voice): a fast voice that talks and starts tasks; workers that do them in the background.
    let voice = ClaudeSession()
    let board = TaskBoard()
    var twoLayer: Bool { defaults.bool(forKey: "twoLayer") }
    var brain: ClaudeSession { twoLayer ? voice : claude }   // whoever answers the user right now
    var filter = DirectiveFilter()   // the voice reply's tags, kept out of speech
    var shownAnswer = ""   // the voice reply without its tags
    var turnContext = "", turnImage = ""   // what this request came with (front app, window): passed on to tasks it starts
    var announcements: [String] = []   // finished tasks waiting for a quiet moment to be told
    var pendingAppshot: Appshot?   // a window attached with both ⌘ keys, for the next request
    var doubleCommand: DoubleCommand?
    var ticker: Timer?
    // Ask Before Risky Actions: what Claude Code wants an OK for, asked one at a time.
    var fullAccess: Bool { defaults.string(forKey: "access") == "full" }
    var permissions: [PermissionRequest] = []
    var asking: PermissionRequest?, askedAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["wake": true, "wakePhrase": "Hey Otto", "followUp": true, "speak": true, "voice": "", "model": "", "freshMinutes": 15.0, "pause": 1.8, "echo": true, "claudeConfig": "", "twoLayer": true, "access": "ask"])
        claude.configDir = ClaudeSession.resolveConfigDir(defaults.string(forKey: "claudeConfig") ?? "")
        listener.echoCancellation = defaults.bool(forKey: "echo")
        listener.pauseToEnd = defaults.double(forKey: "pause")
        listener.wakePhrase = wakePhrase
        speaker.voice = defaults.string(forKey: "voice") ?? ""
        claude.model = defaults.string(forKey: "model") ?? ""
        claude.freshAfter = defaults.double(forKey: "freshMinutes") * 60
        voice.role = .voice
        voice.configDir = claude.configDir
        voice.freshAfter = claude.freshAfter
        claude.fullAccess = fullAccess
        board.configure = { [unowned self] session in
            session.configDir = claude.configDir; session.model = claude.model; session.fullAccess = fullAccess
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        let menu = NSMenu()
        menu.delegate = self; menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        listener.onWake = { [weak self] in self?.woke() }
        listener.onFollowUp = { [weak self] in self?.listeningForReply() }
        listener.onPartial = { [weak self] text in
            guard let self else { return }
            if self.state.followUp && !text.isEmpty {   // a reply has started: make room for it
                self.state.followUp = false; self.state.steps = []; self.state.answer = ""
            }
            self.state.heard = text
        }
        listener.onCommand = { [weak self] text in self?.handle(text) }
        listener.onGiveUp = { [weak self] in self?.gaveUp() }
        listener.onNote = { [weak self] note in self?.log.write("🎙 " + note) }
        listener.onBargeIn = { [weak self] in self?.interrupted() }
        listener.onVoiceDuringSpeech = { [weak self] in self?.speaker.pause() }
        listener.onFalseAlarm = { [weak self] in self?.speaker.resume() }
        listener.onEngineReset = { [weak self] in self?.speaker.stop() }
        speaker.output = { [weak self] in self?.listener.output() }
        speaker.onAudible = { [weak self] on in
            guard let self else { return }
            on ? self.listener.listenDuringSpeech(self.speechText) : self.listener.speechEnded()
        }
        claude.onStep = { [weak self] step in self?.state.steps.append(step); self?.log.write("  " + step) }
        claude.onText = { [weak self] text in
            self?.state.answer = text
            self?.streamSpeech(text)
        }
        claude.onDone = { [weak self] text, failed in self?.finished(text, failed) }
        voice.onText = { [weak self] text in self?.voiceText(text) }
        voice.onDone = { [weak self] text, failed in self?.voiceDone(text, failed) }
        board.onStep = { [weak self] task, step in self?.log.write("  #\(task.id) " + step) }
        board.onChange = { [weak self] in self?.refreshTasks() }
        board.onFinished = { [weak self] task in self?.taskFinished(task) }
        board.onPermission = { [weak self] request in self?.permissionRequested(request) }
        claude.onPermission = { [weak self] request in self?.permissionRequested(request) }
        state.respond = { [weak self] allow in self?.answerPermission(allow) }
        doubleCommand = DoubleCommand { [weak self] in self?.attachWindow() }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in   // task clocks, and telling finished tasks
            guard let self else { return }
            if !self.board.running.isEmpty { self.refreshTasks() }
            self.checkPermissions()
            self.drainAnnouncements()
        }
        speaker.onStart = { [weak self] in self?.state.speaking = true }
        speaker.onError = { [weak self] problem in self?.log.write("🔇 " + problem) }
        speaker.onFinish = { [weak self] completed in
            guard let self else { return }
            self.state.speaking = false
            self.listener.speechEnded()
            self.listener.holdAudio(false)
            if completed { self.log.write("🔊 spoken") }
            let listen = completed && self.replyExpected
            self.replyExpected = false
            if listen { self.listener.beginCapture(followUp: true) } else { self.hideSoon(6) }
        }
        registerHotkey { [weak self] in self?.hotkey() }

        SFSpeechRecognizer.requestAuthorization { speech in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if speech == .authorized && mic {
                        self.listener.wakeEnabled = self.defaults.bool(forKey: "wake")
                    } else {
                        self.show(failure: "Otto needs Microphone and Speech Recognition access. Turn them on in System Settings → Privacy & Security, then reopen Otto.")
                    }
                    self.updateIcon()
                }
            }
        }
        if !defaults.bool(forKey: "askedPermissions") {   // once: the rest are asked for from the menu
            defaults.set(true, forKey: "askedPermissions")
            askForControlPermissions()
        }
        DispatchQueue.global().async { Speaker.stopOrphans() }
        log.write("Started")
    }

    func applicationWillTerminate(_ notification: Notification) { cleanUp() }

    /// Quitting must take the voice and Claude Code with it: both run as separate processes that would outlive the app.
    func cleanUp() {
        replyExpected = false
        speaker.stop()
        claude.reset(); voice.reset(); board.shutdown()
    }

    // Flow

    func woke() {
        replyExpected = false; speakingTurn = false   // a new request is coming: don't read the old answer over it
        speaker.stop()
        NSSound(named: "Tink")?.play()
        state.phase = .listening; state.followUp = false; state.heard = ""
        if !brain.busy { state.steps = []; state.answer = "" }
        panel.show(); updateIcon()
    }

    /// Reads text aloud, listening meanwhile so the user can talk over it.
    func speak(_ text: String, expectReply: Bool = false) {
        speechText = text
        listener.holdAudio(true)
        speaker.say(text)
        replyExpected = expectReply
    }

    /// Speaks the answer as it streams in, a sentence at a time. A tool call resets the text (what came before was narration).
    func streamSpeech(_ text: String) {
        guard speakingTurn else { return }
        if text.count < streamedChars { speaker.dropUnfinished(); streamedChars = 0 }
        let more = String(text.dropFirst(streamedChars))
        streamedChars = text.count
        speakMore(more)
    }

    /// Adds text to the answer being spoken (starting it if needed).
    func speakMore(_ more: String) {
        guard speakingTurn, defaults.bool(forKey: "speak"), !more.isEmpty else { return }
        if !streamStarted {
            streamStarted = true; replyExpected = false; speechText = ""
            listener.holdAudio(true)
            speaker.begin()
        }
        speechText += more
        listener.speaking(more: more)
        speaker.feed(more)
    }

    func interrupted() {   // talked over the answer: stop reading it and take what they're saying as the next request
        replyExpected = false; speakingTurn = false
        speaker.stop()
        if brain.busy { brain.stop() }   // they're redirecting it: the rest of that answer isn't wanted (background tasks go on)
        state.phase = .listening; state.followUp = false; state.heard = ""; state.steps = []; state.answer = ""
        panel.show(); updateIcon()
    }

    func listeningForReply() {   // after an answer: the answer stays on screen while it listens, without a chime
        state.phase = .listening; state.followUp = true
        panel.show(); updateIcon()
    }

    func gaveUp() {
        let wasFollowUp = state.followUp
        state.followUp = false
        if !wasFollowUp { pendingAppshot = nil; state.attachment = "" }   // attached, but nothing asked about it
        if brain.busy { state.phase = .working } else {
            if wasFollowUp { state.phase = .answered }
            hideSoon(wasFollowUp ? 2 : 0)
        }
        updateIcon()
    }

    func hotkey() {
        if speaker.speaking && !listener.capturing { speaker.stop() }
        listener.beginCapture()
    }

    func handle(_ text: String, context: String? = nil) {
        let plain = String(text.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " || $0 == "'" }).trimmingCharacters(in: .whitespaces)
        if asking != nil, let allow = yesOrNo(plain) {   // the answer to "Is that okay?"
            log.write("» " + text)
            return answerPermission(allow)
        }
        if ["stop", "stop it", "cancel", "never mind", "nevermind", "shut up", "be quiet", "quiet", "thats enough",
              "wait", "hold on", "enough", "okay stop", "ok stop", "pause"].contains(plain) { return stopAll() }
        if ["new conversation", "start over", "new chat", "reset", "forget that"].contains(plain) {
            claude.reset(); voice.reset()
            state.phase = .answered; state.heard = text; state.steps = []; state.answer = "Okay, starting fresh."
            log.write("» " + text + " (new conversation)")
            return respond("Okay, starting fresh.")
        }
        beginTurn(heard: text)
        log.write("» " + text)
        // What the user is looking at: selected text always; the window's text when they point at it ("summarize this")
        // or attached it with both ⌘ keys (then with a picture too). Read off the main thread: big windows take a moment.
        let attached = pendingAppshot
        pendingAppshot = nil; state.attachment = ""
        let pointing = attached != nil || Appshot.pointsAtScreen.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        let base = context ?? contextLine()
        DispatchQueue.global(qos: .userInitiated).async {
            let shot = attached ?? Appshot.capture(text: pointing, image: false)
            DispatchQueue.main.async { [self] in
                turnContext = [base, shot?.context(includeText: pointing) ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
                turnImage = shot?.imagePath ?? ""
                if let shot, pointing || !shot.selected.isEmpty {
                    let parts = [shot.selected.isEmpty ? nil : "selected text", pointing && !shot.text.isEmpty ? "window text" : nil,
                                 shot.imagePath.isEmpty ? nil : "window picture"].compactMap { $0 }
                    if !parts.isEmpty { log.write("  with " + parts.joined(separator: ", ") + " from " + shot.label) }
                }
                if twoLayer {
                    voice.send([turnContext, board.summary(), text].filter { !$0.isEmpty }.joined(separator: "\n"), image: turnImage)
                } else {
                    claude.send(turnContext + "\n" + text, image: turnImage)
                }
            }
        }
    }

    /// A new answer is coming: clear the panel and get ready to speak it as it streams.
    func beginTurn(heard: String) {
        state.phase = .working; state.heard = heard; state.steps = []; state.answer = ""
        speakingTurn = true; streamStarted = false; streamedChars = 0
        filter = DirectiveFilter(); shownAnswer = ""
        panel.show(); updateIcon()
    }

    // MARK: Voice layer and background tasks

    func voiceText(_ text: String) {
        guard text.count >= streamedChars else { return }   // the voice has no tools, so its text only grows
        let more = String(text.dropFirst(streamedChars))
        streamedChars = text.count
        let (speech, directives) = filter.feed(more)
        shownAnswer += speech
        state.answer = shownAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        run(directives)
        speakMore(speech)
    }

    func voiceDone(_ text: String, _ failed: Bool) {
        let (speech, directives) = filter.finish()
        shownAnswer += speech
        run(directives)
        speakMore(speech)
        finished(failed ? text : shownAnswer.trimmingCharacters(in: .whitespacesAndNewlines), failed)
    }

    func run(_ directives: [Directive]) {
        for directive in directives {
            switch directive {
            case .start(let title, let instruction):
                // The worker gets what the request came with (front app, window text, picture) without the voice copying it.
                let task = board.start(title: title, instruction: [turnContext, instruction].filter { !$0.isEmpty }.joined(separator: "\n"), image: turnImage)
                log.write("◆ #\(task.id) “\(title)”: " + instruction.replacingOccurrences(of: "\n", with: " "))
                state.steps.append("Started #\(task.id): \(title)")
            case .steer(let id, let text):
                guard board.steer(id, text) else { continue }
                log.write("◆ #\(id) steered: " + text)
                state.steps.append("Updated #\(id)")
            case .cancel(let id):
                guard board.cancel(id) else { continue }
                log.write("◆ #\(id) cancelled")
                state.steps.append("Cancelled #\(id)")
            }
        }
    }

    func taskFinished(_ task: AgentTask) {
        log.write("◆ #\(task.id) \(task.status.rawValue) after \(task.elapsed): " + task.result.replacingOccurrences(of: "\n", with: " "))
        guard twoLayer else { return }
        announcements.append(task.status == .finished
            ? "[Task #\(task.id) “\(task.title)” finished]\n\(task.result.prefix(4000))\n[Tell the user the outcome briefly.]"
            : "[Task #\(task.id) “\(task.title)” failed]\n\(task.result.prefix(1000))\n[Tell the user briefly and offer to try again.]")
        drainAnnouncements()
    }

    /// Tells finished tasks one at a time, when nobody is talking.
    func drainAnnouncements() {
        guard twoLayer, !announcements.isEmpty, asking == nil, permissions.isEmpty, !voice.busy, !listener.capturing, !speaker.speaking else { return }
        let message = announcements.removeFirst()
        beginTurn(heard: "")
        turnContext = contextLine(); turnImage = ""
        voice.send([turnContext, board.summary(), message].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    // MARK: Asking before risky actions

    func permissionRequested(_ request: PermissionRequest) {
        log.write("✋ " + (request.taskID.map { "#\($0) " } ?? "") + "asks to " + request.spoken + "  [" + ClaudeSession.describe(request.tool, request.input) + "]")
        permissions.append(request)
        checkPermissions()
    }

    /// Asks the next waiting question when nobody is talking; a question nobody answers is a no after two minutes.
    func checkPermissions() {
        permissions.removeAll { $0.session?.busy != true }   // its task ended or was cancelled meanwhile
        if let current = asking, current.session?.busy != true || Date().timeIntervalSince(askedAt) > 120 {
            if current.session?.busy == true { log.write("✋ No answer in two minutes: denied") }
            answerPermission(false, quietly: true)
        }
        guard asking == nil, !permissions.isEmpty, !listener.capturing, !speaker.speaking else { return }
        let request = permissions.removeFirst()
        asking = request; askedAt = Date()
        let who = request.taskID.flatMap { id in board.tasks.first { $0.id == id } }.map { "Task \($0.id), \($0.title)," } ?? "Claude"
        state.question = "\(who) wants to \(request.spoken)."
        state.phase = .answered; state.heard = ""; state.answer = ""
        panel.show(); updateIcon()
        speakingTurn = true; streamStarted = false
        if defaults.bool(forKey: "speak") { speak("\(who) wants to \(request.spoken). Is that okay?", expectReply: true) }
        else { listener.beginCapture(followUp: true) }
    }

    func answerPermission(_ allow: Bool, quietly: Bool = false) {
        guard let request = asking else { return }
        asking = nil; state.question = ""
        request.session?.answer(request, allow: allow)
        if let id = request.taskID { board.tasks.first { $0.id == id }?.waiting = nil; refreshTasks() }
        log.write("✋ " + (allow ? "Allowed" : "Denied") + ": " + request.spoken)
        guard !quietly else { return checkPermissions() }
        state.phase = .answered; state.answer = allow ? "Allowed." : "Okay, not doing that."
        if defaults.bool(forKey: "speak") { speak(allow ? "Okay." : "Okay, I won't.") } else { hideSoon(3) }
    }

    /// A spoken yes or no to the question being asked, or nil if it's something else.
    func yesOrNo(_ plain: String) -> Bool? {
        let first = plain.split(separator: " ").prefix(2).joined(separator: " ")
        for no in ["no", "nope", "dont", "don't", "deny", "stop", "cancel", "wait", "never"] where first == no || first.hasPrefix(no + " ") { return false }
        for yes in ["yes", "yeah", "yep", "sure", "allow", "go ahead", "do it", "okay", "ok", "approve", "fine", "go for it", "proceed", "please do"]
        where first == yes || first.hasPrefix(yes + " ") || plain.hasPrefix(yes) { return true }
        return nil
    }

    func refreshTasks() {
        let now = Date()
        let shown = board.tasks.filter { $0.status == .running || now.timeIntervalSince($0.ended ?? now) < 90 }.suffix(4)
        state.tasks = shown.map { t in
            TaskRow(id: t.id, title: t.title, status: t.status, detail: t.status == .running ? t.elapsed + (t.steps.last.map { " · " + $0 } ?? "") : t.elapsed)
        }
        let running = board.running.count
        statusItem?.button?.title = running > 0 ? " \(running)" : ""
    }

    /// Both ⌘ keys: attach the front window (text and picture) and listen for what to do with it.
    func attachWindow() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let shot = Appshot.capture(text: true, image: true) else { return }
            DispatchQueue.main.async { [self] in
                pendingAppshot = shot
                state.attachment = shot.label
                log.write("📎 Attached " + shot.label + " (\(shot.text.count) characters of text" + (shot.imagePath.isEmpty ? ")" : " and a picture)"))
                if listener.capturing { panel.show() } else { listener.beginCapture() }
            }
        }
    }

    func finished(_ text: String, _ failed: Bool) {
        let streamed = speakingTurn && streamStarted
        speakingTurn = false; streamStarted = false
        state.phase = failed ? .failed : .answered
        state.answer = text
        log.write((failed ? "✗ " : "✓ ") + text.replacingOccurrences(of: "\n", with: " "))
        updateIcon()
        if failed {
            if streamed { speaker.stop() }
            return show(failure: text)
        }
        if listener.capturing { return panel.show() }   // the user is already saying something else: show it, don't read it over them
        guard streamed else { return respond(text) }
        panel.show()
        if streamedChars == 0 { speechText += text; listener.speaking(more: text); speaker.feed(text) }   // nothing of the final answer streamed
        replyExpected = defaults.bool(forKey: "followUp")
        speaker.end()
    }

    func respond(_ text: String) {
        panel.show()
        let followUp = defaults.bool(forKey: "followUp")
        if defaults.bool(forKey: "speak") {
            speak(text, expectReply: followUp)
        } else if followUp {
            listener.beginCapture(followUp: true)
        } else {
            hideSoon(12)
        }
    }

    func show(failure text: String) {
        state.phase = .failed; state.answer = text
        panel.show()
        if defaults.bool(forKey: "speak") { speak("Sorry, that didn't work. The details are on screen.") } else { replyExpected = false }
        hideSoon(20)
    }

    func stopAll() {
        replyExpected = false; speakingTurn = false
        brain.stop(); speaker.stop()
        let running = board.running.count
        state.phase = .answered; state.answer = running == 0 ? "Stopped." : "Stopped. \(running == 1 ? "A task is" : "\(running) tasks are") still running in the background."
        log.write("■ Stopped")
        updateIcon(); hideSoon(1.5)
    }

    func hideSoon(_ seconds: TimeInterval) {
        panel.hide(after: seconds) { [weak self] in
            guard let self else { return false }
            return self.listener.capturing || self.brain.busy || self.speaker.speaking
        }
    }

    func updateIcon() {
        let name = brain.busy ? "ellipsis.bubble.fill" : listener.capturing ? "waveform.circle.fill" : listener.wakeEnabled ? "waveform.circle" : "mic.slash.circle"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Otto")
    }

    // Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems(); actions.removeAll()
        let status = claude.busy ? "Working…" : listener.wakeEnabled ? "Say “\(wakePhrase)” or press ⌃⌥Space" : "Press ⌃⌥Space to talk"
        let header = menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        add(menu, "Type a Request…") { [unowned self] in typeRequest() }
        add(menu, "Attach Front Window (both ⌘ keys)") { [unowned self] in attachWindow() }
        add(menu, "Stop", enabled: claude.busy || speaker.speaking) { [unowned self] in stopAll() }
        add(menu, "New Conversation") { [unowned self] in claude.reset(); voice.reset() }
        let taskMenu = NSMenu()
        if board.tasks.isEmpty {
            let none = taskMenu.addItem(withTitle: "No tasks yet", action: nil, keyEquivalent: ""); none.isEnabled = false
        }
        for task in board.tasks.suffix(10).reversed() {
            let item = taskMenu.addItem(withTitle: "#\(task.id) \(task.title) — \(task.status.rawValue), \(task.elapsed)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            if task.status == .running { add(taskMenu, "    Cancel #\(task.id)") { [unowned self] in board.cancel(task.id) } }
        }
        if !board.running.isEmpty {
            taskMenu.addItem(.separator())
            add(taskMenu, "Cancel All Tasks") { [unowned self] in board.running.forEach { board.cancel($0.id) } }
        }
        let tasksItem = menu.addItem(withTitle: board.running.isEmpty ? "Tasks" : "Tasks (\(board.running.count) running)", action: nil, keyEquivalent: "")
        tasksItem.submenu = taskMenu
        menu.addItem(.separator())
        add(menu, "Listen for “\(wakePhrase)”", on: listener.wakeEnabled) { [unowned self] in
            listener.wakeEnabled.toggle(); defaults.set(listener.wakeEnabled, forKey: "wake"); updateIcon()
        }
        add(menu, "Change Wake Word…") { [unowned self] in changeWakePhrase() }
        add(menu, "Speak Answers", on: defaults.bool(forKey: "speak")) { [unowned self] in
            defaults.set(!defaults.bool(forKey: "speak"), forKey: "speak")
        }
        let pauses = NSMenu()
        for (title, seconds) in [("Short", 1.3), ("Normal", 1.8), ("Long", 2.6), ("Very Long", 3.6)] {
            add(pauses, title, on: abs(listener.pauseToEnd - seconds) < 0.05) { [unowned self] in
                defaults.set(seconds, forKey: "pause"); listener.pauseToEnd = seconds
            }
        }
        menu.addItem(withTitle: "Pause Before Sending", action: nil, keyEquivalent: "").submenu = pauses
        let safety = NSMenu()
        add(safety, "Ask Before Risky Actions", on: !fullAccess) { [unowned self] in setAccess(full: false) }
        add(safety, "Full Access (never asks; a web page or email could make it run anything)", on: fullAccess) { [unowned self] in setAccess(full: true) }
        menu.addItem(withTitle: fullAccess ? "Safety: Full Access" : "Safety: Asks First", action: nil, keyEquivalent: "").submenu = safety
        add(menu, "Fast Voice + Background Tasks", on: twoLayer) { [unowned self] in
            defaults.set(!twoLayer, forKey: "twoLayer")
            log.write("Fast voice with background tasks: " + (twoLayer ? "on" : "off"))
        }
        add(menu, "Echo Cancellation", on: listener.echoCancellation) { [unowned self] in
            listener.echoCancellation.toggle(); defaults.set(listener.echoCancellation, forKey: "echo")
            listener.restartAudio()
        }
        add(menu, "Listen for a Reply After Answers", on: defaults.bool(forKey: "followUp")) { [unowned self] in
            defaults.set(!defaults.bool(forKey: "followUp"), forKey: "followUp")
        }
        let voices = NSMenu()
        add(voices, "System Voice (Siri and other voices: System Settings)", on: speaker.voice.isEmpty) { [unowned self] in setVoice("") }
        voices.addItem(.separator())
        for name in Speaker.voices() {
            add(voices, name, on: speaker.voice == name) { [unowned self] in setVoice(name) }
        }
        voices.addItem(.separator())
        add(voices, "Set the System Voice…") {
            // System Settings → Accessibility → Spoken Content: System Voice, and Manage Voices to download more
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
        }
        menu.addItem(withTitle: "Voice", action: nil, keyEquivalent: "").submenu = voices
        let models = NSMenu()
        for (title, id) in [("Claude Code's Default", ""), ("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku (fastest)", "haiku")] {
            add(models, title, on: claude.model == id) { [unowned self] in
                defaults.set(id, forKey: "model"); claude.model = id; claude.reset()
            }
        }
        menu.addItem(withTitle: "Model", action: nil, keyEquivalent: "").submenu = models
        let accounts = NSMenu()
        let chosen = defaults.string(forKey: "claudeConfig") ?? ""
        for dir in ClaudeSession.configDirs() {
            add(accounts, dir == "~/.claude" ? "~/.claude (Claude Code's default)" : dir, on: dir == chosen || (dir == "~/.claude" && chosen.isEmpty)) { [unowned self] in
                defaults.set(dir, forKey: "claudeConfig")
                claude.configDir = ClaudeSession.resolveConfigDir(dir); claude.reset()
                voice.configDir = claude.configDir; voice.reset()
                log.write("Claude account: " + dir)
            }
        }
        menu.addItem(withTitle: "Claude Account", action: nil, keyEquivalent: "").submenu = accounts
        add(menu, "Open at Login", on: SMAppService.mainApp.status == .enabled) {
            let service = SMAppService.mainApp
            do { try service.status == .enabled ? service.unregister() : service.register() } catch { NSLog("Otto: login item: \(error)") }
        }
        add(menu, "Permissions…") { [unowned self] in askForControlPermissions(openSettings: true) }
        add(menu, "Show Log") { [unowned self] in NSWorkspace.shared.open(log.url) }
        menu.addItem(.separator())
        add(menu, "Quit Otto") { NSApp.terminate(nil) }
    }

    func add(_ menu: NSMenu, _ title: String, on: Bool? = nil, enabled: Bool = true, _ run: @escaping () -> Void) {
        let action = MenuAction(run)
        actions.append(action)
        let item = menu.addItem(withTitle: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = action; item.isEnabled = enabled
        if let on { item.state = on ? .on : .off }
    }

    func setAccess(full: Bool) {
        defaults.set(full ? "full" : "ask", forKey: "access")
        claude.fullAccess = full; claude.reset()   // new tasks start with the new setting; running ones keep theirs
        log.write("Safety: " + (full ? "full access" : "ask before risky actions"))
    }

    func setVoice(_ id: String) {
        defaults.set(id, forKey: "voice"); speaker.voice = id
        speak("This is how I'll sound.")
    }

    func changeWakePhrase() {
        let alert = NSAlert()
        alert.messageText = "Wake word"
        alert.informativeText = "What you say to start a request, like “Hey Otto”, “Hey Robin” or “Okay Computer”. "
            + "Two words work better than one: a single word you use in normal speech will wake it by accident."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = wakePhrase
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let phrase = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...4).contains(Listener.words(phrase).count) else {
            let problem = NSAlert()
            problem.messageText = "Use one to four words"
            problem.informativeText = "For example “Hey Otto”."
            problem.runModal()
            return changeWakePhrase()
        }
        defaults.set(phrase, forKey: "wakePhrase")
        listener.wakePhrase = phrase
        log.write("Wake word: " + phrase)
    }

    func typeRequest() {
        let context = contextLine()   // before this app comes forward
        let alert = NSAlert()
        alert.messageText = "Ask Claude"
        alert.addButton(withTitle: "Ask"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "What should I do?"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let text = alert.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if !text.isEmpty { handle(text, context: context) }
    }

    func askForControlPermissions(openSettings: Bool = false) {
        let accessibility = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        let screen = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        if openSettings && (!accessibility || !screen) {
            let pane = accessibility ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        }
    }
}

// MARK: - Entry point

signal(SIGPIPE, SIG_IGN)   // writing to a Claude Code that just exited must fail, not kill the app
let arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, helperCommands.contains(first) {
    guard first == "ask" else { exit(Ctl.run(arguments)) }
    // Testing from the terminal. Two layers by default, like the app: prints what the voice would say, the tasks it
    // starts, their steps, and what it says when they finish. --single: one agent, as with the setting off.
    let settings = UserDefaults(suiteName: "io.github.jimjja.otto")
    let configDir = ClaudeSession.resolveConfigDir(settings?.string(forKey: "claudeConfig") ?? "")
    let model = settings?.string(forKey: "model") ?? ""
    let single = arguments.contains("--single"), safe = arguments.contains("--safe")   // --safe: ask first, and answer no
    let request = arguments.dropFirst().filter { $0 != "--single" && $0 != "--safe" }.joined(separator: " ")
    let began = Date()
    func stamp() -> String { String(format: "%5.1fs", Date().timeIntervalSince(began)) }
    if single {
        let session = ClaudeSession()
        session.model = model; session.configDir = configDir
        session.onStep = { print(stamp(), "› " + $0) }
        session.onDone = { text, failed in print(stamp(), (failed ? "✗ " : "✓ ") + text); exit(failed ? 1 : 0) }
        session.send(contextLine() + "\n" + request)
        RunLoop.main.run()
    }
    let voice = ClaudeSession(), board = TaskBoard()
    voice.role = .voice; voice.configDir = configDir
    board.configure = { $0.configDir = configDir; $0.model = model; $0.fullAccess = !safe }
    board.onPermission = { request in
        print(stamp(), "✋ #\(request.taskID ?? 0) asks to \(request.spoken)  [\(ClaudeSession.describe(request.tool, request.input))] → no")
        request.session?.answer(request, allow: false)
    }
    var filter = DirectiveFilter(), seen = 0, said = "", firstWord = true, pending: [String] = []
    func run(_ directives: [Directive]) {
        for d in directives {
            switch d {
            case .start(let title, let instruction):
                let t = board.start(title: title, instruction: contextLine() + "\n" + instruction)
                print(stamp(), "◆ started #\(t.id) “\(title)”: \(instruction)")
            case .steer(let id, let text): board.steer(id, text); print(stamp(), "◆ steered #\(id): \(text)")
            case .cancel(let id): board.cancel(id); print(stamp(), "◆ cancelled #\(id)")
            }
        }
    }
    voice.onText = { text in
        let (speech, directives) = filter.feed(String(text.dropFirst(seen)))
        seen = text.count
        if firstWord && !speech.trimmingCharacters(in: .whitespaces).isEmpty { firstWord = false; print(stamp(), "(first word)") }
        said += speech; run(directives)
    }
    func next() {   // tell finished tasks, then stop once nothing is left
        if let message = pending.first, !voice.busy {
            pending.removeFirst(); seen = 0; said = ""; filter = DirectiveFilter(); firstWord = true
            voice.send([contextLine(), board.summary(), message].joined(separator: "\n"))
        } else if pending.isEmpty && board.running.isEmpty && !voice.busy { exit(0) }
    }
    voice.onDone = { text, failed in
        let (speech, directives) = filter.finish()
        said += speech; run(directives)
        print(stamp(), failed ? "✗ " + text : "🔊 " + said.trimmingCharacters(in: .whitespacesAndNewlines))
        next()
    }
    board.onStep = { task, step in print(stamp(), "  #\(task.id) › " + step) }
    board.onFinished = { task in
        print(stamp(), "◆ #\(task.id) \(task.status.rawValue) after \(task.elapsed)")
        pending.append("[Task #\(task.id) “\(task.title)” \(task.status == .finished ? "finished" : "failed")]\n\(task.result.prefix(4000))\n[Tell the user the outcome briefly.]")
        next()
    }
    voice.send([contextLine(), request].joined(separator: "\n"))
    RunLoop.main.run()
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
// Quit from Activity Monitor, `pkill` (build.sh) or logout arrives as a signal, which skips applicationWillTerminate.
let quitSignals = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }   // even if the main thread is stuck
        DispatchQueue.main.async { controller.cleanUp(); exit(0) }
    }
    source.resume()
    return source
}
app.setActivationPolicy(.accessory)
app.run()
