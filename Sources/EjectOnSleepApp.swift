import SwiftUI
import ServiceManagement

// Menu bar app: ejects all external physical drives when the Mac goes to sleep.
// Requires macOS 13 or later. App Sandbox must be OFF (it needs to run diskutil).

@main
struct EjectOnSleepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = EjectModel.shared

    private static let menuBarIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let symbol = NSImage(systemSymbolName: "eject.circle", accessibilityDescription: "Eject on Sleep")!
            .withSymbolConfiguration(config)!
        symbol.isTemplate = true
        return symbol
    }()

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { !model.hideIcon }, set: { if model.hideIcon == $0 { model.hideIcon = !$0 } })) {
            Toggle("Eject drives when Mac sleeps", isOn: $model.enabled)
            Toggle("Remount drives on wake", isOn: $model.remountOnWake)
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Divider()
            Button("Eject all external drives now") { model.ejectNow() }
            Button("Unmount drives and sleep") { model.unmountAndSleep() }
            if !model.lastMessage.isEmpty {
                Text(model.lastMessage)
            }
            Divider()
            Button("Settings…") { AppDelegate.showSettings() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
    }
}

// Opens the settings window when the app is launched by hand or reopened (e.g. from
// Applications), so settings stay reachable while the menu bar icon is hidden.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
            .enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if EjectModel.shared.hideIcon && !launchedAtLogin {
            Self.showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showSettings()
        return true
    }

    static func showSettings() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Eject on Sleep"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: EjectModel.shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: EjectModel

    var body: some View {
        Form {
            Toggle("Eject drives when Mac sleeps", isOn: $model.enabled)
            Toggle("Remount drives on wake", isOn: $model.remountOnWake)
            Toggle("Unmount instead of fully ejecting (keeps drive powered)", isOn: $model.unmountOnly)
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Toggle("Hide menu bar icon", isOn: $model.hideIcon)
            Text("With the icon hidden, open Eject on Sleep from Applications to bring this window back.")
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            HStack {
                Button("Eject all external drives now") { model.ejectNow() }
                Button("Unmount and sleep") { model.unmountAndSleep() }
                if !model.lastMessage.isEmpty {
                    Text(model.lastMessage).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

final class EjectModel: ObservableObject {
    static let shared = EjectModel()

    @Published var hideIcon: Bool {
        didSet { UserDefaults.standard.set(hideIcon, forKey: "hideIcon") }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled") }
    }
    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }
    // Unmount keeps the drive powered and attached (safer with docks); full eject can power it off.
    @Published var unmountOnly: Bool {
        didSet { UserDefaults.standard.set(unmountOnly, forKey: "unmountOnly") }
    }
    @Published var remountOnWake: Bool {
        didSet { UserDefaults.standard.set(remountOnWake, forKey: "remountOnWake") }
    }
    @Published var lastMessage: String = ""

    private var disksToRemount: [String] = []
    private var sleepProblems: [String] = []

    private init() {
        hideIcon = UserDefaults.standard.bool(forKey: "hideIcon")
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
        unmountOnly = UserDefaults.standard.object(forKey: "unmountOnly") as? Bool ?? true
        remountOnWake = UserDefaults.standard.object(forKey: "remountOnWake") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.enabled else { return }
            self.disksToRemount = Self.externalDisks()
            self.sleepProblems = self.ejectNow()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.warnAboutSleepProblems()
            self?.remountAfterWake()
        }
    }

    // A sleep that was already underway can't be stopped, so report what was still in use once awake.
    private func warnAboutSleepProblems() {
        guard !sleepProblems.isEmpty else { return }
        let problems = sleepProblems
        sleepProblems = []
        DispatchQueue.main.async {
            _ = Self.confirm(
                title: "Some drives could not be unmounted before sleep",
                message: problems.joined(separator: "\n\n") + "\n\nCheck the drive for problems and close the files or apps using it before the next sleep.",
                yes: "OK", no: "Dismiss"
            )
        }
    }

    // Drives often reappear a few seconds after wake (docks/hubs), so retry a few times.
    private func remountAfterWake() {
        guard enabled, remountOnWake, !disksToRemount.isEmpty else { return }
        let disks = disksToRemount
        disksToRemount = []
        DispatchQueue.global().async {
            var pending = disks
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 5)
                pending = pending.filter { !Self.run(["mountDisk", $0]) }
                if pending.isEmpty { break }
            }
            DispatchQueue.main.async {
                self.lastMessage = pending.isEmpty
                    ? "Remounted \(disks.count) drive(s)"
                    : "Could not remount \(pending.count) of \(disks.count) drive(s)"
            }
        }
    }

    @discardableResult
    func ejectNow() -> [String] {
        let disks = Self.externalDisks()
        if disks.isEmpty {
            lastMessage = "No external drives found"
            return []
        }
        var ok = 0
        var problems: [String] = []
        for disk in disks {
            let result = Self.runOutput([unmountOnly ? "unmountDisk" : "eject", disk])
            if result.ok {
                ok += 1
            } else {
                problems.append(Self.describeFailure(disk: disk, output: result.output))
            }
        }
        lastMessage = "\(unmountOnly ? "Unmounted" : "Ejected") \(ok) of \(disks.count) drive(s)"
        return problems
    }

    // Unmounts first; if anything is still in use, warns before the Mac actually sleeps.
    func unmountAndSleep() {
        let problems = ejectNow()
        if !problems.isEmpty && !Self.confirm(
            title: "Some drives are still in use",
            message: problems.joined(separator: "\n\n") + "\n\nSleeping now may disconnect them while files are open.",
            yes: "Sleep Anyway", no: "Cancel"
        ) {
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        try? p.run()
    }

    private static func describeFailure(disk: String, output: String) -> String {
        let lines = output.split(separator: "\n").map(String.init)
        let reason = lines.first(where: { $0.contains("dissented") })
            .map { $0.replacingOccurrences(of: "Unmount was dissented by", with: "In use by") }
            ?? lines.last ?? "It is in use."
        return "\(disk): \(reason)"
    }

    static func confirm(title: String, message: String, yes: String, no: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: no)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func externalDisks() -> [String] {
        guard let output = runCapture(["list", "external", "physical"]) else { return [] }
        return output
            .split(separator: "\n")
            .filter { $0.hasPrefix("/dev/disk") }
            .compactMap { $0.split(separator: " ").first.map(String.init) }
    }

    private static func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runOutput(_ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (p.terminationStatus == 0, text)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private static func runCapture(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastMessage = "Login item error: \(error.localizedDescription)"
        }
    }
}
