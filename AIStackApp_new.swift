import SwiftUI
import AppKit
import Foundation
import Security

@main
struct AIStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.overallReady ? "cpu.fill" : "cpu")
        }
        .menuBarExtraStyle(.window)

        WindowGroup("AI Gate", id: "main") {
            MainWindow()
                .environmentObject(state)
        }
        .defaultSize(width: 1120, height: 740)
        .windowResizability(.contentMinSize)

        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit AI Gate") { state.quit() }
                    .keyboardShortcut("q")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared.prepareForQuit()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.finishQuit()
    }
}

// MARK: - Data Models

enum ServiceStatus: String, Codable {
    case ready = "Running"
    case down = "Stopped"
    case starting = "Starting"
    case warning = "Warning"
}

struct EnvItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let category: String
    let required: String
    var installed: String
    var isReady: Bool
    var iconName: String
}

struct ProxyConfig: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var port: Int
    var healthUrl: String
    var gitRepo: String?
    var startCommand: String
    var enabled: Bool = true
    var status: ServiceStatus = .down
    var latency: Int? = nil
    var version: String = "v1.0"
    var iconName: String = "arrow.triangle.branch"
}

struct ActivityLog: Identifiable, Hashable {
    let id = UUID()
    let timestamp = Date()
    let title: String
    let timeAgo: String
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedSection: Section = .overview
    @Published var routerStatus: ServiceStatus = .down
    @Published var autoHealing: Bool = true
    @Published var isBusy: Bool = false
    @Published var lastCheck = Date()
    @Published var lastAction = "All systems are running."

    @Published var envItems: [EnvItem] = []
    @Published var proxies: [ProxyConfig] = []
    @Published var bootstrapOutput: String = ""
    @Published var isBootstrapping: Bool = false
    @Published var activities: [ActivityLog] = [
        ActivityLog(title: "All services started", timeAgo: "Just now"),
        ActivityLog(title: "AgentRouter Proxy connected", timeAgo: "2m ago"),
        ActivityLog(title: "9Router Gateway ready", timeAgo: "3m ago"),
        ActivityLog(title: "Environment check completed", timeAgo: "5m ago")
    ]

    private var backend: Process?
    private var timer: Timer?
    private var quitting = false
    private let proxyStore = ProxyStore()

    var activeProxies: [ProxyConfig] { proxies.filter { $0.enabled } }
    var readyProxiesCount: Int { activeProxies.filter { $0.status == .ready }.count }
    var envReadyCount: Int { envItems.filter { $0.isReady }.count }

    var overallReady: Bool {
        routerStatus == .ready && (activeProxies.isEmpty || readyProxiesCount == activeProxies.count)
    }

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case services = "Services"
        case proxies = "Proxies"
        case environment = "Environment"
        case logs = "Logs"
        case settings = "Settings"
        case help = "Help"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: "house"
            case .services: "server.rack"
            case .proxies: "antenna.radiowaves.left.and.right"
            case .environment: "cube"
            case .logs: "doc.text"
            case .settings: "gearshape"
            case .help: "questionmark.circle"
            }
        }
    }

    func start() {
        guard !quitting else { return }
        loadProxies()
        checkEnvironment()
        launchBackendIfNeeded()
        refresh()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !quitting else { return }

        // Check 9Router
        check("http://127.0.0.1:20128/dashboard") { [weak self] ok in
            Task { @MainActor in
                self?.routerStatus = ok ? .ready : .down
                self?.updateRefreshState()
            }
        }

        // Check each Proxy
        for i in proxies.indices {
            let p = proxies[i]
            if p.enabled {
                check(p.healthUrl) { [weak self] ok in
                    Task { @MainActor in
                        guard let self = self, i < self.proxies.count else { return }
                        self.proxies[i].status = ok ? .ready : .down
                        self.updateRefreshState()
                    }
                }
            } else {
                proxies[i].status = .down
            }
        }
    }

    private func updateRefreshState() {
        lastCheck = Date()
        if overallReady {
            lastAction = "All systems are running."
        } else {
            lastAction = "Needs attention — Auto-heal \(autoHealing ? "Active" : "Off")."
        }
    }

    // MARK: Environment Checks & Bootstrap

    func checkEnvironment() {
        DispatchQueue.global(qos: .userInitiated).async {
            var items: [EnvItem] = []
            let envPath = "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH\"; "

            // 1. macOS
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            items.append(EnvItem(name: "macOS", category: "Operating System", required: "Darwin", installed: osVersion, isReady: true, iconName: "laptopcomputer"))

            // 2. Homebrew
            let brewVer = self.execShell("\(envPath)command -v brew >/dev/null && brew --version | head -n 1 || echo 'Missing'")
            let brewOk = !brewVer.contains("Missing") && !brewVer.isEmpty
            let brewClean = brewVer.replacingOccurrences(of: "Homebrew ", with: "")
            items.append(EnvItem(name: "Homebrew", category: "Package Manager", required: "4.0+", installed: brewOk ? brewClean : "Not Installed", isReady: brewOk, iconName: "shippingbox"))

            // 3. Node.js (Require 20.x)
            let nodeVer = self.execShell("\(envPath)command -v node >/dev/null && node -v || echo 'Missing'")
            let nodeOk = nodeVer.contains("v20.")
            items.append(EnvItem(name: "Node.js", category: "JavaScript Runtime", required: "v20.20.2", installed: nodeOk ? nodeVer : (nodeVer.contains("v") ? nodeVer : "Not Installed"), isReady: nodeOk, iconName: "shield.checkmark"))

            // 4. 9Router CLI
            let routerVer = self.execShell("\(envPath)command -v 9router >/dev/null && 9router --version 2>/dev/null | head -n 1 || echo 'Missing'")
            let routerOk = !routerVer.contains("Missing") && !routerVer.isEmpty
            items.append(EnvItem(name: "9Router CLI", category: "Command Line Interface", required: "0.5.55", installed: routerOk ? routerVer : "Not Installed", isReady: routerOk, iconName: "viewfinder"))

            // 5. Git CLI
            let gitVer = self.execShell("\(envPath)command -v git >/dev/null && git --version | awk '{print $3}' || echo 'Missing'")
            let gitOk = !gitVer.contains("Missing") && !gitVer.isEmpty
            items.append(EnvItem(name: "Git", category: "Version Control", required: "2.0+", installed: gitOk ? gitVer : "Not Installed", isReady: gitOk, iconName: "arrow.triangle.branch"))

            // 6. Go Compiler
            let goVer = self.execShell("\(envPath)command -v go >/dev/null && go version | awk '{print $3}' || echo 'Missing'")
            let goOk = !goVer.contains("Missing") && !goVer.isEmpty
            items.append(EnvItem(name: "Go Compiler", category: "Proxy Binary Compiler", required: "1.20+", installed: goOk ? goVer : "Not Installed", isReady: goOk, iconName: "cpu"))

            Task { @MainActor in
                self.envItems = items
            }
        }
    }

    func runBootstrap() {
        isBusy = true
        isBootstrapping = true
        bootstrapOutput = "🚀 Running automated setup & dependency installation...\n"
        lastAction = "Installing dependencies..."
        addActivity("Environment setup initiated")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [managerPath(), "--start"]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in
                    self?.bootstrapOutput += str
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try p.run()
                p.waitUntilExit()
                Task { @MainActor in
                    self.isBusy = false
                    self.isBootstrapping = false
                    self.bootstrapOutput += "\n✅ Environment setup completed successfully!\n"
                    self.addActivity("All services started & environment ready")
                    self.checkEnvironment()
                    self.refresh()
                }
            } catch {
                Task { @MainActor in
                    self.isBusy = false
                    self.isBootstrapping = false
                    self.bootstrapOutput += "\n❌ Error: \(error.localizedDescription)\n"
                }
            }
        }
    }

    // MARK: - Process Actions

    func addActivity(_ title: String) {
        activities.insert(ActivityLog(title: title, timeAgo: "Just now"), at: 0)
        if activities.count > 10 { activities.removeLast() }
    }

    func repair() {
        runBootstrap()
    }

    func restart() {
        isBusy = true
        lastAction = "Restarting services..."
        addActivity("Restarting all services")
        runManager("--restart") { [weak self] _ in
            Task { @MainActor in
                self?.isBusy = false
                self?.refresh()
            }
        }
    }

    func stopAll() {
        isBusy = true
        lastAction = "Stopping all services..."
        addActivity("Stopped all services")
        runManager("--shutdown") { [weak self] _ in
            Task { @MainActor in
                self?.isBusy = false
                self?.refresh()
            }
        }
    }

    func openDashboard() {
        guard routerStatus == .ready, let url = URL(string: "http://127.0.0.1:20128/dashboard") else {
            lastAction = "9Router is not ready."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        lastAction = "Copied to clipboard"
    }

    // MARK: - Dynamic Proxies CRUD

    func addProxy(_ proxy: ProxyConfig) {
        proxies.append(proxy)
        saveProxies()
        addActivity("Added proxy \(proxy.name)")
        refresh()
    }

    func updateProxy(_ proxy: ProxyConfig) {
        if let idx = proxies.firstIndex(where: { $0.id == proxy.id }) {
            proxies[idx] = proxy
            saveProxies()
            addActivity("Updated proxy \(proxy.name)")
            refresh()
        }
    }

    func deleteProxy(_ proxy: ProxyConfig) {
        proxies.removeAll { $0.id == proxy.id }
        saveProxies()
        addActivity("Removed proxy \(proxy.name)")
        refresh()
    }

    func testProxy(_ proxy: ProxyConfig) {
        guard let url = URL(string: proxy.healthUrl) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let start = Date()
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                if let i = self?.proxies.firstIndex(where: { $0.id == proxy.id }) {
                    self?.proxies[i].status = (200..<400).contains(code) ? .ready : .down
                    self?.proxies[i].latency = (200..<400).contains(code) ? latencyMs : nil
                }
            }
        }.resume()
    }

    // MARK: - Lifecycle & Process Helpers

    func quit() {
        guard !quitting else { return }
        quitting = true
        timer?.invalidate()
        timer = nil
        runManagerSync("--shutdown")
        NSApp.terminate(nil)
    }

    func prepareForQuit() {
        quitting = true
        timer?.invalidate()
        timer = nil
        runManagerSync("--shutdown")
    }

    func finishQuit() {
        backend?.terminate()
        backend = nil
    }

    private func launchBackendIfNeeded() {
        guard backend == nil || backend?.isRunning == false else { return }
        let path = managerPath()
        guard !path.isEmpty else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [path, "--background"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        backend = p
    }

    private func managerPath() -> String {
        Bundle.main.path(forResource: "AI-Stack", ofType: "command") ?? ""
    }

    private func runManager(_ arg: String, completion: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [managerPath(), arg]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try p.run(); p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                completion(String(data: data, encoding: .utf8) ?? "")
            } catch { completion("Manager error: \(error.localizedDescription)") }
        }
    }

    private func runManagerSync(_ arg: String) {
        guard !managerPath().isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [managerPath(), arg]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }

    private func check(_ urlString: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: urlString) else { completion(false); return }
        var r = URLRequest(url: url); r.timeoutInterval = 2
        URLSession.shared.dataTask(with: r) { _, response, _ in
            completion((response as? HTTPURLResponse).map { 200..<400 ~= $0.statusCode } ?? false)
        }.resume()
    }

    nonisolated private func execShell(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func loadProxies() {
        proxies = proxyStore.load(defaults: [
            ProxyConfig(
                name: "AgentRouter Proxy",
                port: 8318,
                healthUrl: "http://127.0.0.1:8318/health",
                gitRepo: "https://github.com/trefeon/agentrouter-spoof-proxy.git",
                startCommand: "./agentrouter-proxy",
                enabled: true,
                version: "v3.3.0",
                iconName: "network"
            )
        ])
    }

    private func saveProxies() {
        proxyStore.save(proxies)
    }
}

// MARK: - Persistence

struct ProxyStore {
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AI Stack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("proxies.json")
    }()

    func load(defaults: [ProxyConfig]) -> [ProxyConfig] {
        guard let d = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode([ProxyConfig].self, from: d) else { return defaults }
        return p.isEmpty ? defaults : p
    }

    func save(_ proxies: [ProxyConfig]) {
        if let d = try? JSONEncoder().encode(proxies) {
            try? d.write(to: url, options: .atomic)
        }
    }
}

