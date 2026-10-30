// screenflare-ctl — a stable, permission-light automation surface for Screenflare.
//
// Why this exists: Screenflare (app.screenflare) ships no URL scheme, AppleScript
// dictionary, CLI or App Intents. Its menu bar is the only hook, and driving it
// through `osascript` + System Events costs Apple Events/Automation permission,
// spawns three or four processes per action, and breaks when a localized title
// changes shape.
//
// This tool talks to the Accessibility API directly:
//   * one AXUIElementCreateApplication(pid) per run, menu walked in-process;
//   * menu titles resolved from Screenflare's own Localizable.strings, so any UI
//     language works;
//   * menu item key equivalents and enabled bits are reported, so callers can see
//     the real state (is it recording? can it record?) instead of guessing;
//   * results are read back from the library folders, so a capture returns the
//     file it produced rather than "the clipboard changed".
//
// It performs no Apple Events and needs no Automation grant. It only needs the
// Accessibility trust of the process that launches it (Raycast, your terminal,
// or the OpenLogi agent), which those hosts already hold.
//
// Commands
//   screenflare-ctl doctor            [--json]   environment + per-action resolution report
//   screenflare-ctl list              [--json]   every capability: titles, enabled, shortcut
//   screenflare-ctl state             [--json]   running / recording / paused
//   screenflare-ctl action <id>       [--json] [--no-wait] [--timeout N] [--force]
//
// Exit codes: 0 ok, 2 usage, 3 app not running, 4 accessibility denied,
//             5 unresolved menu item, 6 item disabled, 7 timeout, 8 press failed.

import AppKit
import ApplicationServices
import Darwin
import Foundation

let schemaVersion = 1
/// Screenflare's bundle id. A locally rebuilt copy (`screenflarex`) carries
/// `app.screenflare.x`, so both are accepted: whichever is running is the one to drive.
let bundleIDs = ["app.screenflare.x", "app.screenflare"]
let bundleID = bundleIDs[0]
let appPath = "/Applications/Screenflare.app"
let infoPlistPath = appPath + "/Contents/Info.plist"
let resourcesPath = appPath + "/Contents/Resources"

enum Exit: Int32 {
    case ok = 0, usage = 2, notRunning = 3, accessDenied = 4
    case unresolved = 5, unavailable = 6, timeout = 7, pressFailed = 8
}

// MARK: - Capabilities

/// `menuKey` is Screenflare's own localization key for the menu title. These ids and
/// keys are this CLI's public contract: everything else (AX walking, language,
/// folders) is implementation detail.
struct Capability {
    enum Area { case file, app }
    enum Produces { case ui, screenshot, text, recordingStarted, recordingStopped }
    let id: String
    let area: Area
    let menuKey: String
    let produces: Produces
}

let capabilities: [Capability] = [
    .init(id: "capture-area", area: .file, menuKey: "menu.file.captureScreenshot", produces: .screenshot),
    .init(id: "capture-window", area: .file, menuKey: "menu.file.captureWindow", produces: .screenshot),
    .init(id: "capture-fullscreen", area: .file, menuKey: "menu.file.captureFullscreen", produces: .screenshot),
    .init(id: "capture-scrolling", area: .file, menuKey: "menu.file.captureScrolling", produces: .screenshot),
    .init(id: "capture-text", area: .file, menuKey: "menu.file.captureText", produces: .text),
    .init(id: "record-display", area: .file, menuKey: "menu.file.recordDisplay", produces: .recordingStarted),
    .init(id: "record-window", area: .file, menuKey: "menu.file.recordWindow", produces: .recordingStarted),
    .init(id: "record-area", area: .file, menuKey: "menu.file.recordArea", produces: .recordingStarted),
    .init(id: "record-or-capture", area: .file, menuKey: "menu.file.captureBar", produces: .ui),
    .init(id: "stop-recording", area: .file, menuKey: "menu.file.stopRecording", produces: .recordingStopped),
    .init(id: "pause-recording", area: .file, menuKey: "menu.file.pauseRecording", produces: .ui),
    .init(id: "new-recording", area: .file, menuKey: "menu.file.newRecording", produces: .recordingStarted),
    .init(id: "open-last-recording", area: .file, menuKey: "menu.file.openLastProject", produces: .ui),
    .init(id: "screenshot-history", area: .file, menuKey: "menu.file.screenshotHistory", produces: .ui),
    .init(id: "recording-history", area: .file, menuKey: "menu.file.previousProjects", produces: .ui),
    .init(id: "open-image", area: .file, menuKey: "menu.file.openImage", produces: .ui),
    .init(id: "open-image-editor", area: .file, menuKey: "menu.file.openImageEditor", produces: .ui),
    .init(id: "settings", area: .app, menuKey: "menu.app.settings", produces: .ui),
]

// MARK: - Arguments

struct Args {
    var flags = Set<String>()
    var values: [String: String] = [:]
    var positional: [String] = []

    init(_ raw: [String]) {
        var index = 0
        let knownValueFlags: Set<String> = ["timeout", "screenshots", "recordings", "as"]
        while index < raw.count {
            let argument = raw[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if knownValueFlags.contains(name), index + 1 < raw.count {
                    values[name] = raw[index + 1]
                    index += 2
                    continue
                }
                flags.insert(name)
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }
}

let args = Args(Array(CommandLine.arguments.dropFirst()))

// MARK: - Output

func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(data: data, encoding: .utf8)!
}

let wantsJSON = args.flags.contains("json")

func emit(_ payload: [String: Any], exit code: Exit, human: String?) -> Never {
    if wantsJSON {
        print(jsonLine(payload))
    } else if let human {
        if code == .ok { print(human) } else { FileHandle.standardError.write((human + "\n").data(using: .utf8)!) }
    } else {
        print(jsonLine(payload))
    }
    exit(code.rawValue)
}

func succeed(_ extra: [String: Any] = [:], human: String? = nil) -> Never {
    var payload: [String: Any] = ["schema": schemaVersion, "ok": true]
    payload.merge(extra) { _, new in new }
    emit(payload, exit: .ok, human: human)
}

func fail(_ code: String, _ message: String, hint: String? = nil, exit status: Exit,
          extra: [String: Any] = [:]) -> Never {
    var error: [String: Any] = ["code": code, "message": message]
    if let hint { error["hint"] = hint }
    var payload: [String: Any] = ["schema": schemaVersion, "ok": false, "error": error]
    payload.merge(extra) { _, new in new }
    emit(payload, exit: status, human: message + (hint.map { "\n  hint: \($0)" } ?? ""))
}

// MARK: - Accessibility

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func title(of element: AXUIElement) -> String {
    (attribute(element, kAXTitleAttribute as String) as? String) ?? ""
}

func children(of element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func isEnabled(_ element: AXUIElement) -> Bool {
    (attribute(element, kAXEnabledAttribute as String) as? Bool) ?? false
}

/// Menu item key equivalent rendered like macOS does: ⌃⌥⇧⌘ with the command glyph last.
/// AXMenuItemCmdModifiers: 1 = ⇧, 2 = ⌥, 4 = ⌃, 8 = "no command".
func shortcut(_ element: AXUIElement) -> String? {
    guard let char = attribute(element, "AXMenuItemCmdChar") as? String, !char.isEmpty else { return nil }
    let modifiers = (attribute(element, "AXMenuItemCmdModifiers") as? Int) ?? 0
    var text = ""
    if modifiers & 4 != 0 { text += "⌃" }
    if modifiers & 2 != 0 { text += "⌥" }
    if modifiers & 1 != 0 { text += "⇧" }
    if modifiers & 8 == 0 { text += "⌘" }
    let display: String
    switch char {
    case " ": display = "Space"
    case String(UnicodeScalar(27)!): display = "⎋"
    case String(UnicodeScalar(13)!): display = "↩"
    case String(UnicodeScalar(9)!): display = "⇥"
    case String(UnicodeScalar(127)!): display = "⌫"
    default: display = char
    }
    return text + display
}

struct MenuItem {
    let element: AXUIElement
    let menuTitle: String
    let title: String
    let enabled: Bool
    let shortcut: String?
    let marked: Bool
}

struct Menu {
    let title: String
    let items: [MenuItem]
}

func readMenus(of bar: AXUIElement) -> [Menu] {
    children(of: bar).map { barItem in
        let barTitle = title(of: barItem)
        var items: [MenuItem] = []
        if let menu = children(of: barItem).first {
            items = children(of: menu).compactMap { item in
                let itemTitle = title(of: item)
                guard !itemTitle.isEmpty else { return nil }
                return MenuItem(element: item, menuTitle: barTitle, title: itemTitle,
                                enabled: isEnabled(item), shortcut: shortcut(item),
                                marked: !((attribute(item, "AXMenuItemMarkChar") as? String) ?? "").isEmpty)
            }
        }
        return Menu(title: barTitle, items: items)
    }
}

// MARK: - Target

struct Target {
    let bundleIdentifier: String
    let pid: pid_t
    /// Where the running bundle actually lives: the original app, or a rebuilt copy the
    /// user keeps elsewhere. Everything file-based (Localizable.strings, Info.plist) has
    /// to come from here, not from the installed path.
    let bundleURL: URL
    let ax: AXUIElement

    var resourcesPath: String { bundleURL.appendingPathComponent("Contents/Resources").path }
    var infoPlistPath: String { bundleURL.appendingPathComponent("Contents/Info.plist").path }
}

func appVersion(_ infoPlistPath: String = infoPlistPath) -> String {
    (NSDictionary(contentsOfFile: infoPlistPath)?["CFBundleShortVersionString"] as? String) ?? "unknown"
}

func runningTarget() -> Target? {
    let apps = NSWorkspace.shared.runningApplications
    for identifier in bundleIDs {
        if let app = apps.first(where: { $0.bundleIdentifier == identifier }) {
            return Target(bundleIdentifier: identifier, pid: app.processIdentifier,
                          bundleURL: app.bundleURL ?? URL(fileURLWithPath: appPath),
                          ax: AXUIElementCreateApplication(app.processIdentifier))
        }
    }
    return nil
}

func menuBar(of target: Target) -> AXUIElement? {
    guard let value = attribute(target.ax, kAXMenuBarAttribute as String) else { return nil }
    return (value as! AXUIElement)
}

// MARK: - Localization

func preferencesArray(_ key: String, domain: CFString) -> [String] {
    (CFPreferencesCopyAppValue(key as CFString, domain) as? [String]) ?? []
}

func bundleLocalizations(_ infoPlistPath: String = infoPlistPath) -> [String] {
    (NSDictionary(contentsOfFile: infoPlistPath)?["CFBundleLocalizations"] as? [String]) ?? ["en"]
}

/// The language Screenflare actually renders: per-app override, then global, then system.
func effectiveLanguage(for identifier: String = bundleID, infoPlistPath: String = infoPlistPath,
                       resourcesPath: String = resourcesPath) -> String {
    let available = bundleLocalizations(infoPlistPath)
    var candidates: [String] = []
    candidates += preferencesArray("AppleLanguages", domain: identifier as CFString)
    candidates += preferencesArray("AppleLanguages", domain: kCFPreferencesAnyApplication)
    candidates += Locale.preferredLanguages
    for candidate in candidates {
        if available.contains(candidate) { return candidate }
        if let base = candidate.split(separator: "-").first, available.contains(String(base)) { return String(base) }
    }
    return available.first ?? "en"
}

func loadStrings(_ language: String, resourcesPath: String = resourcesPath) -> [String: String] {
    let path = "\(resourcesPath)/\(language).lproj/Localizable.strings"
    guard FileManager.default.fileExists(atPath: path) else { return [:] }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    process.arguments = ["-convert", "json", "-o", "-", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: String]) ?? [:]
}

struct Strings {
    let language: String
    let table: [String: String]
    func callAsFunction(_ key: String) -> String? { table[key] }
}

func currentStrings(for identifier: String = bundleID, infoPlistPath: String = infoPlistPath,
                    resourcesPath: String = resourcesPath) -> Strings {
    let language = effectiveLanguage(for: identifier, infoPlistPath: infoPlistPath, resourcesPath: resourcesPath)
    var table = loadStrings(language, resourcesPath: resourcesPath)
    if table.isEmpty { table = loadStrings("en", resourcesPath: resourcesPath) }
    return Strings(language: language, table: table)
}

// MARK: - Library folders

func expand(_ path: String) -> String {
    path.hasPrefix("~") ? NSHomeDirectory() + String(path.dropFirst()) : path
}

func screenshotsFolder() -> String {
    if let override = args.values["screenshots"] ?? ProcessInfo.processInfo.environment["SCREENFLARE_SCREENSHOTS"], !override.isEmpty {
        return expand(override)
    }
    return NSHomeDirectory() + "/Screenflare/screenshots"
}

func recordingsFolder() -> String {
    if let override = args.values["recordings"] ?? ProcessInfo.processInfo.environment["SCREENFLARE_RECORDINGS"], !override.isEmpty {
        return expand(override)
    }
    return NSHomeDirectory() + "/Screenflare/recordings"
}

func subdirectories(_ folder: String) -> Set<String> {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    var result = Set<String>()
    for entry in entries {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder + "/" + entry, isDirectory: &isDir), isDir.boolValue {
            result.insert(entry)
        }
    }
    return result
}

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

@discardableResult
func waitUntil(timeout: Double, poll: Double = 0.05, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: poll)
    }
    return predicate()
}

func newScreenshot(since known: Set<String>) -> [String: Any]? {
    let folder = screenshotsFolder()
    guard let name = subdirectories(folder).subtracting(known).sorted().first else { return nil }
    let dir = folder + "/" + name
    let meta = readJSON(dir + "/meta.json") ?? [:]
    var payload: [String: Any] = ["dir": dir, "name": name, "meta": meta, "thumb": dir + "/thumbnail.png"]
    if let export = meta["exportPath"] as? String, FileManager.default.fileExists(atPath: export) {
        payload["image"] = export
    } else {
        payload["image"] = dir + "/thumbnail.png"
    }
    return payload
}

func newRecording(since known: Set<String>) -> [String: Any]? {
    let folder = recordingsFolder()
    guard let name = subdirectories(folder).subtracting(known).sorted().first else { return nil }
    let dir = folder + "/" + name
    return ["dir": dir, "name": name, "meta": readJSON(dir + "/meta.json") ?? [:]]
}

// MARK: - Resolver

struct Resolution {
    let capability: Capability
    let item: MenuItem
    let titles: [String]
}

struct Resolver {
    let target: Target
    let strings: Strings
    let menus: [Menu]

    func menuTitle(_ area: Capability.Area) -> String? {
        strings(area == .file ? "menu.file" : "menu.app")
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    /// Trailing key segment as words: "menu.file.recordWindow" → "record window".
    static func keyWords(_ key: String) -> String {
        let tail = key.split(separator: ".").last.map(String.init) ?? key
        var words: [String] = []
        var current = ""
        for character in tail {
            if character.isUppercase, !current.isEmpty { words.append(current); current = "" }
            current.append(Character(character.lowercased()))
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    func resolve(_ capability: Capability) -> Resolution? {
        guard let expected = strings(capability.menuKey) else { return nil }
        // Preferred menu first (File for most, the app menu for Settings), then every
        // menu: the app menu's bar title is the product name with no localization key.
        var search: [Menu] = []
        if let barTitle = menuTitle(capability.area), let preferred = menus.first(where: { $0.title == barTitle }) {
            search.append(preferred)
        }
        search += menus.filter { menu in !search.contains { $0.title == menu.title } }

        let wanted = Resolver.normalized(expected)
        let words = Resolver.keyWords(capability.menuKey)
        let matchers: [(String) -> Bool] = [
            { $0 == expected },
            { Resolver.normalized($0) == wanted },
            { Resolver.normalized($0).hasSuffix(words) },
        ]
        for predicate in matchers {
            for menu in search {
                if let item = menu.items.first(where: { predicate($0.title) }) {
                    return Resolution(capability: capability, item: item, titles: [menu.title, item.title])
                }
            }
        }
        return nil
    }

    func stopEnabled() -> Bool {
        guard let capability = capabilities.first(where: { $0.id == "stop-recording" }) else { return false }
        return resolve(capability)?.item.enabled ?? false
    }

    func paused() -> Bool {
        guard let pauseTitle = strings("menu.file.pauseRecording"),
              let resumeTitle = strings("menu.file.resumeRecording"),
              let barTitle = menuTitle(.file),
              let menu = menus.first(where: { $0.title == barTitle })
        else { return false }
        if menu.items.contains(where: { $0.title == resumeTitle }) { return true }
        if menu.items.contains(where: { $0.title == pauseTitle }) { return false }
        return false
    }

    func inventory(_ capability: Capability) -> [String: Any] {
        guard let resolution = resolve(capability) else {
            return ["id": capability.id, "menuKey": capability.menuKey, "error": "unresolved"]
        }
        var row: [String: Any] = ["id": capability.id, "menuKey": capability.menuKey,
                                  "titles": resolution.titles, "enabled": resolution.item.enabled]
        if let shortcut = resolution.item.shortcut { row["shortcut"] = shortcut }
        if resolution.item.marked { row["marked"] = true }
        return row
    }
}

// MARK: - Shared plumbing

func statePayload(_ target: Target?, _ resolver: Resolver?) -> [String: Any] {
    var state: [String: Any] = [
        "running": target != nil,
        "version": appVersion(),
        "axTrusted": AXIsProcessTrusted(),
        "screenshotsFolder": screenshotsFolder(),
        "recordingsFolder": recordingsFolder(),
    ]
    if let target { state["pid"] = Int(target.pid) }
    state["recording"] = resolver?.stopEnabled() ?? false
    state["paused"] = resolver?.paused() ?? false
    state["language"] = resolver?.strings.language ?? bundleID
    return state
}

func connect() -> (Target, Resolver) {
    guard let target = runningTarget() else {
        fail("app_not_running", "No Screenflare or ScreenflareX is running.",
             hint: "Launch one: open -g -a \(appPath)  — or a rebuilt copy at ~/Applications/ScreenflareX.app",
             exit: .notRunning,
             extra: ["state": statePayload(nil, nil)])
    }
    guard let bar = menuBar(of: target) else {
        fail("no_menu_bar", "Screenflare exposes no accessibility menu bar.",
             hint: "Allow the calling app (Raycast / Terminal / OpenLogi) in System Settings ▸ Privacy & Security ▸ Accessibility.",
             exit: .accessDenied, extra: ["state": statePayload(target, nil)])
    }
    let resolver = Resolver(
        target: target,
        strings: currentStrings(for: target.bundleIdentifier, infoPlistPath: target.infoPlistPath,
                               resourcesPath: target.resourcesPath),
        menus: readMenus(of: bar))
    return (target, resolver)
}

func freshResolver(_ target: Target, strings: Strings) -> Resolver? {
    guard let bar = menuBar(of: target) else { return nil }
    return Resolver(target: target, strings: strings, menus: readMenus(of: bar))
}

// MARK: - Commands

func runDoctor() {
    var report: [String: Any] = [
        "axTrusted": AXIsProcessTrusted(),
        "appPath": appPath,
        "appVersion": appVersion(runningTarget()?.infoPlistPath ?? infoPlistPath),
        "language": currentStrings().language,
        "bundleLocalizations": bundleLocalizations(),
        "screenshotsFolder": screenshotsFolder(),
        "recordingsFolder": recordingsFolder(),
    ]
    let (target, resolver) = connect()
    let rows = capabilities.map { resolver.inventory($0) }
    let unresolved = rows.filter { ($0["error"] as? String) == "unresolved" }.compactMap { $0["id"] as? String }
    report["running"] = true
    report["menuBar"] = true
    report["actions"] = rows
    report["unresolved"] = unresolved
    report["state"] = statePayload(target, resolver)

    let human = """
    Screenflare \(appVersion(target.infoPlistPath))  pid \(target.pid)  language \(resolver.strings.language)  AX \(AXIsProcessTrusted() ? "trusted" : "not trusted")
    screenshots  \(screenshotsFolder())
    recordings   \(recordingsFolder())
    actions      \(capabilities.count - unresolved.count)/\(capabilities.count) resolved\(unresolved.isEmpty ? "" : " (unresolved: \(unresolved.joined(separator: ", ")))")
    recording    \(resolver.stopEnabled() ? "yes" : "no")  paused \(resolver.paused() ? "yes" : "no")
    """
    if unresolved.isEmpty {
        succeed(["doctor": report], human: human)
    } else {
        emit(["schema": schemaVersion, "ok": false,
              "error": ["code": "unresolved_actions",
                        "message": "Cannot resolve \(unresolved.count) menu item(s): " + unresolved.joined(separator: ", ")],
              "doctor": report], exit: .unresolved, human: human + "\nunresolved: " + unresolved.joined(separator: ", "))
    }
}

func runList() {
    let (target, resolver) = connect()
    let rows = capabilities.map { resolver.inventory($0) }
    let human = rows.map { row -> String in
        let id = (row["id"] as? String ?? "?").padding(toLength: 20, withPad: " ", startingAt: 0)
        if row["error"] != nil { return "\(id) unresolved (\(row["menuKey"] as? String ?? ""))" }
        let enabled = (row["enabled"] as? Bool) == true ? "on " : "off"
        let keys = ((row["shortcut"] as? String) ?? "").padding(toLength: 7, withPad: " ", startingAt: 0)
        let titles = (row["titles"] as? [String] ?? []).joined(separator: " ▸ ")
        return "\(id) \(enabled) \(keys) \(titles)"
    }.joined(separator: "\n")
    succeed(["actions": rows, "state": statePayload(target, resolver)], human: human)
}

func runState() {
    let (target, resolver) = connect()
    let state = statePayload(target, resolver)
    succeed(["state": state],
            human: "running pid \(target.pid)  recording \((state["recording"] as? Bool) == true ? "yes" : "no")  paused \((state["paused"] as? Bool) == true ? "yes" : "no")")
}

func runAction(_ id: String) {
    guard let capability = capabilities.first(where: { $0.id == id }) else {
        fail("unknown_action", "Unknown action \"\(id)\".", exit: .usage,
             extra: ["actions": capabilities.map { $0.id }])
    }
    let interactive = capability.produces == .screenshot || capability.produces == .text
    let timeout = Double(args.values["timeout"] ?? "") ?? (interactive ? 120 : 20)
    let noWait = args.flags.contains("no-wait") || capability.produces == .ui

    let (target, resolver) = connect()
    guard let resolution = resolver.resolve(capability) else {
        fail("unresolved_action", "Cannot find the menu item for \(id) in Screenflare \(appVersion()).",
             hint: "Run: screenflare-ctl list  — and check the app's UI language.",
             exit: .unresolved,
             extra: ["action": id, "menuKey": capability.menuKey, "state": statePayload(target, resolver)])
    }
    if !resolution.item.enabled && !args.flags.contains("force") {
        fail("menu_item_disabled", "\(resolution.titles.joined(separator: " ▸ ")) is disabled right now.",
             hint: ["stop-recording", "pause-recording"].contains(id) ? "Nothing is recording." : nil,
             exit: .unavailable,
             extra: ["action": id, "titles": resolution.titles, "state": statePayload(target, resolver)])
    }

    let knownScreenshots = subdirectories(screenshotsFolder())
    let knownRecordings = subdirectories(recordingsFolder())
    let pasteboardBefore = NSPasteboard.general.changeCount

    let error = AXUIElementPerformAction(resolution.item.element, kAXPressAction as CFString)
    guard error == .success else {
        fail("press_failed", "Accessibility refused the press (AXError \(error.rawValue)).",
             hint: "Check Accessibility permission for the app that launched this tool.",
             exit: .pressFailed,
             extra: ["action": id, "titles": resolution.titles, "axError": Int(error.rawValue)])
    }

    var payload: [String: Any] = ["action": id, "titles": resolution.titles]
    if let shortcut = resolution.item.shortcut { payload["shortcut"] = shortcut }

    switch capability.produces {
    case .ui:
        payload["kind"] = "ui"
        succeed(payload, human: "pressed \(resolution.titles.joined(separator: " ▸ "))")

    case .text:
        if noWait { payload["kind"] = "text"; payload["pending"] = true; succeed(payload) }
        var copied = ""
        waitUntil(timeout: timeout, poll: 0.15) {
            guard NSPasteboard.general.changeCount != pasteboardBefore else { return false }
            copied = NSPasteboard.general.string(forType: .string) ?? ""
            return !copied.isEmpty
        }
        guard !copied.isEmpty else {
            fail("no_text", "No text reached the clipboard within \(Int(timeout))s.",
                 hint: "The overlay may still be open, or the selection was empty.", exit: .timeout,
                 extra: ["action": id])
        }
        payload["kind"] = "text"
        payload["text"] = copied
        succeed(payload, human: copied)

    case .screenshot:
        if noWait { payload["kind"] = "screenshot"; payload["pending"] = true; succeed(payload) }
        var produced: [String: Any]?
        waitUntil(timeout: timeout, poll: 0.1) {
            produced = newScreenshot(since: knownScreenshots)
            return produced != nil
        }
        guard let screenshot = produced else {
            fail("timeout", "No new screenshot appeared within \(Int(timeout))s.",
                 hint: "Region/window captures wait for user input; use --no-wait to return immediately.",
                 exit: .timeout, extra: ["action": id])
        }
        payload["kind"] = "screenshot"
        payload.merge(screenshot) { _, new in new }
        succeed(payload, human: (screenshot["image"] as? String) ?? "")

    case .recordingStarted:
        if noWait { payload["kind"] = "recording"; payload["pending"] = true; succeed(payload) }
        var recording = false
        waitUntil(timeout: min(timeout, 10), poll: 0.1) {
            recording = freshResolver(target, strings: resolver.strings)?.stopEnabled() ?? false
            return recording
        }
        payload["kind"] = "recording"
        payload["recording"] = recording
        succeed(payload, human: recording ? "recording" : "recording did not start")

    case .recordingStopped:
        if noWait { payload["kind"] = "recording"; payload["recording"] = false; payload["pending"] = true; succeed(payload) }
        var stopped = false
        waitUntil(timeout: min(timeout, 45), poll: 0.2) {
            if let fresh = freshResolver(target, strings: resolver.strings) { stopped = !fresh.stopEnabled() }
            return stopped
        }
        guard stopped else {
            fail("timeout", "Recording did not stop within \(Int(min(timeout, 45)))s.", exit: .timeout,
                 extra: ["action": id])
        }
        var artifact: [String: Any]?
        waitUntil(timeout: 5, poll: 0.2) {
            artifact = newRecording(since: knownRecordings)
            return artifact != nil
        }
        payload["kind"] = "recording"
        payload["recording"] = false
        if let artifact { payload["artifact"] = artifact }
        succeed(payload, human: (artifact?["dir"] as? String) ?? "recording stopped")
    }
}


/// Composite command for one-button use (Actions Ring slot, mouse button):
/// stop the active recording, otherwise start one. Deciding here keeps the
/// caller stateless — a shell action cannot branch on Screenflare's state.
func runToggle() {
    let mode = args.values["as"] ?? "display"
    let modeAction: String
    switch mode {
    case "display": modeAction = "record-display"
    case "window": modeAction = "record-window"
    case "area": modeAction = "record-area"
    default:
        fail("usage", "Unknown --as value \"\(mode)\" (display, window, area).", exit: .usage)
    }
    let (_, resolver) = connect()
    let recording = resolver.stopEnabled()
    let chosen = recording ? "stop-recording" : modeAction
    if args.flags.contains("dry-run") {
        succeed(["toggle": ["recording": recording, "would": chosen]], human: "would \(chosen)")
    }
    runAction(chosen)
}

// MARK: - Entry point

let command = args.flags.contains("help") ? "help" : (args.positional.first ?? "doctor")
let tail = Array(args.positional.dropFirst())

switch command {
case "doctor": runDoctor()
case "list": runList()
case "state": runState()
case "toggle": runToggle()
case "action":
    guard let id = tail.first else {
        fail("usage", "action needs an id, e.g. `screenflare-ctl action capture-window`", exit: .usage,
             extra: ["actions": capabilities.map { $0.id }])
    }
    runAction(id)
case "help":
    let text = """
    screenflare-ctl \(schemaVersion) — stable automation surface for Screenflare

    USAGE
      screenflare-ctl doctor                 environment + per-action resolution report
      screenflare-ctl list                   capabilities with titles, state and shortcuts
      screenflare-ctl state                  running / recording / paused
      screenflare-ctl action <id> [flags]     press one capability
      screenflare-ctl toggle [--as mode]      stop recording, else start one (--dry-run to peek)

    FLAGS
      --json              machine-readable output (one JSON object per run)
      --no-wait           do not wait for the artifact (screenshot/text)
      --timeout <seconds> how long to wait for an artifact (default 120 interactive, 20 otherwise)
      --force             press even when the menu item reports disabled
      --as display|window|area   what `toggle` starts when nothing is recording
      --screenshots <dir> --recordings <dir>  library folders (default ~/Screenflare/...)

    ACTIONS
    \(capabilities.map { "  " + $0.id }.joined(separator: "\n"))
    """
    succeed(["commands": ["doctor", "list", "state", "action", "toggle"], "actions": capabilities.map { $0.id }], human: text)
default:
    fail("usage", "Unknown command \"\(command)\".", exit: .usage,
         extra: ["commands": ["doctor", "list", "state", "action"]])
}
