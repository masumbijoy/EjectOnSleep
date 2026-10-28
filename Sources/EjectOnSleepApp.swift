import SwiftUI
import ServiceManagement

// Menu bar app: ejects all external physical drives when the Mac goes to sleep.
// Requires macOS 13 or later. App Sandbox must be OFF (it needs to run diskutil).

@main
struct EjectOnSleepApp: App {
    @StateObject private var model = EjectModel()

    private static let menuBarIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let symbol = NSImage(systemSymbolName: "eject.circle", accessibilityDescription: "Eject on Sleep")!
            .withSymbolConfiguration(config)!
        symbol.isTemplate = true
        return symbol
    }()

    var body: some Scene {
        MenuBarExtra {
            Toggle("Eject drives when Mac sleeps", isOn: $model.enabled)
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Divider()
            Button("Eject all external drives now") { model.ejectNow() }
            if !model.lastMessage.isEmpty {
                Text(model.lastMessage)
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
    }
}

final class EjectModel: ObservableObject {
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled") }
    }
    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }
    @Published var lastMessage: String = ""

    init() {
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.enabled else { return }
            self.ejectNow()
        }
    }

    func ejectNow() {
        let disks = Self.externalDisks()
        if disks.isEmpty {
            lastMessage = "No external drives found"
            return
        }
        var ok = 0
        for disk in disks {
            if Self.run(["eject", disk]) { ok += 1 }
        }
        lastMessage = "Ejected \(ok) of \(disks.count) drive(s)"
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
