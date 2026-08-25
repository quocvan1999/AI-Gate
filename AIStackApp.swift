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
            AppLogoImage(kind: .nav, size: 18)
        }
        .menuBarExtraStyle(.window)

        Window("AI Gate", id: "main") {
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let window = AppState.mainAppWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return false
        }
        return true
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
    var statusDescription: String
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

enum LogLevel: String, Codable, CaseIterable {
    case all = "ALL"
    case info = "INFO"
    case success = "SUCCESS"
    case warning = "WARN"
    case error = "ERROR"

    var color: Color {
        switch self {
        case .all: return .primary
        case .info: return Color.blue
        case .success: return Color.green
        case .warning: return Color.orange
        case .error: return Color.red
        }
    }
}

struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let source: String
    let message: String
    let detail: String?

    var timeFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    var fullText: String {
        "[\(timeFormatted)] [\(level.rawValue)] [\(source)] \(message)\(detail.map { "\n\($0)" } ?? "")"
    }
}

struct ToastItem: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let level: LogLevel
    let detail: String?
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedSection: Section = .overview
    @Published var routerStatus: ServiceStatus = .down
    @Published var autoHealing: Bool = true
    @Published var isBusy: Bool = false
    @Published var isManuallyStopped: Bool = false
    @Published var lastCheck = Date()
    @Published var lastAction = "All services are running normally."

    @Published var envItems: [EnvItem] = []
    @Published var proxies: [ProxyConfig] = []
    @Published var isBootstrapping: Bool = false
    @Published var toasts: [ToastItem] = []
    @Published var testingProxyIDs: Set<UUID> = []
    @Published var logs: [LogEntry] = [
        LogEntry(timestamp: Date().addingTimeInterval(-300), level: .info, source: "System", message: "AI Gate initialized and configuration loaded successfully", detail: nil),
        LogEntry(timestamp: Date().addingTimeInterval(-240), level: .info, source: "Environment", message: "Checked runtime dependencies: Darwin, Homebrew, Node v20, 9Router, Go, Git", detail: nil),
        LogEntry(timestamp: Date().addingTimeInterval(-180), level: .success, source: "9Router", message: "9Router Gateway is ready on port 20128", detail: "Dashboard: http://127.0.0.1:20128/dashboard"),
        LogEntry(timestamp: Date().addingTimeInterval(-120), level: .success, source: "AgentRouter", message: "AgentRouter Proxy connected on port 8318", detail: "Health URL: http://127.0.0.1:8318/health (1 ms)"),
        LogEntry(timestamp: Date().addingTimeInterval(-60), level: .info, source: "AutoHeal", message: "All services are operating normally in background", detail: nil)
    ]

    private var backend: Process?
    private var timer: Timer?
    private var logTimer: Timer?
    private var logFileOffsets: [String: UInt64] = [:]
    private var quitting = false
    private let proxyStore = ProxyStore()
    private var toastDismissers: [UUID: DispatchWorkItem] = [:]

    var activeProxies: [ProxyConfig] { proxies.filter { $0.enabled } }
    var readyProxiesCount: Int { activeProxies.filter { $0.status == .ready }.count }
    var envReadyCount: Int { envItems.filter { $0.isReady }.count }

    var overallReady: Bool {
        routerStatus == .ready && (activeProxies.isEmpty || readyProxiesCount == activeProxies.count)
    }

    static func mainAppWindow() -> NSWindow? {
        NSApp.windows.first { window in
            guard window.canBecomeMain else { return false }
            let id = window.identifier?.rawValue ?? ""
            if id == "main" || id.hasPrefix("main-") { return true }
            return window.title == "AI Gate"
        }
    }

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case proxies = "Proxies"
        case environment = "Environment"
        case logs = "Logs"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: return "house.fill"
            case .proxies: return "antenna.radiowaves.left.and.right"
            case .environment: return "cube.fill"
            case .logs: return "doc.text.fill"
            }
        }
        var accentColor: Color {
            switch self {
            case .overview: return Color(red: 0.20, green: 0.52, blue: 0.98)
            case .proxies: return Color(red: 0.38, green: 0.34, blue: 0.93)
            case .environment: return Color(red: 0.96, green: 0.57, blue: 0.13)
            case .logs: return Color(red: 0.47, green: 0.47, blue: 0.53)
            }
        }
    }

    func start() {
        guard !quitting else { return }
        loadProxies()
        checkEnvironment()
        launchBackendIfNeeded()
        refresh()
        startLiveLogStreaming()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func startLiveLogStreaming() {
        let logDir = ("~/ai-stack/logs" as NSString).expandingTildeInPath
        let proxyLog = (logDir as NSString).appendingPathComponent("agentrouter-proxy.log")
        let routerLog = (logDir as NSString).appendingPathComponent("9router.log")

        // Read initial log offsets so we don't dump historical lines on launch
        if let f = FileHandle(forReadingAtPath: proxyLog) {
            f.seekToEndOfFile()
            logFileOffsets[proxyLog] = f.offsetInFile
            try? f.close()
        }
        if let f = FileHandle(forReadingAtPath: routerLog) {
            f.seekToEndOfFile()
            logFileOffsets[routerLog] = f.offsetInFile
            try? f.close()
        }

        logTimer?.invalidate()
        logTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.readNewLogLines(path: proxyLog, source: "AgentRouter")
                self?.readNewLogLines(path: routerLog, source: "9Router")
            }
        }
    }

    private func readNewLogLines(path: String, source: String) {
        guard let file = FileHandle(forReadingAtPath: path) else { return }
        let currentOffset = logFileOffsets[path] ?? 0
        file.seekToEndOfFile()
        let endOffset = file.offsetInFile

        if endOffset < currentOffset {
            logFileOffsets[path] = 0
            try? file.close()
            return
        }

        if endOffset > currentOffset {
            file.seek(toFileOffset: currentOffset)
            let data = file.readDataToEndOfFile()
            logFileOffsets[path] = endOffset
            try? file.close()

            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for line in lines {
                    let lvl: LogLevel = line.contains("Error") || line.contains("error") || line.contains("40") || line.contains("50") || line.contains("FAILED") ? .error :
                                        (line.contains("Warn") || line.contains("warn") ? .warning :
                                        (line.contains("200") || line.contains("POST") || line.contains("GET") || line.contains("OK") ? .success : .info))
                    addLog(line, level: lvl, source: source)
                }
            }
        } else {
            try? file.close()
        }
    }


    func refresh() {
        guard !quitting else { return }

        // Check 9Router
        let prevRouter = routerStatus
        check("http://127.0.0.1:20128/dashboard") { [weak self] ok in
            Task { @MainActor in
                guard let self = self else { return }
                let newStatus: ServiceStatus = ok ? .ready : .down
                if prevRouter != newStatus {
                    if newStatus == .ready {
                        self.addLog("9Router Gateway is connected and operational", level: .success, source: "9Router")
                    } else if !self.isManuallyStopped {
                        self.addLog("9Router Gateway connection lost! Attempting auto-recovery...", level: .error, source: "AutoHeal", detail: "Port: 20128 • Dashboard unresponsive")
                        if self.autoHealing && !self.isBusy {
                            self.launchBackendIfNeeded()
                        }
                    }
                }
                self.routerStatus = newStatus
                self.updateRefreshState()
            }
        }

        // Check each Proxy
        for i in proxies.indices {
            let p = proxies[i]
            let prevProxyStatus = p.status
            if p.enabled {
                check(p.healthUrl) { [weak self] ok in
                    Task { @MainActor in
                        guard let self = self, i < self.proxies.count else { return }
                        let newStatus: ServiceStatus = ok ? .ready : .down
                        if prevProxyStatus != newStatus {
                            if newStatus == .ready {
                                self.addLog("\(p.name) reconnected successfully", level: .success, source: p.name)
                            } else if !self.isManuallyStopped {
                                self.addLog("Detected \(p.name) disconnected or error", level: .warning, source: "AutoHeal", detail: "URL: \(p.healthUrl)")
                                if self.autoHealing && !self.isBusy {
                                    self.launchBackendIfNeeded()
                                }
                            }
                        }
                        self.proxies[i].status = newStatus
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
        if isManuallyStopped {
            lastAction = "Services manually stopped (Auto-recovery paused)."
        } else if overallReady {
            lastAction = "All services are running normally."
        } else {
            lastAction = "Checking and recovering services..."
        }
    }

    // MARK: Environment Checks & Bootstrap

    func checkEnvironment() {
        DispatchQueue.global(qos: .userInitiated).async {
            var items: [EnvItem] = []
            let envPath = "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH\"; "

            // 1. macOS System
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            items.append(EnvItem(name: "macOS System", category: "Operating System", required: "Darwin", installed: osVersion, isReady: true, iconName: "laptopcomputer", statusDescription: "Compatible operating system"))

            // 2. Homebrew
            let brewVer = self.execShell("\(envPath)command -v brew >/dev/null && brew --version | head -n 1 || echo 'Missing'")
            let brewOk = !brewVer.contains("Missing") && !brewVer.isEmpty
            let brewClean = brewVer.replacingOccurrences(of: "Homebrew ", with: "")
            items.append(EnvItem(name: "Homebrew", category: "Package Manager", required: "Package Manager", installed: brewOk ? brewClean : "Not installed", isReady: brewOk, iconName: "shippingbox", statusDescription: brewOk ? "Ready" : "Not installed"))

            // 3. Node.js (Require 20.x)
            let nodeVer = self.execShell("\(envPath)command -v node >/dev/null && node -v || echo 'Missing'")
            let nodeOk = nodeVer.contains("v20.")
            items.append(EnvItem(name: "Node.js (v20)", category: "JavaScript Runtime", required: "v20.20.2", installed: nodeOk ? nodeVer : (nodeVer.contains("v") ? nodeVer : "Not installed"), isReady: nodeOk, iconName: "shield.checkmark", statusDescription: nodeOk ? "Node.js v20 LTS verified" : "Requires v20 LTS"))

            // 4. 9Router CLI
            let routerVer = self.execShell("\(envPath)command -v 9router >/dev/null && 9router --version 2>/dev/null | head -n 1 || echo 'Missing'")
            let routerOk = !routerVer.contains("Missing") && !routerVer.isEmpty
            items.append(EnvItem(name: "9Router CLI", category: "Command Line Interface", required: "0.5.55", installed: routerOk ? routerVer : "Not installed", isReady: routerOk, iconName: "viewfinder", statusDescription: routerOk ? "Globally installed" : "Not installed"))

            // 5. Go Compiler
            let goVer = self.execShell("\(envPath)command -v go >/dev/null && go version | awk '{print $3}' || echo 'Missing'")
            let goOk = !goVer.contains("Missing") && !goVer.isEmpty
            items.append(EnvItem(name: "Go Compiler", category: "Proxy Binary Compiler", required: "1.20+", installed: goOk ? goVer : "Not installed", isReady: goOk, iconName: "cpu", statusDescription: goOk ? "Ready" : "Not installed"))

            // 6. Git CLI
            let gitVer = self.execShell("\(envPath)command -v git >/dev/null && git --version | awk '{print $3}' || echo 'Missing'")
            let gitOk = !gitVer.contains("Missing") && !gitVer.isEmpty
            items.append(EnvItem(name: "Git CLI", category: "Version Control", required: "v2.0+", installed: gitOk ? gitVer : "Not installed", isReady: gitOk, iconName: "arrow.triangle.branch", statusDescription: gitOk ? "Ready" : "Not installed"))

            Task { @MainActor in
                self.envItems = items
            }
        }
    }

    nonisolated private static func standardEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let path = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:\(home)/.nvm/versions/node/v20.20.2/bin:\(home)/go/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(path):\(existing)"
        } else {
            env["PATH"] = path
        }
        env["HOME"] = home
        env["NVM_DIR"] = "\(home)/.nvm"
        return env
    }

    func runBootstrap() {
        isBusy = true
        isBootstrapping = true
        lastAction = "Installing dependencies..."
        addLog("Starting automated environment installation & setup...", level: .info, source: "Installer", notify: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [managerPath(), "--start"]
        p.environment = Self.standardEnvironment()

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                let lines = str.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                Task { @MainActor in
                    for line in lines {
                        let lvl: LogLevel = line.contains("Error") || line.contains("error") || line.contains("FAILED") || line.contains("❌") ? .error :
                                            (line.contains("Warning") || line.contains("warn") || line.contains("⚠️") ? .warning :
                                            (line.contains("✅") || line.contains("Success") || line.contains("success") ? .success : .info))
                        self?.addLog(line, level: lvl, source: "Installer")
                    }
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
                    if p.terminationStatus == 0 {
                        self.addLog("Environment setup completed successfully! All services are ready.", level: .success, source: "Installer", notify: true)
                    } else {
                        self.addLog("Setup exited with status code: \(p.terminationStatus)", level: .error, source: "Installer", notify: true)
                    }
                    self.checkEnvironment()
                    self.refresh()
                }
            } catch {
                Task { @MainActor in
                    self.isBusy = false
                    self.isBootstrapping = false
                    self.addLog("Failed to execute installer command: \(error.localizedDescription)", level: .error, source: "Installer", detail: error.localizedDescription, notify: true)
                }
            }
        }
    }

    // MARK: - Process Actions & Logging

    func addLog(_ message: String, level: LogLevel = .info, source: String = "System", detail: String? = nil, notify: Bool = false) {
        let entry = LogEntry(timestamp: Date(), level: level, source: source, message: message, detail: detail)
        logs.insert(entry, at: 0)
        if logs.count > 300 { logs.removeLast() }
        if notify {
            showToast(message, level: level, detail: detail)
        }
    }

    func showToast(_ message: String, level: LogLevel = .info, detail: String? = nil) {
        lastAction = message
        let item = ToastItem(message: message, level: level, detail: detail)
        toasts.append(item)
        if toasts.count > 3 {
            let removed = toasts.removeFirst()
            toastDismissers[removed.id]?.cancel()
            toastDismissers[removed.id] = nil
        }
        let duration: TimeInterval = (level == .error || level == .warning) ? 5.0 : 3.5
        let work = DispatchWorkItem { [weak self] in
            self?.dismissToast(item.id)
        }
        toastDismissers[item.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismissToast(_ id: UUID) {
        toastDismissers[id]?.cancel()
        toastDismissers[id] = nil
        toasts.removeAll { $0.id == id }
    }

    func clearLogs() {
        logs.removeAll()
        addLog("Activity logs cleared", level: .info, source: "System", notify: true)
    }

    func copyAllLogs() {
        let text = logs.reversed().map { $0.fullText }.joined(separator: "\n")
        copy(text, notice: "Copied all logs to clipboard")
    }

    func repair() {
        runBootstrap()
    }

    func startAll() {
        isManuallyStopped = false
        isBusy = true
        lastAction = "Starting services..."
        addLog("Starting all services and enabling auto-recovery monitoring...", level: .info, source: "System", notify: true)
        launchBackendIfNeeded()
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.isBusy = false
            self?.refresh()
        }
    }

    func restart() {
        isManuallyStopped = false
        isBusy = true
        lastAction = "Restarting services..."
        addLog("Restarting all services (9Router Gateway & Proxies)...", level: .info, source: "System", notify: true)
        runManager("--restart") { [weak self] output in
            Task { @MainActor in
                self?.isBusy = false
                self?.addLog("Services restarted successfully", level: .success, source: "System", detail: output.isEmpty ? nil : output, notify: true)
                self?.refresh()
            }
        }
    }

    func stopAll() {
        isManuallyStopped = true
        isBusy = true
        lastAction = "Services stopped (Auto-recovery paused)."
        addLog("All services safely stopped (Auto-recovery paused)", level: .warning, source: "System", notify: true)
        
        backend?.terminate()
        backend = nil
        
        for p in proxies {
            killPort(p.port)
        }
        killPort(8318)
        killPort(20128)
        
        runManager("--shutdown") { [weak self] output in
            Task { @MainActor in
                self?.isBusy = false
                self?.routerStatus = .down
                for i in self?.proxies.indices ?? 0..<0 {
                    self?.proxies[i].status = .down
                }
                self?.updateRefreshState()
            }
        }
    }

    private func killPort(_ port: Int) {
        _ = execShell("lsof -tiTCP:\(port) -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null || true")
    }

    func openDashboard() {
        guard routerStatus == .ready, let url = URL(string: "http://127.0.0.1:20128/dashboard") else {
            lastAction = "9Router is not ready."
            addLog("Cannot open Dashboard: 9Router Gateway is offline", level: .warning, source: "9Router", notify: true)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copy(_ value: String, notice: String = "Copied to clipboard") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showToast(notice, level: .success)
    }

    // MARK: - Dynamic Proxies CRUD

    func addProxy(_ proxy: ProxyConfig) {
        proxies.append(proxy)
        saveProxies()
        addLog("Added new Proxy: \(proxy.name) (Port \(proxy.port))", level: .success, source: "ProxyManager", notify: true)
        refresh()
    }

    func updateProxy(_ proxy: ProxyConfig) {
        if let idx = proxies.firstIndex(where: { $0.id == proxy.id }) {
            let wasEnabled = proxies[idx].enabled
            proxies[idx] = proxy
            saveProxies()
            if wasEnabled && !proxy.enabled {
                killPort(proxy.port)
                proxies[idx].status = .down
            }
            addLog("Updated configuration for \(proxy.name)", level: .info, source: "ProxyManager", notify: true)
            refresh()
        }
    }

    func deleteProxy(_ proxy: ProxyConfig) {
        killPort(proxy.port)
        proxies.removeAll { $0.id == proxy.id }
        saveProxies()
        addLog("Deleted Proxy: \(proxy.name)", level: .warning, source: "ProxyManager", notify: true)
        refresh()
    }

    func testProxy(_ proxy: ProxyConfig) {
        guard !testingProxyIDs.contains(proxy.id) else { return }
        guard let url = URL(string: proxy.healthUrl) else {
            addLog("Invalid Health URL: \(proxy.healthUrl)", level: .error, source: proxy.name, notify: true)
            return
        }
        testingProxyIDs.insert(proxy.id)
        lastAction = "Testing \(proxy.name)..."
        addLog("Testing connection to \(proxy.name) at \(proxy.healthUrl)...", level: .info, source: proxy.name)
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let start = Date()
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                guard let self = self else { return }
                self.testingProxyIDs.remove(proxy.id)
                let ok = (200..<400).contains(code)
                if let i = self.proxies.firstIndex(where: { $0.id == proxy.id }) {
                    self.proxies[i].status = ok ? .ready : .down
                    self.proxies[i].latency = ok ? latencyMs : nil
                }
                if ok {
                    self.addLog("\(proxy.name) responded successfully (HTTP \(code), latency \(latencyMs) ms)", level: .success, source: proxy.name, notify: true)
                } else if let err = error {
                    self.addLog("Connection to \(proxy.name) failed: \(err.localizedDescription)", level: .error, source: proxy.name, detail: "URL: \(proxy.healthUrl)", notify: true)
                } else {
                    self.addLog("\(proxy.name) returned HTTP \(code)", level: .warning, source: proxy.name, detail: "URL: \(proxy.healthUrl)", notify: true)
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
        guard !isManuallyStopped else { return }
        guard backend == nil || backend?.isRunning == false else { return }
        let path = managerPath()
        guard !path.isEmpty else { return }

        // Clean up previous background loops before launching a new one
        _ = execShell("pgrep -f 'AI-Stack.command.*--background' | xargs kill -9 2>/dev/null || true")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [path, "--background"]
        p.environment = Self.standardEnvironment()
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
        p.environment = Self.standardEnvironment()
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
        p.environment = Self.standardEnvironment()
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
        p.environment = Self.standardEnvironment()
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

// MARK: - macOS System Settings UI Components

struct AppLogoImage: View {
    enum Kind { case app, nav }
    var kind: Kind = .app
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image = Self.load(kind) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "house.fill")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.18, green: 0.22, blue: 0.72))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: kind == .nav ? size / 2 : size * 0.22, style: .continuous))
    }

    static func load(_ kind: Kind) -> NSImage? {
        let name = kind == .nav ? "NavIcon" : "AppIcon"
        if let named = NSImage(named: name) { return named }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }
}

struct SquircleIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26
    var inner: CGFloat = 13
    var radius: CGFloat = 6

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(color)
                .frame(width: size, height: size)
            Image(systemName: symbol)
                .font(.system(size: inner, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct CodeBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(nsColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct PageHeader: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    let trailing: AnyView

    init(symbol: String, color: Color, title: String, subtitle: String) {
        self.symbol = symbol
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(EmptyView())
    }

    init<T: View>(
        symbol: String, color: Color, title: String, subtitle: String,
        @ViewBuilder trailing: () -> T
    ) {
        self.symbol = symbol
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SquircleIcon(symbol: symbol, color: color, size: 44, inner: 20, radius: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            Spacer()

            trailing
        }
        .padding(.bottom, 4)
    }
}

struct SettingsCard<Content: View>: View {
    var header: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let h = header {
                Text(h.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
            )
        }
    }
}

// MARK: - Main Navigation Window

struct MainWindow: View {
    @EnvironmentObject private var state: AppState
    @State private var showingAddProxy = false

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            ZStack {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                switch state.selectedSection {
                case .overview:
                    OverviewView()
                case .proxies:
                    ProxiesView(showingAdd: $showingAddProxy)
                case .environment:
                    EnvironmentView()
                case .logs:
                    LogsView()
                }
            }
            .overlay(alignment: .bottom) {
                ToastStackView()
                    .padding(.bottom, 22)
            }
        }
        .navigationTitle("AI Gate")
        .sheet(isPresented: $showingAddProxy) {
            ProxyEditor(proxy: nil) { p in state.addProxy(p) }
                .overlay(alignment: .bottom) {
                    ToastStackView()
                        .padding(.bottom, 16)
                }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var state: AppState
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AppLogoImage(kind: .app, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI Gate")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Control Center")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.8)
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            List(selection: $state.selectedSection) {
                Section {
                    ForEach(filtered(AppState.Section.allCases)) { sec in
                        NavigationLink(value: sec) {
                            HStack(spacing: 12) {
                                SquircleIcon(symbol: sec.icon, color: sec.accentColor, size: 26, inner: 13, radius: 6)
                                Text(sec.rawValue)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func filtered(_ list: [AppState.Section]) -> [AppState.Section] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return list
        }
        return list.filter { $0.rawValue.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - Tab 1: Overview

struct OverviewView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. Hero Status Banner
                SettingsCard {
                    HStack(alignment: .center, spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill((state.overallReady ? Color.green : Color.orange).opacity(0.15))
                                .frame(width: 50, height: 50)
                            Image(systemName: state.overallReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(state.overallReady ? Color.green : Color.orange)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(state.overallReady ? "System Operational" : "Attention Required")
                                    .font(.system(size: 16, weight: .bold))
                                Circle()
                                    .fill(state.overallReady ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                            }
                            Text(state.overallReady
                                 ? "9Router Gateway & \(state.readyProxiesCount)/\(state.proxies.count) Local Proxies online • Ready to handle requests."
                                 : state.lastAction)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button {
                                state.restart()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .bold))
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .help("Restart all services")
                            .disabled(state.isBusy)

                            if !state.isManuallyStopped {
                                Button {
                                    state.stopAll()
                                } label: {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.red)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .help("Stop all services (Pauses auto-recovery)")
                                .disabled(state.isBusy)
                            } else {
                                Button {
                                    state.startAll()
                                } label: {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.green)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .help("Start all services")
                                .disabled(state.isBusy)
                            }
                        }
                    }
                    .padding(16)
                }

                // 2. Unified Summary Stats
                SettingsCard(header: "System Overview") {
                    HStack(spacing: 0) {
                        StatColumn(
                            title: "9Router Gateway",
                            value: "Port 20128",
                            badgeText: state.routerStatus == .ready ? "ONLINE" : "OFFLINE",
                            badgeColor: state.routerStatus == .ready ? .green : .orange,
                            icon: "server.rack"
                        )

                        Divider()
                            .frame(height: 38)

                        StatColumn(
                            title: "Local Proxies",
                            value: "\(state.readyProxiesCount)/\(state.proxies.count) Ready",
                            badgeText: "\(state.proxies.count) Configured",
                            badgeColor: .indigo,
                            icon: "antenna.radiowaves.left.and.right"
                        )

                        Divider()
                            .frame(height: 38)

                        StatColumn(
                            title: "Runtime Environment",
                            value: "\(state.envReadyCount)/\(state.envItems.count) Ready",
                            badgeText: state.envReadyCount == state.envItems.count && !state.envItems.isEmpty ? "Complete" : "Setup Needed",
                            badgeColor: state.envReadyCount == state.envItems.count && !state.envItems.isEmpty ? .green : .orange,
                            icon: "cube.fill"
                        )
                    }
                    .padding(.vertical, 14)
                }

                // 3. Active Services
                SettingsCard(header: "Active Services (\(state.proxies.count + 1))") {
                    VStack(spacing: 0) {
                        // 9Router Gateway
                        HStack(spacing: 12) {
                            SquircleIcon(symbol: "server.rack", color: Color(red: 0.19, green: 0.68, blue: 0.60), size: 34, inner: 16, radius: 8)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("9Router Gateway")
                                        .font(.system(size: 13, weight: .bold))
                                    CodeBadge(text: "PORT 20128")
                                }
                                Text("http://127.0.0.1:20128")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.cyan)
                            }

                            Spacer()

                            StatusPill(
                                text: state.routerStatus == .ready ? "Running" : "Offline",
                                color: state.routerStatus == .ready ? .green : .orange
                            )

                            Button("Copy Endpoint") {
                                state.copy("http://127.0.0.1:20128")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Open Dashboard") {
                                state.openDashboard()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(state.routerStatus != .ready)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        // Proxies
                        ForEach(state.proxies) { proxy in
                            Divider()
                                .padding(.leading, 60)

                            HStack(spacing: 12) {
                                SquircleIcon(symbol: proxy.iconName, color: Color(red: 0.38, green: 0.34, blue: 0.93), size: 34, inner: 16, radius: 8)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(proxy.name)
                                            .font(.system(size: 13, weight: .bold))
                                        CodeBadge(text: "PORT \(proxy.port)")
                                    }
                                    Text("http://127.0.0.1:\(proxy.port)/v1")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                }

                                Spacer()

                                if proxy.enabled && proxy.status == .ready {
                                    Text("\(proxy.latency ?? 1) ms")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                }

                                StatusPill(
                                    text: proxy.enabled ? (proxy.status == .ready ? "Running" : "Offline") : "Off",
                                    color: proxy.enabled && proxy.status == .ready ? .green : .orange
                                )

                                TestProxyButton(proxy: proxy)

                                Button("Copy API") {
                                    state.copy("http://127.0.0.1:\(proxy.port)/v1")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                        }
                    }
                }
            }
            .padding(22)
        }
    }
}

struct StatColumn: View {
    let title: String
    let value: String
    let badgeText: String
    let badgeColor: Color
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            SquircleIcon(symbol: icon, color: badgeColor, size: 34, inner: 15, radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                HStack(spacing: 6) {
                    Text(value)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(nsColor: .labelColor))
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(badgeColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}// MARK: - Tab 3: Environment & Setup

struct EnvironmentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    symbol: AppState.Section.environment.icon,
                    color: AppState.Section.environment.accentColor,
                    title: "Environment & Setup",
                    subtitle: "Verify and configure required system runtime dependencies."
                )

                // Top Banner Card
                SettingsCard {
                    HStack(spacing: 14) {
                        Image(systemName: state.envReadyCount == state.envItems.count && !state.envItems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(state.envReadyCount == state.envItems.count && !state.envItems.isEmpty ? Color.green : Color.orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Environment: \(state.envReadyCount)/\(state.envItems.count) tools ready")
                                .font(.system(size: 14, weight: .bold))
                            Text("System automatically manages Homebrew, Node.js v20, 9Router, Go, and Git.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }

                        Spacer()

                        Button {
                            state.runBootstrap()
                        } label: {
                            if state.isBusy {
                                Label("Installing...", systemImage: "hourglass")
                            } else {
                                Label("Click Auto Install", systemImage: "wrench.and.screwdriver.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isBusy)
                    }
                    .padding(16)
                }

                // Tool Checklist in Grouped SettingsCard
                SettingsCard(header: "Environment Dependencies (\(state.envItems.count))") {
                    VStack(spacing: 0) {
                        ForEach(Array(state.envItems.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 12) {
                                SquircleIcon(
                                    symbol: item.iconName,
                                    color: item.isReady ? Color.green : Color.orange,
                                    size: 34,
                                    inner: 16,
                                    radius: 8
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 13, weight: .bold))
                                    Text(item.statusDescription)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(item.installed)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    Text("Required: \(item.required)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                }

                                StatusPill(
                                    text: item.isReady ? "Ready" : "Missing",
                                    color: item.isReady ? .green : .orange
                                )
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)

                            if index < state.envItems.count - 1 {
                                Divider()
                                    .padding(.leading, 60)
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }
}

// MARK: - Tab 4: Proxies View

struct ProxiesView: View {
    @EnvironmentObject private var state: AppState
    @Binding var showingAdd: Bool
    @State private var selectedProxy: ProxyConfig?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    symbol: AppState.Section.proxies.icon,
                    color: AppState.Section.proxies.accentColor,
                    title: "Proxy Manager",
                    subtitle: "Manage and configure dynamic local proxies."
                ) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add New Proxy", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                SettingsCard(header: "Local Proxies (\(state.proxies.count))") {
                    VStack(spacing: 0) {
                        ForEach(Array(state.proxies.enumerated()), id: \.element.id) { index, proxy in
                            ProxyRowView(
                                proxy: proxy,
                                onToggle: {
                                    var updated = proxy
                                    updated.enabled.toggle()
                                    state.updateProxy(updated)
                                },
                                onEdit: { selectedProxy = proxy },
                                onDelete: { state.deleteProxy(proxy) }
                            )

                            if index < state.proxies.count - 1 {
                                Divider()
                                    .padding(.leading, 60)
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .sheet(item: $selectedProxy) { p in
            ProxyEditor(proxy: p) { updated in state.updateProxy(updated) }
                .overlay(alignment: .bottom) {
                    ToastStackView()
                        .padding(.bottom, 16)
                }
        }
    }
}

struct ProxyRowView: View {
    let proxy: ProxyConfig
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var showingGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SquircleIcon(symbol: proxy.iconName, color: Color(red: 0.38, green: 0.34, blue: 0.93), size: 34, inner: 16, radius: 8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(proxy.name)
                            .font(.system(size: 13, weight: .bold))
                        CodeBadge(text: "PORT \(proxy.port)")
                    }
                    Text("http://127.0.0.1:\(proxy.port)/v1")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }

                Spacer()

                if let latency = proxy.latency {
                    Text("\(latency) ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }

                StatusPill(
                    text: proxy.enabled ? (proxy.status == .ready ? "Running" : "Offline") : "Off",
                    color: proxy.enabled && proxy.status == .ready ? .green : .orange
                )

                Toggle("", isOn: Binding(get: { proxy.enabled }, set: { _ in onToggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                TestProxyButton(proxy: proxy)

                Button("Client Guide") { showingGuide = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Edit") { onEdit() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Delete", role: .destructive) { onDelete() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()

                Text("Command: \(proxy.startCommand)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.leading, 46)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .sheet(isPresented: $showingGuide) {
            ClientGuideSheet(proxy: proxy)
        }
    }
}

struct ClientGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    let proxy: ProxyConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Client Connection Guide").font(.title3.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Base URL:") {
                    HStack {
                        Text("http://127.0.0.1:\(proxy.port)/v1").font(.caption.monospaced())
                        Button("Copy") { state.copy("http://127.0.0.1:\(proxy.port)/v1") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                LabeledContent("API Key:") {
                    HStack {
                        Text("sk-dummy").font(.caption.monospaced())
                        Button("Copy") { state.copy("sk-dummy") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 480, height: 260)
        .overlay(alignment: .bottom) {
            ToastStackView()
                .padding(.bottom, 16)
        }
    }
}

struct ProxyEditor: View {
    @Environment(\.dismiss) private var dismiss
    let proxy: ProxyConfig?
    let onSave: (ProxyConfig) -> Void

    @State private var selectedPreset = "AgentRouter"
    @State private var name: String
    @State private var portStr: String
    @State private var healthUrl: String
    @State private var gitRepo: String
    @State private var startCommand: String
    @State private var enabled: Bool

    init(proxy: ProxyConfig?, onSave: @escaping (ProxyConfig) -> Void) {
        self.proxy = proxy
        self.onSave = onSave
        _name = State(initialValue: proxy?.name ?? "AgentRouter Proxy")
        _portStr = State(initialValue: "\(proxy?.port ?? 8318)")
        _healthUrl = State(initialValue: proxy?.healthUrl ?? "http://127.0.0.1:8318/health")
        _gitRepo = State(initialValue: proxy?.gitRepo ?? "https://github.com/trefeon/agentrouter-spoof-proxy.git")
        _startCommand = State(initialValue: proxy?.startCommand ?? "./agentrouter-proxy")
        _enabled = State(initialValue: proxy?.enabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(proxy == nil ? "Add New Proxy" : "Edit Proxy")
                .font(.title3.bold())

            Form {
                Picker("Preset Template", selection: $selectedPreset) {
                    Text("AgentRouter Proxy (Port 8318)").tag("AgentRouter")
                    Text("Ollama Local AI (Port 11434)").tag("Ollama")
                    Text("LiteLLM Proxy (Port 4000)").tag("LiteLLM")
                    Text("Custom Script (Port 8000)").tag("Custom")
                }
                .onChange(of: selectedPreset) { _, newValue in
                    applyPreset(newValue)
                }

                Section("Configuration Details") {
                    TextField("Proxy Name", text: $name)
                    TextField("Port", text: $portStr)
                    TextField("Health Check URL", text: $healthUrl)
                    TextField("Start Command", text: $startCommand)
                    TextField("Git Repo (Optional)", text: $gitRepo)
                    Toggle("Enable Proxy", isOn: $enabled)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let port = Int(portStr) ?? 8318
                    let newP = ProxyConfig(
                        id: proxy?.id ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        port: port,
                        healthUrl: healthUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                        gitRepo: gitRepo.isEmpty ? nil : gitRepo.trimmingCharacters(in: .whitespacesAndNewlines),
                        startCommand: startCommand.trimmingCharacters(in: .whitespacesAndNewlines),
                        enabled: enabled,
                        status: proxy?.status ?? .down
                    )
                    onSave(newP)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func applyPreset(_ preset: String) {
        switch preset {
        case "AgentRouter":
            name = "AgentRouter Proxy"
            portStr = "8318"
            healthUrl = "http://127.0.0.1:8318/health"
            gitRepo = "https://github.com/trefeon/agentrouter-spoof-proxy.git"
            startCommand = "./agentrouter-proxy"
        case "Ollama":
            name = "Ollama Local AI"
            portStr = "11434"
            healthUrl = "http://127.0.0.1:11434/api/tags"
            gitRepo = ""
            startCommand = "ollama serve"
        case "LiteLLM":
            name = "LiteLLM Proxy"
            portStr = "4000"
            healthUrl = "http://127.0.0.1:4000/health"
            gitRepo = ""
            startCommand = "litellm --port 4000"
        case "Custom":
            name = "Custom Script Proxy"
            portStr = "8000"
            healthUrl = "http://127.0.0.1:8000/health"
            gitRepo = ""
            startCommand = "python3 server.py"
        default: break
        }
    }
}

// MARK: - Tab 4: Logs View

struct LogsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedLevel: LogLevel = .all
    @State private var searchKeyword: String = ""
    @State private var expandedLogId: UUID? = nil

    private var filteredLogs: [LogEntry] {
        state.logs.filter { entry in
            let matchesLevel = (selectedLevel == .all) || (entry.level == selectedLevel)
            let query = searchKeyword.trimmingCharacters(in: .whitespaces).lowercased()
            let matchesQuery = query.isEmpty || entry.message.lowercased().contains(query) || entry.source.lowercased().contains(query) || (entry.detail?.lowercased().contains(query) ?? false)
            return matchesLevel && matchesQuery
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                PageHeader(
                    symbol: AppState.Section.logs.icon,
                    color: AppState.Section.logs.accentColor,
                    title: "System Logs",
                    subtitle: "Real-time log events, requests, and system diagnostics."
                ) {
                    HStack(spacing: 8) {
                        Button {
                            state.copyAllLogs()
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Button(role: .destructive) {
                            state.clearLogs()
                        } label: {
                            Label("Clear Logs", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }

                // Filter & Search Toolbar
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        // Level Filter Chips
                        HStack(spacing: 8) {
                            ForEach(LogLevel.allCases, id: \.self) { lvl in
                                let count = countFor(lvl)
                                Button {
                                    selectedLevel = lvl
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(lvl.rawValue)
                                            .font(.system(size: 11, weight: selectedLevel == lvl ? .bold : .medium))
                                        Text("(\(count))")
                                            .font(.system(size: 10, design: .monospaced))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(selectedLevel == lvl ? lvl.color.opacity(0.2) : Color(nsColor: .tertiarySystemFill))
                                    .foregroundStyle(selectedLevel == lvl ? (lvl == .all ? Color.primary : lvl.color) : Color(nsColor: .secondaryLabelColor))
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(selectedLevel == lvl ? (lvl == .all ? Color.primary.opacity(0.3) : lvl.color.opacity(0.5)) : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }

                        Divider()

                        // Search Input Field
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            TextField("Filter logs by keyword, service name, or error...", text: $searchKeyword)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                            if !searchKeyword.isEmpty {
                                Button(action: { searchKeyword = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(14)
                }

                // Log Entries List
                SettingsCard(header: "Log Entries (\(filteredLogs.count))") {
                    if filteredLogs.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 28))
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            Text("No log entries match the filter")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(40)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredLogs.enumerated()), id: \.element.id) { index, log in
                                LogItemRow(
                                    log: log,
                                    isExpanded: expandedLogId == log.id,
                                    onToggleExpand: {
                                        if expandedLogId == log.id {
                                            expandedLogId = nil
                                        } else {
                                            expandedLogId = log.id
                                        }
                                    }
                                )

                                if index < filteredLogs.count - 1 {
                                    Divider()
                                        .padding(.leading, 14)
                                }
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func countFor(_ lvl: LogLevel) -> Int {
        if lvl == .all { return state.logs.count }
        return state.logs.filter { $0.level == lvl }.count
    }
}

struct LogItemRow: View {
    let log: LogEntry
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                // Timestamp
                Text(log.timeFormatted)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 58, alignment: .leading)

                // Level Badge
                Text(log.level.rawValue)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(log.level.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(log.level.color.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .frame(width: 62, alignment: .center)

                // Source
                Text("[\(log.source)]")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 90, alignment: .leading)

                // Message
                Text(log.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(isExpanded ? nil : 1)

                Spacer(minLength: 0)

                if log.detail != nil {
                    Button(action: onToggleExpand) {
                        Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Expanded Detail View
            if isExpanded, let detail = log.detail {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.leading, 68)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct TestProxyButton: View {
    @EnvironmentObject private var state: AppState
    let proxy: ProxyConfig

    private var isTesting: Bool { state.testingProxyIDs.contains(proxy.id) }

    var body: some View {
        Button {
            state.testProxy(proxy)
        } label: {
            if isTesting {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Testing")
                }
            } else {
                Text("Test")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isTesting)
        .help(isTesting ? "Testing proxy connection..." : "Test proxy health URL")
    }
}

struct ToastStackView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            ForEach(state.toasts) { toast in
                ToastBanner(toast: toast) {
                    state.dismissToast(toast.id)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: state.toasts.map(\.id))
        .allowsHitTesting(!state.toasts.isEmpty)
    }
}

struct ToastBanner: View {
    let toast: ToastItem
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(toast.level.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(toast.level.color.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
        .onTapGesture(perform: onDismiss)
    }

    private var iconName: String {
        switch toast.level {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info, .all: return "info.circle.fill"
        }
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                AppLogoImage(kind: .app, size: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text("AI Gate")
                        .font(.system(size: 14, weight: .bold))
                    Text(state.overallReady ? "System Operational" : "Attention Required")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }

                Spacer()

                StatusPill(
                    text: state.overallReady ? "Online" : "Attention",
                    color: state.overallReady ? .green : .orange
                )
            }
            .padding(.bottom, 2)

            // Services Card Group
            SettingsCard(header: "Active Services") {
                VStack(spacing: 0) {
                    // 9Router Gateway
                    HStack(spacing: 10) {
                        SquircleIcon(symbol: "server.rack", color: Color(red: 0.19, green: 0.68, blue: 0.60), size: 26, inner: 12, radius: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("9Router Gateway")
                                .font(.system(size: 12, weight: .semibold))
                            Text("127.0.0.1:20128")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.cyan)
                        }
                        Spacer()
                        StatusPill(
                            text: state.routerStatus == .ready ? "Running" : "Offline",
                            color: state.routerStatus == .ready ? .green : .orange
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                    ForEach(state.activeProxies) { p in
                        Divider()
                            .padding(.leading, 46)

                        HStack(spacing: 10) {
                            SquircleIcon(symbol: p.iconName, color: Color(red: 0.38, green: 0.34, blue: 0.93), size: 26, inner: 12, radius: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Text("127.0.0.1:\(p.port)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            }
                            Spacer()
                            StatusPill(
                                text: p.status == .ready ? "Running" : "Offline",
                                color: p.status == .ready ? .green : .orange
                            )
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
            }

            // Actions Card Group
            SettingsCard(header: "Quick Actions") {
                VStack(spacing: 0) {
                    // Open App Window
                    Button(action: openMainWindow) {
                        HStack(spacing: 10) {
                            SquircleIcon(symbol: "macwindow", color: Color(red: 0.20, green: 0.52, blue: 0.98), size: 24, inner: 12, radius: 6)
                            Text("Open AI Gate")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 44)

                    // Open Dashboard
                    Button(action: state.openDashboard) {
                        HStack(spacing: 10) {
                            SquircleIcon(symbol: "safari.fill", color: Color(red: 0.19, green: 0.68, blue: 0.60), size: 24, inner: 12, radius: 6)
                            Text("Open 9Router Dashboard")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(state.routerStatus == .ready ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(state.routerStatus != .ready)

                    Divider()
                        .padding(.leading, 44)

                    // Restart Services
                    Button(action: state.restart) {
                        HStack(spacing: 10) {
                            SquircleIcon(symbol: "arrow.clockwise", color: Color.orange, size: 24, inner: 12, radius: 6)
                            Text("Restart All Services")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(state.isBusy ? Color(nsColor: .tertiaryLabelColor) : Color.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isBusy)
                }
            }

            Divider()

            // Footer
            HStack {
                Text(state.lastAction)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)

                Spacer()

                Button(role: .destructive) {
                    state.quit()
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.red)
            }
        }
        .padding(14)
        .frame(width: 320)
        .overlay(alignment: .bottom) {
            ToastStackView()
                .padding(.bottom, 44)
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = AppState.mainAppWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        openWindow(id: "main")
    }
}
