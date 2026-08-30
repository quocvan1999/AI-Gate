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
            MenuBarLogoLabel()
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

struct CursorBridgeStatus: Equatable {
    var installed: Bool = false
    var loggedIn: Bool = false
    var funnelEnabled: Bool = false
    var wanted: Bool = false
    var autoHeal: Bool = true
    var publicUrl: String = ""
    var baseUrl: String = ""
    var targetPort: Int = 20128
    var message: String = "Đang kiểm tra Cursor Bridge..."
    var lastHealAt: String = ""
    var updatedAt: String = ""

    var isReady: Bool { funnelEnabled && !baseUrl.isEmpty }
    var isRecovering: Bool { wanted && autoHeal && !funnelEnabled }
}

struct ProviderHealthItem: Equatable, Identifiable {
    var id: String { model }
    var model: String = ""
    var provider: String = ""
    var name: String = ""
    var active: Bool = false
    var testStatus: String = ""
    var errorCode: Int? = nil
    var lastError: String = ""
    var usable: Bool = false
}

struct PathHealthStatus: Equatable {
    var localRouter: Bool = false
    var localApi: Bool = false
    var localDashboardMs: Int = 0
    var localApiMs: Int = 0
    var funnelCli: Bool = false
    var wanted: Bool = false
    var baseUrl: String = ""
    var publicReachable: Bool = false
    var publicStatus: Int = 0
    var publicMs: Int = 0
    var publicAuthenticated: Bool = false
    var publicAuthStatus: Int = 0
    var cursorConfigured: Bool = false
    var cursorMessage: String = ""
    var cursorBaseUrl: String = ""
    var comboName: String = "my-combo"
    var comboHealthy: Bool = false
    var usableProviders: Int = 0
    var providerCount: Int = 0
    var providers: [ProviderHealthItem] = []
    var cursorPathOk: Bool = false
    var message: String = "Đang kiểm tra đường kết nối..."

    var localOk: Bool { localRouter }
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
    @Published var bridgeStatus = CursorBridgeStatus()
    @Published var pathHealth = PathHealthStatus()
    @Published var bridgeBusy: Bool = false
    @Published var bridgeHealing: Bool = false
    @Published var bridgeSetupRunning: Bool = false
    @Published var cursorApplyBusy: Bool = false
    @Published var cursorApplyMessage: String = ""
    @Published var nineRouterApiKey: String = ""
    @Published var availableModels: [String] = []
    @Published var selectedBridgeModel: String = "my-combo"
    private var lastBridgeHealAttempt: Date? = nil
    private var previousBridgeReady: Bool? = nil
    private var healthBusy: Bool = false
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
    private let bridgeStore = CursorBridgeStore()
    private var toastDismissers: [UUID: DispatchWorkItem] = [:]

    var activeProxies: [ProxyConfig] { proxies.filter { $0.enabled } }
    var readyProxiesCount: Int { activeProxies.filter { $0.status == .ready }.count }
    var envReadyCount: Int { envItems.filter { $0.isReady }.count }

    var overallReady: Bool {
        let localOk = routerStatus == .ready && (activeProxies.isEmpty || readyProxiesCount == activeProxies.count)
        guard localOk else { return false }
        // When Bridge is wanted, Cursor path must also be healthy.
        if bridgeStatus.wanted {
            return pathHealth.cursorPathOk || (pathHealth.publicReachable && pathHealth.cursorConfigured)
        }
        return true
    }

    var statusHeadline: String {
        if routerStatus != .ready {
            return "Attention Required"
        }
        if overallReady { return "System Operational" }
        if bridgeStatus.wanted && !pathHealth.cursorPathOk {
            return "Local OK • Cursor path issue"
        }
        return "Attention Required"
    }

    var statusDetailLine: String {
        if overallReady {
            let bridgeNote = bridgeStatus.wanted
                ? " • Cursor path OK"
                : ""
            return "9Router & \(readyProxiesCount)/\(proxies.count) proxies online\(bridgeNote)"
        }
        if !pathHealth.message.isEmpty { return pathHealth.message }
        return lastAction
    }

    var cursorSetupSnippet: String {
        let base = bridgeStatus.baseUrl.isEmpty ? "https://YOUR-MACHINE.ts.net/v1" : bridgeStatus.baseUrl
        let key = nineRouterApiKey.isEmpty ? "(open 9router dashboard → copy API key)" : nineRouterApiKey
        let model = selectedBridgeModel.isEmpty ? "my-combo" : selectedBridgeModel
        return """
        Cursor → Settings → Models
        1) OpenAI API Key: ON
        2) Override OpenAI Base URL:
        \(base)
        3) API Key:
        \(key)
        4) Add custom model:
        \(model)
        """
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
        case cursorBridge = "Cursor Bridge"
        case proxies = "Proxies"
        case environment = "Environment"
        case logs = "Logs"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: return "house.fill"
            case .cursorBridge: return "link.circle.fill"
            case .proxies: return "antenna.radiowaves.left.and.right"
            case .environment: return "cube.fill"
            case .logs: return "doc.text.fill"
            }
        }
        var accentColor: Color {
            switch self {
            case .overview: return Color(red: 0.20, green: 0.52, blue: 0.98)
            case .cursorBridge: return Color(red: 0.18, green: 0.72, blue: 0.55)
            case .proxies: return Color(red: 0.38, green: 0.34, blue: 0.93)
            case .environment: return Color(red: 0.96, green: 0.57, blue: 0.13)
            case .logs: return Color(red: 0.47, green: 0.47, blue: 0.53)
            }
        }
    }

    func start() {
        guard !quitting else { return }
        loadProxies()
        selectedBridgeModel = bridgeStore.loadSelectedModel(default: "my-combo")
        checkEnvironment()
        launchBackendIfNeeded()
        refresh()
        refreshCursorBridge()
        startLiveLogStreaming()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshCursorBridge()
            }
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

            // 7. Tailscale (optional — required for Cursor Bridge)
            let tsPath = self.execShell("""
            \(envPath)
            if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then echo "/Applications/Tailscale.app/Contents/MacOS/Tailscale"; \
            elif command -v tailscale >/dev/null 2>&1; then command -v tailscale; \
            else echo Missing; fi
            """)
            let tsOk = !tsPath.contains("Missing") && !tsPath.isEmpty
            let tsState = tsOk ? self.execShell("\"\(tsPath)\" status --json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"BackendState\",\"\"))' 2>/dev/null || echo unknown") : "Missing"
            let tsReady = tsOk && tsState == "Running"
            items.append(EnvItem(
                name: "Tailscale",
                category: "Cursor Bridge Tunnel",
                required: "App + Login",
                installed: tsOk ? (tsReady ? "Running" : "Installed (\(tsState.isEmpty ? "NeedsLogin" : tsState))") : "Not installed",
                isReady: tsReady,
                iconName: "network",
                statusDescription: tsReady ? "Ready for Funnel" : (tsOk ? "Open Tailscale and log in" : "Install Tailscale (free)")
            ))

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
        lastAction = "Stopping all services (Funnel + 9Router + proxies)..."
        addLog("Stopping all related services: Funnel, 9Router, proxies, auto-heal...", level: .warning, source: "System", notify: true)

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
                self?.bridgeStatus.funnelEnabled = false
                self?.bridgeStatus.wanted = false
                self?.bridgeStatus.baseUrl = ""
                self?.bridgeStatus.publicUrl = ""
                self?.bridgeStatus.message = "Đã tắt hết dịch vụ (Funnel + gateway + proxies)."
                self?.pathHealth = PathHealthStatus(
                    message: "Đã dừng toàn bộ — Enable Bridge / Start lại khi cần."
                )
                for i in self?.proxies.indices ?? 0..<0 {
                    self?.proxies[i].status = .down
                }
                self?.updateRefreshState()
                self?.addLog("All related services stopped (no auto-restore until Start/Enable)", level: .success, source: "System", notify: true)
                self?.refreshCursorBridge()
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

    func openTailscaleInstall() {
        if let url = URL(string: "https://tailscale.com/download/mac") {
            NSWorkspace.shared.open(url)
        }
    }

    func openTailscaleApp() {
        let app = "/Applications/Tailscale.app"
        if FileManager.default.fileExists(atPath: app) {
            NSWorkspace.shared.open(URL(fileURLWithPath: app))
        } else {
            openTailscaleInstall()
        }
    }

    func openTailscaleAdminFunnel() {
        if let url = URL(string: "https://login.tailscale.com/admin/acls") {
            NSWorkspace.shared.open(url)
        }
    }

    func copy(_ value: String, notice: String = "Copied to clipboard") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showToast(notice, level: .success)
    }

    func copyCursorSetup() {
        copy(cursorSetupSnippet, notice: "Copied Cursor setup instructions")
    }

    func setBridgeModel(_ model: String) {
        selectedBridgeModel = model
        bridgeStore.saveSelectedModel(model)
    }

    // MARK: - Cursor Bridge

    func refreshCursorBridge() {
        guard !quitting else { return }
        loadNineRouterCredentials()

        runManager("--bridge-status") { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                if let parsed = Self.parseBridgeStatus(output) {
                    let wasReady = self.previousBridgeReady
                    self.bridgeStatus = parsed
                    self.previousBridgeReady = parsed.isReady

                    if wasReady == true && !parsed.isReady && parsed.wanted {
                        self.addLog("Cursor Bridge Funnel dropped — auto-heal will retry", level: .warning, source: "CursorBridge", detail: parsed.message)
                    } else if wasReady == false && parsed.isReady && parsed.wanted {
                        self.addLog("Cursor Bridge Funnel restored: \(parsed.baseUrl)", level: .success, source: "CursorBridge")
                    }

                    // App-side nudge if shell loop hasn't healed yet (e.g. right after wake).
                    if parsed.isRecovering && !self.bridgeBusy && !self.isManuallyStopped {
                        self.maybeRequestBridgeHeal()
                    }
                }
                self.refreshPathHealth()
            }
        }
    }

    func refreshPathHealth() {
        guard !quitting, !healthBusy else { return }
        healthBusy = true
        let model = selectedBridgeModel.isEmpty ? "my-combo" : selectedBridgeModel
        runManager("--bridge-health", extraArgs: ["--model", model]) { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                self.healthBusy = false
                if let parsed = Self.parsePathHealth(output) {
                    self.pathHealth = parsed
                }
            }
        }
    }

    func applyCursorConfig(relaunchNotice: Bool = true) {
        guard !cursorApplyBusy else { return }
        cursorApplyBusy = true
        let model = selectedBridgeModel.isEmpty ? "my-combo" : selectedBridgeModel
        addLog("Applying Bridge settings into Cursor (Base URL + API key + \(model))...", level: .info, source: "CursorBridge", notify: true)
        runManager("--cursor-apply", extraArgs: ["--model", model]) { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                self.cursorApplyBusy = false
                if let obj = Self.parseJSONObject(output) {
                    let ok = obj["ok"] as? Bool ?? false
                    let msg = obj["message"] as? String ?? (ok ? "Applied" : "Apply failed")
                    self.cursorApplyMessage = msg
                    self.addLog(msg, level: ok ? .success : .error, source: "CursorBridge", notify: relaunchNotice)
                } else {
                    self.cursorApplyMessage = "Apply failed (no response)"
                    self.addLog("Apply to Cursor failed", level: .error, source: "CursorBridge", detail: output, notify: true)
                }
                self.refreshPathHealth()
            }
        }
    }

    func setBridgeAutoHeal(_ enabled: Bool) {
        let flag = enabled ? "on" : "off"
        bridgeStatus.autoHeal = enabled
        runManager("--bridge-set-autoheal", extraArgs: [flag]) { [weak self] output in
            Task { @MainActor in
                if let parsed = Self.parseBridgeStatus(output) {
                    self?.bridgeStatus = parsed
                }
                self?.addLog(
                    enabled ? "Auto-heal Funnel enabled" : "Auto-heal Funnel disabled",
                    level: .info,
                    source: "CursorBridge",
                    notify: true
                )
            }
        }
    }

    private func maybeRequestBridgeHeal() {
        let now = Date()
        if let last = lastBridgeHealAttempt, now.timeIntervalSince(last) < 20 {
            return
        }
        lastBridgeHealAttempt = now
        bridgeHealing = true
        runManager("--bridge-heal-now") { [weak self] output in
            Task { @MainActor in
                self?.bridgeHealing = false
                if let parsed = Self.parseBridgeStatus(output) {
                    self?.bridgeStatus = parsed
                    if parsed.isReady {
                        self?.addLog("Auto-heal restored Funnel: \(parsed.baseUrl)", level: .success, source: "CursorBridge", notify: true)
                    }
                }
            }
        }
    }

    func enableCursorBridge() {
        guard !bridgeBusy else { return }
        bridgeBusy = true
        addLog("Enabling Cursor Bridge (Tailscale Funnel → 9Router :20128)...", level: .info, source: "CursorBridge", notify: true)
        runManager("--bridge-start") { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                self.runManager("--bridge-status") { statusRaw in
                    Task { @MainActor in
                        self.bridgeBusy = false
                        if let parsed = Self.parseBridgeStatus(statusRaw) {
                            self.bridgeStatus = parsed
                            self.previousBridgeReady = parsed.isReady
                        }
                        self.loadNineRouterCredentials()
                        if self.bridgeStatus.isReady {
                            self.addLog("Cursor Bridge ready: \(self.bridgeStatus.baseUrl)", level: .success, source: "CursorBridge", notify: true)
                            self.applyCursorConfig()
                        } else {
                            let msg = self.bridgeStatus.message.isEmpty ? output : self.bridgeStatus.message
                            self.addLog("Cursor Bridge not ready yet", level: .warning, source: "CursorBridge", detail: msg, notify: true)
                        }
                    }
                }
            }
        }
    }

    /// Giống Environment Auto Install: cài Tailscale → mở login → chờ Running → bật Funnel.
    func runBridgeAutoSetup() {
        guard !bridgeSetupRunning && !bridgeBusy else { return }
        bridgeSetupRunning = true
        bridgeBusy = true
        lastAction = "Auto-setup Cursor Bridge..."
        addLog("Starting Cursor Bridge auto setup (install Tailscale → login → Funnel)...", level: .info, source: "CursorBridge", notify: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [managerPath(), "--bridge-setup"]
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
                                            (line.contains("✅") || line.contains("Success") || line.contains("READY") || line.contains("hoàn tất") ? .success : .info))
                        self?.addLog(line, level: lvl, source: "CursorBridge")
                    }
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try p.run()
                p.waitUntilExit()
                handle.readabilityHandler = nil
                Task { @MainActor in
                    self.bridgeSetupRunning = false
                    self.bridgeBusy = false
                    self.checkEnvironment()
                    self.refreshCursorBridge()
                    if p.terminationStatus == 0 {
                        self.addLog("Cursor Bridge auto setup completed", level: .success, source: "CursorBridge", notify: true)
                    } else {
                        // Incomplete is expected when waiting for password / login / Admin — not a hard crash.
                        self.addLog(
                            "Cần thêm 1 bước trên macOS",
                            level: .warning,
                            source: "CursorBridge",
                            detail: self.bridgeStatus.message.isEmpty
                                ? "Nhập mật khẩu Installer / Log in Tailscale / bật Funnel trong Admin, rồi bấm Continue Setup."
                                : self.bridgeStatus.message,
                            notify: true
                        )
                    }
                }
            } catch {
                handle.readabilityHandler = nil
                Task { @MainActor in
                    self.bridgeSetupRunning = false
                    self.bridgeBusy = false
                    self.addLog("Auto setup failed: \(error.localizedDescription)", level: .error, source: "CursorBridge", notify: true)
                }
            }
        }
    }

    func disableCursorBridge() {
        guard !bridgeBusy else { return }
        bridgeBusy = true
        addLog("Disabling Cursor Bridge Funnel...", level: .warning, source: "CursorBridge", notify: true)
        runManager("--bridge-stop") { [weak self] _ in
            Task { @MainActor in
                self?.bridgeBusy = false
                self?.previousBridgeReady = false
                self?.refreshCursorBridge()
                self?.addLog("Cursor Bridge stopped (auto-heal will not restore until Enable)", level: .info, source: "CursorBridge", notify: true)
            }
        }
    }

    private func loadNineRouterCredentials() {
        DispatchQueue.global(qos: .utility).async {
            let db = ("~/.9router/db/data.sqlite" as NSString).expandingTildeInPath
            let key = self.execShell("sqlite3 \"\(db)\" \"SELECT key FROM apiKeys WHERE isActive=1 ORDER BY createdAt ASC LIMIT 1;\" 2>/dev/null")
            let combos = self.execShell("sqlite3 \"\(db)\" \"SELECT name FROM combos ORDER BY updatedAt DESC;\" 2>/dev/null")
            var models = combos
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // Also pull a few live model ids when router is up
            let live = self.execShell("curl -fsS --max-time 2 http://127.0.0.1:20128/v1/models 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(\"\\n\".join([m.get(\"id\",\"\") for m in d.get(\"data\",[])[:30]]))' 2>/dev/null")
            for id in live.components(separatedBy: .newlines) {
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !models.contains(trimmed) {
                    models.append(trimmed)
                }
            }
            if models.isEmpty { models = ["my-combo"] }

            Task { @MainActor in
                if !key.isEmpty { self.nineRouterApiKey = key }
                self.availableModels = models
                if !models.contains(self.selectedBridgeModel) {
                    self.selectedBridgeModel = models.contains("my-combo") ? "my-combo" : (models.first ?? "my-combo")
                }
            }
        }
    }

    private static func parseBridgeStatus(_ raw: String) -> CursorBridgeStatus? {
        guard let obj = parseJSONObject(raw) else { return nil }
        return CursorBridgeStatus(
            installed: obj["installed"] as? Bool ?? false,
            loggedIn: obj["loggedIn"] as? Bool ?? false,
            funnelEnabled: obj["funnelEnabled"] as? Bool ?? false,
            wanted: obj["wanted"] as? Bool ?? false,
            autoHeal: obj["autoHeal"] as? Bool ?? true,
            publicUrl: obj["publicUrl"] as? String ?? "",
            baseUrl: obj["baseUrl"] as? String ?? "",
            targetPort: obj["targetPort"] as? Int ?? 20128,
            message: obj["message"] as? String ?? "",
            lastHealAt: obj["lastHealAt"] as? String ?? "",
            updatedAt: obj["updatedAt"] as? String ?? ""
        )
    }

    private static func parseJSONObject(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else { return nil }
        let json = String(trimmed[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func parsePathHealth(_ raw: String) -> PathHealthStatus? {
        guard let obj = parseJSONObject(raw) else { return nil }
        var providers: [ProviderHealthItem] = []
        if let arr = obj["providers"] as? [[String: Any]] {
            providers = arr.map { item in
                ProviderHealthItem(
                    model: item["model"] as? String ?? "",
                    provider: item["provider"] as? String ?? "",
                    name: item["name"] as? String ?? "",
                    active: item["active"] as? Bool ?? false,
                    testStatus: item["testStatus"] as? String ?? "",
                    errorCode: item["errorCode"] as? Int,
                    lastError: item["lastError"] as? String ?? "",
                    usable: item["usable"] as? Bool ?? false
                )
            }
        }
        return PathHealthStatus(
            localRouter: obj["localRouter"] as? Bool ?? false,
            localApi: obj["localApi"] as? Bool ?? false,
            localDashboardMs: obj["localDashboardMs"] as? Int ?? 0,
            localApiMs: obj["localApiMs"] as? Int ?? 0,
            funnelCli: obj["funnelCli"] as? Bool ?? false,
            wanted: obj["wanted"] as? Bool ?? false,
            baseUrl: obj["baseUrl"] as? String ?? "",
            publicReachable: obj["publicReachable"] as? Bool ?? false,
            publicStatus: obj["publicStatus"] as? Int ?? 0,
            publicMs: obj["publicMs"] as? Int ?? 0,
            publicAuthenticated: obj["publicAuthenticated"] as? Bool ?? false,
            publicAuthStatus: obj["publicAuthStatus"] as? Int ?? 0,
            cursorConfigured: obj["cursorConfigured"] as? Bool ?? false,
            cursorMessage: obj["cursorMessage"] as? String ?? "",
            cursorBaseUrl: obj["cursorBaseUrl"] as? String ?? "",
            comboName: obj["comboName"] as? String ?? "my-combo",
            comboHealthy: obj["comboHealthy"] as? Bool ?? false,
            usableProviders: obj["usableProviders"] as? Int ?? 0,
            providerCount: obj["providerCount"] as? Int ?? 0,
            providers: providers,
            cursorPathOk: obj["cursorPathOk"] as? Bool ?? false,
            message: obj["message"] as? String ?? ""
        )
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
        logTimer?.invalidate()
        logTimer = nil
        backend?.terminate()
        backend = nil
        addLog("Quit: shutting down Funnel + 9Router + proxies...", level: .warning, source: "System")
        runManagerSync("--shutdown")
        NSApp.terminate(nil)
    }

    func prepareForQuit() {
        guard !quitting else {
            runManagerSync("--shutdown")
            return
        }
        quitting = true
        timer?.invalidate()
        timer = nil
        logTimer?.invalidate()
        logTimer = nil
        backend?.terminate()
        backend = nil
        runManagerSync("--shutdown")
    }

    func finishQuit() {
        // Belt-and-suspenders: ensure ports/Funnel are down even if terminate raced.
        runManagerSync("--shutdown")
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

    private func runManager(_ arg: String, extraArgs: [String] = [], completion: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [managerPath(), arg] + extraArgs
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

struct CursorBridgeStore {
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AI Stack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cursor-bridge.json")
    }()

    func loadSelectedModel(default defaultModel: String) -> String {
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let model = obj["selectedModel"] as? String,
              !model.isEmpty else { return defaultModel }
        return model
    }

    func saveSelectedModel(_ model: String) {
        let obj: [String: Any] = ["selectedModel": model]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? d.write(to: url, options: .atomic)
        }
    }
}

// MARK: - macOS System Settings UI Components

struct MenuBarLogoLabel: View {
    private static let pointSize: CGFloat = 18

    var body: some View {
        if let image = AppLogoImage.sizedImage(named: "NavIcon", points: Self.pointSize) {
            Image(nsImage: image)
                .renderingMode(.original)
        } else {
            Image(systemName: "house.fill")
        }
    }
}

struct AppLogoImage: View {
    enum Kind { case app, nav }
    var kind: Kind = .app
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image = Self.sizedImage(named: kind == .nav ? "NavIcon" : "AppIcon", points: size) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.original)
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
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    static func sizedImage(named name: String, points: CGFloat) -> NSImage? {
        guard let original = NSImage(named: name)
            ?? Bundle.main.url(forResource: name, withExtension: "png").flatMap({ NSImage(contentsOf: $0) })
        else { return nil }
        let image = original.copy() as? NSImage ?? original
        image.size = NSSize(width: points, height: points)
        image.isTemplate = false
        return image
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
                case .cursorBridge:
                    CursorBridgeView()
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

// MARK: - Tab: Cursor Bridge

struct CursorBridgeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsCard {
                    HStack(alignment: .center, spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill((state.bridgeStatus.isReady ? Color.green : Color.orange).opacity(0.15))
                                .frame(width: 50, height: 50)
                            Image(systemName: state.bridgeStatus.isReady ? "link.circle.fill" : "link.badge.plus")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(state.bridgeStatus.isReady ? Color.green : Color.orange)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(
                                    state.bridgeStatus.isReady
                                        ? "Cursor Bridge Ready"
                                        : (state.bridgeStatus.isRecovering || state.bridgeHealing
                                           ? "Auto-healing Funnel…"
                                           : "Cursor Bridge Setup")
                                )
                                    .font(.system(size: 16, weight: .bold))
                                Circle()
                                    .fill(
                                        state.bridgeStatus.isReady
                                            ? Color.green
                                            : (state.bridgeStatus.isRecovering ? Color.orange : Color.orange)
                                    )
                                    .frame(width: 8, height: 8)
                            }
                            Text(state.bridgeStatus.message)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            if state.bridgeStatus.isReady {
                                Button("Disable") { state.disableCursorBridge() }
                                    .buttonStyle(.bordered)
                                    .disabled(state.bridgeBusy || state.bridgeSetupRunning)
                            } else {
                                Button(state.bridgeSetupRunning ? "Setting up…" : setupButtonTitle) {
                                    state.runBridgeAutoSetup()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(state.bridgeBusy || state.bridgeSetupRunning || state.routerStatus != .ready)

                                if state.bridgeStatus.installed && state.bridgeStatus.loggedIn {
                                    Button("Enable Bridge") { state.enableCursorBridge() }
                                        .buttonStyle(.bordered)
                                        .disabled(state.bridgeBusy || state.bridgeSetupRunning || state.routerStatus != .ready)
                                }
                            }
                            Button {
                                state.refreshCursorBridge()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(state.bridgeBusy || state.bridgeSetupRunning)
                        }
                    }
                    .padding(16)
                }

                SettingsCard(header: "Prerequisites") {
                    VStack(spacing: 0) {
                        bridgeCheckRow(
                            title: "9Router Gateway",
                            ok: state.routerStatus == .ready,
                            detail: state.routerStatus == .ready ? "Port 20128 online" : "Start services from Overview"
                        )
                        Divider().padding(.leading, 46)
                        bridgeCheckRow(
                            title: "Tailscale installed",
                            ok: state.bridgeStatus.installed,
                            detail: state.bridgeStatus.installed ? "CLI detected" : "Free app required for fixed HTTPS domain"
                        )
                        Divider().padding(.leading, 46)
                        bridgeCheckRow(
                            title: "Tailscale logged in",
                            ok: state.bridgeStatus.loggedIn,
                            detail: state.bridgeStatus.loggedIn ? "Backend Running" : "Open Tailscale and sign in once"
                        )
                        Divider().padding(.leading, 46)
                        bridgeCheckRow(
                            title: "Funnel CLI",
                            ok: state.bridgeStatus.funnelEnabled,
                            detail: state.bridgeStatus.funnelEnabled
                                ? "Stable *.ts.net URL"
                                : (state.bridgeStatus.isRecovering ? "Recovering via auto-heal…" : "Press Enable Bridge after login")
                        )
                        Divider().padding(.leading, 46)
                        bridgeCheckRow(
                            title: "Public HTTPS probe",
                            ok: state.pathHealth.publicReachable,
                            detail: state.pathHealth.publicReachable
                                ? "HTTP \(state.pathHealth.publicStatus) in \(state.pathHealth.publicMs) ms"
                                : (state.bridgeStatus.wanted ? "Cursor cloud không tới được Funnel" : "Bật Bridge để kiểm tra")
                        )
                        Divider().padding(.leading, 46)
                        bridgeCheckRow(
                            title: "Cursor configured",
                            ok: state.pathHealth.cursorConfigured,
                            detail: state.pathHealth.cursorMessage.isEmpty
                                ? "Base URL + key + model"
                                : state.pathHealth.cursorMessage
                        )
                        Divider().padding(.leading, 46)
                        bridgeCheckRow(
                            title: "Combo providers",
                            ok: !state.bridgeStatus.wanted || state.pathHealth.comboHealthy || state.pathHealth.providerCount == 0,
                            detail: state.pathHealth.providerCount == 0
                                ? "Chưa đọc được combo"
                                : "\(state.pathHealth.usableProviders)/\(state.pathHealth.providerCount) usable • \(state.pathHealth.comboName)"
                        )
                    }
                }

                SettingsCard(header: "Auto-heal Funnel") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Tự bật lại Funnel khi bị mất",
                            isOn: Binding(
                                get: { state.bridgeStatus.autoHeal },
                                set: { state.setBridgeAutoHeal($0) }
                            )
                        )
                        .toggleStyle(.switch)

                        Text("Khi bạn đã Enable Bridge, AI-Gate nhớ intent đó. Nếu Tailscale reconnect / Funnel drop / mở lại app, auto-heal sẽ restore Funnel (mỗi ~15s). Disable Bridge = tắt hẳn, không tự bật lại.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            StatusPill(
                                text: state.bridgeStatus.wanted ? "Wanted: ON" : "Wanted: OFF",
                                color: state.bridgeStatus.wanted ? .green : .orange
                            )
                            StatusPill(
                                text: state.bridgeStatus.autoHeal ? "Auto-heal: ON" : "Auto-heal: OFF",
                                color: state.bridgeStatus.autoHeal ? .green : .orange
                            )
                            if state.bridgeHealing || state.bridgeStatus.isRecovering {
                                StatusPill(text: "Healing…", color: .orange)
                            }
                            Spacer()
                        }

                        if !state.bridgeStatus.lastHealAt.isEmpty {
                            Text("Last heal: \(state.bridgeStatus.lastHealAt)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        }
                    }
                    .padding(14)
                }

                if !state.bridgeStatus.installed || !state.bridgeStatus.loggedIn || !state.bridgeStatus.funnelEnabled {
                    SettingsCard(header: "Guided setup") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Một nút Setup — AI Gate tự mở hộp thoại mật khẩu / Installer. Bạn chỉ cần xác nhận trên macOS (mật khẩu, Log in, Allow VPN). Không cần mở Terminal.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 6) {
                                setupHintRow(done: state.bridgeStatus.installed, text: "Cài Tailscale (hộp thoại mật khẩu hoặc Installer)")
                                setupHintRow(done: state.bridgeStatus.loggedIn, text: "Log in Tailscale + Allow VPN")
                                setupHintRow(done: state.bridgeStatus.funnelEnabled, text: "Bật Funnel (HTTPS công khai)")
                            }

                            HStack(spacing: 8) {
                                Button(state.bridgeSetupRunning ? "Setting up…" : setupButtonTitle) {
                                    state.runBridgeAutoSetup()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                                .disabled(state.bridgeBusy || state.bridgeSetupRunning || state.routerStatus != .ready)

                                if state.bridgeStatus.installed {
                                    Button("Open Tailscale") { state.openTailscaleApp() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)
                                }

                                if state.bridgeStatus.loggedIn && !state.bridgeStatus.funnelEnabled {
                                    Button("Open Admin") { state.openTailscaleAdminFunnel() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)
                                }
                            }

                            Text("Nếu lần đầu Funnel lỗi: trang Admin sẽ tự mở — bật HTTPS Certificates + Funnel, rồi bấm Continue Setup.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                    }
                }

                SettingsCard(header: "Apply to Cursor") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(state.pathHealth.cursorConfigured
                              ? "Cursor đã khớp Base URL + model. Bấm Apply lại nếu Funnel URL đổi."
                              : "Một nút — AI Gate ghi Base URL, API key 9Router và model vào Cursor (quit/reopen Cursor tự động).")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .fixedSize(horizontal: false, vertical: true)

                        if !state.cursorApplyMessage.isEmpty {
                            Text(state.cursorApplyMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(state.pathHealth.cursorConfigured ? Color.green : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        bridgeCopyRow(
                            title: "Base URL",
                            value: state.bridgeStatus.baseUrl.isEmpty ? "Enable Bridge để lấy https://….ts.net/v1" : state.bridgeStatus.baseUrl,
                            canCopy: !state.bridgeStatus.baseUrl.isEmpty
                        ) {
                            state.copy(state.bridgeStatus.baseUrl, notice: "Copied Base URL")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Model")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            HStack(spacing: 8) {
                                Picker("", selection: Binding(
                                    get: { state.selectedBridgeModel },
                                    set: { state.setBridgeModel($0) }
                                )) {
                                    ForEach(state.availableModels.isEmpty ? ["my-combo"] : state.availableModels, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 360)
                            }
                        }

                        HStack(spacing: 8) {
                            Button(state.cursorApplyBusy ? "Applying…" : "Apply to Cursor") {
                                state.applyCursorConfig()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .disabled(!state.bridgeStatus.isReady || state.cursorApplyBusy || state.nineRouterApiKey.isEmpty)

                            Button("Test Cursor path") { state.refreshPathHealth() }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)

                            Button("Copy setup text") { state.copyCursorSetup() }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(!state.bridgeStatus.isReady)

                            Button("Open 9Router") { state.openDashboard() }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(state.routerStatus != .ready)
                        }

                        Text("Codex dùng localhost — không cần Apply. Cursor bắt buộc qua Funnel public.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.orange)
                    }
                    .padding(14)
                }

                if !state.pathHealth.providers.isEmpty {
                    SettingsCard(header: "Combo providers (\(state.pathHealth.comboName))") {
                        VStack(spacing: 0) {
                            ForEach(Array(state.pathHealth.providers.enumerated()), id: \.element.id) { idx, item in
                                HStack(spacing: 12) {
                                    Image(systemName: item.usable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(item.usable ? Color.green : Color.orange)
                                        .font(.system(size: 14))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.model)
                                            .font(.system(size: 12, weight: .semibold))
                                        Text(item.lastError.isEmpty
                                              ? "\(item.provider) • \(item.testStatus)"
                                              : item.lastError)
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    StatusPill(
                                        text: item.usable ? "OK" : (item.errorCode.map { "\($0)" } ?? "Down"),
                                        color: item.usable ? .green : .orange
                                    )
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                if idx < state.pathHealth.providers.count - 1 {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                    }
                }

            }
            .padding(22)
        }
        .onAppear { state.refreshCursorBridge() }
    }

    private var setupButtonTitle: String {
        if !state.bridgeStatus.installed { return "Setup Tailscale" }
        if !state.bridgeStatus.loggedIn { return "Continue Setup" }
        if !state.bridgeStatus.funnelEnabled { return "Continue Setup" }
        return "Setup"
    }

    private func setupHintRow(done: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color(nsColor: .tertiaryLabelColor))
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(done ? Color(nsColor: .secondaryLabelColor) : Color.primary)
        }
    }

    private func bridgeCheckRow(title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color(nsColor: .tertiaryLabelColor))
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            Spacer()
            StatusPill(text: ok ? "OK" : "Need", color: ok ? .green : .orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func bridgeCopyRow(title: String, value: String, canCopy: Bool, onCopy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Button("Copy", action: onCopy)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canCopy)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color(red: 0.18, green: 0.72, blue: 0.55)))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .labelColor))
        }
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
                                Text(state.statusHeadline)
                                    .font(.system(size: 16, weight: .bold))
                                Circle()
                                    .fill(state.overallReady ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                            }
                            Text(state.statusDetailLine)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button {
                                state.selectedSection = .cursorBridge
                            } label: {
                                Label("Cursor Bridge", systemImage: "link.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

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
                                .help("Stop all related services (Funnel, 9Router, proxies — no auto-restore)")
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

                // Cursor Bridge quick status + path health
                SettingsCard(header: "Cursor Bridge") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            SquircleIcon(
                                symbol: "link.circle.fill",
                                color: state.pathHealth.cursorPathOk ? .green : Color(red: 0.18, green: 0.72, blue: 0.55),
                                size: 34,
                                inner: 16,
                                radius: 8
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    state.pathHealth.cursorPathOk
                                        ? "Cursor path ready"
                                        : (state.bridgeStatus.isRecovering
                                           ? "Auto-healing Funnel…"
                                           : state.pathHealth.message)
                                )
                                    .font(.system(size: 13, weight: .bold))
                                Text(state.bridgeStatus.baseUrl.isEmpty ? state.bridgeStatus.message : state.bridgeStatus.baseUrl)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                    .lineLimit(2)
                            }
                            Spacer()
                            StatusPill(
                                text: state.pathHealth.cursorPathOk
                                    ? "Ready"
                                    : (state.bridgeStatus.isRecovering ? "Healing" : "Check"),
                                color: state.pathHealth.cursorPathOk ? .green : .orange
                            )
                        }

                        HStack(spacing: 8) {
                            pathChip("Local", state.pathHealth.localRouter)
                            pathChip("Funnel", state.pathHealth.publicReachable || (!state.bridgeStatus.wanted && state.bridgeStatus.funnelEnabled))
                            pathChip("Cursor cfg", state.pathHealth.cursorConfigured)
                            pathChip("Combo", !state.bridgeStatus.wanted || state.pathHealth.comboHealthy || state.pathHealth.providerCount == 0)
                            Spacer()
                            Button("Test") { state.refreshPathHealth() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button(state.bridgeStatus.isReady ? "Apply" : "Open") {
                                if state.bridgeStatus.isReady {
                                    state.applyCursorConfig()
                                } else {
                                    state.selectedSection = .cursorBridge
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(state.cursorApplyBusy)
                        }
                    }
                    .padding(14)
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

    private func pathChip(_ title: String, _ ok: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                Text("Local tools (same Mac)")
                    .font(.system(size: 12, weight: .semibold))
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

                Divider()

                Text("Cursor IDE")
                    .font(.system(size: 12, weight: .semibold))
                Text("Cursor không gọi được localhost. Dùng tab Cursor Bridge (Tailscale Funnel) để lấy Base URL https://….ts.net/v1 + API key 9Router.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Cursor Bridge") {
                    dismiss()
                    state.selectedSection = .cursorBridge
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 340)
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
                    Text(state.statusHeadline)
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

                    Button {
                        openMainWindow()
                        state.selectedSection = .cursorBridge
                    } label: {
                        HStack(spacing: 10) {
                            SquircleIcon(symbol: "link.circle.fill", color: Color(red: 0.18, green: 0.72, blue: 0.55), size: 24, inner: 12, radius: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Cursor Bridge")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.primary)
                                Text(state.bridgeStatus.isReady ? "Ready" : "Setup")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            }
                            Spacer()
                            StatusPill(
                                text: state.bridgeStatus.isReady ? "On" : "Off",
                                color: state.bridgeStatus.isReady ? .green : .orange
                            )
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

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
