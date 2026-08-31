import SwiftUI
import AppKit
import Foundation
import Security
import CryptoKit
import UniformTypeIdentifiers
import Combine

@main
struct AIStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup("AI Gate", id: "main") {
            MainWindow()
                .environmentObject(state)
                .environmentObject(state.usage)
                .environmentObject(state.logsState)
                .environmentObject(state.topology)
                .background(MainWindowBootstrap())
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit AI Gate") { state.quit() }
                    .keyboardShortcut("q")
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(state.usage)
                .environmentObject(state.topology)
        } label: {
            MenuBarLogoLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Đưa cửa sổ chính lên full vùng màn hình làm việc khi mở app.
private struct MainWindowBootstrap: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard !context.coordinator.didConfigure, let window = view.window else { return }
            context.coordinator.didConfigure = true
            AppWindow.present(window, fillScreen: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard !context.coordinator.didConfigure, let window = nsView.window else { return }
            context.coordinator.didConfigure = true
            AppWindow.present(window, fillScreen: true)
        }
    }

    final class Coordinator {
        var didConfigure = false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppState.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            AppWindow.present(fillScreen: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppWindow.present(fillScreen: true)
        return false
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

    /// Bỏ timestamp poll — tránh redraw mỗi 5s dù trạng thái không đổi.
    func stableEquals(_ other: CursorBridgeStatus) -> Bool {
        var a = self
        var b = other
        a.updatedAt = ""
        b.updatedAt = ""
        return a == b
    }
}

struct ProviderHealthItem: Equatable, Identifiable {
    var id: String { model.isEmpty ? provider : "\(provider)|\(model)" }
    var model: String = ""
    var provider: String = ""
    var name: String = ""
    /// Tên hiển thị từ providerNodes / alias — không hardcode catalog.
    var displayName: String = ""
    var active: Bool = false
    var testStatus: String = ""
    var errorCode: Int? = nil
    var lastError: String = ""
    var usable: Bool = false
    var latencyMs: Int? = nil
    var live: Bool = false
    /// Node free/noAuth (mimo-free, opencode…) — không có trong /api/providers connections.
    var sourceIsFreeNoAuth: Bool = false
    /// id connection 9Router — dùng live probe `/api/providers/{id}/test`.
    var connectionId: String = ""
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
    var cursorAppliedModel: String = ""
    var codexAppliedModel: String = ""
    var comboName: String = "my-combo"
    var comboHealthy: Bool = false
    var usableProviders: Int = 0
    var providerCount: Int = 0
    var providers: [ProviderHealthItem] = []
    /// Topology trang Usage 9Router (providers API + noAuth) — không phải list model combo.
    var topologyProviders: [ProviderHealthItem] = []
    var topologyActive: Int = 0
    var topologyCount: Int = 0
    var cursorPathOk: Bool = false
    var cursorStalePublic: Bool = false
    var expectedCursorBaseUrl: String = ""
    var cursorShimRunning: Bool = false
    var message: String = "Đang kiểm tra đường kết nối..."

    var localOk: Bool { localRouter }

    /// So sánh bỏ ms / latency / lastError nhiễu — chỉ render khi trạng thái thật sự đổi.
    func stableEquals(_ other: PathHealthStatus) -> Bool {
        func scrubItem(_ item: ProviderHealthItem) -> ProviderHealthItem {
            var p = item
            p.latencyMs = nil
            p.lastError = ""
            return p
        }
        func scrub(_ raw: PathHealthStatus) -> PathHealthStatus {
            var p = raw
            p.localDashboardMs = 0
            p.localApiMs = 0
            p.publicMs = 0
            p.providers = p.providers.map(scrubItem)
            p.topologyProviders = p.topologyProviders.map(scrubItem)
            return p
        }
        return scrub(self) == scrub(other)
    }
}

struct UsageStats: Equatable, Sendable {
    var requests: Int = 0
    var promptTokens: Int = 0
    var cachedTokens: Int = 0
    var completionTokens: Int = 0
    var cost: Double = 0
}

/// Kỳ thống kê Usage — khớp filter 9Router (`/api/usage/stats?period=`).
enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "today"
    case h24 = "24h"
    case d7 = "7d"
    case d30 = "30d"
    case d60 = "60d"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: return "Today"
        case .h24: return "24h"
        case .d7: return "7D"
        case .d30: return "30D"
        case .d60: return "60D"
        }
    }
}

struct UsageRequestItem: Equatable, Identifiable, Sendable {
    var id: Int
    var timestamp: String = ""
    var provider: String = ""
    var model: String = ""
    var connectionId: String = ""
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var status: String = ""
}

/// Dashboard JWT cho `/api/usage/*` (cookie `auth_token`) — cùng secret 9Router dùng locally.
enum NineRouterDashboardAuth {
    static var jwtSecretPath: String {
        ("~/.9router/jwt-secret" as NSString).expandingTildeInPath
    }

    static func mintAuthToken(ttlSeconds: Int = 86_400) -> String? {
        let path = jwtSecretPath
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let header = #"{"alg":"HS256"}"#
        let payload = #"{"authenticated":true,"iat":\#(now),"exp":\#(now + ttlSeconds)}"#
        let signingInput = "\(base64URL(Data(header.utf8))).\(base64URL(Data(payload.utf8)))"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        return "\(signingInput).\(base64URL(Data(mac)))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Snapshot SSE đã parse ngoài MainActor (giống patch field của 9Router web).
struct UsageSSESnapshot: Equatable, Sendable {
    var stats: UsageStats?
    var recent: [UsageRequestItem]
    var activeProviders: Set<String>
    var activeModels: Set<String>
    var lastProvider: String
    var errorProvider: String
}

enum NineRouterUsageSSEParse {
    static func parse(_ jsonText: String) -> UsageSSESnapshot? {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var stats: UsageStats?
        if obj["totalRequests"] != nil || obj["totalPromptTokens"] != nil {
            var s = UsageStats()
            s.requests = jsonInt(obj["totalRequests"])
            s.promptTokens = jsonInt(obj["totalPromptTokens"])
            s.cachedTokens = jsonInt(obj["totalCachedTokens"])
            s.completionTokens = jsonInt(obj["totalCompletionTokens"])
            if let c = obj["totalCost"] as? Double {
                s.cost = c
            } else if let n = obj["totalCost"] as? NSNumber {
                s.cost = n.doubleValue
            }
            stats = s
        }

        var activeProviders = Set<String>()
        var activeModels = Set<String>()
        if let active = obj["activeRequests"] as? [[String: Any]] {
            for row in active {
                let p = (row["provider"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !p.isEmpty { activeProviders.insert(p) }
                let m = (row["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !m.isEmpty {
                    activeModels.insert(m)
                    if let slash = m.lastIndex(of: "/") {
                        let tail = String(m[m.index(after: slash)...])
                        if !tail.isEmpty { activeModels.insert(tail) }
                    }
                }
            }
        }

        var recent: [UsageRequestItem] = []
        if let rows = obj["recentRequests"] as? [[String: Any]] {
            recent.reserveCapacity(min(rows.count, 20))
            for (idx, row) in rows.prefix(20).enumerated() {
                let ts = row["timestamp"] as? String ?? ""
                let provider = row["provider"] as? String ?? ""
                let model = row["model"] as? String ?? ""
                let prompt = jsonInt(row["promptTokens"])
                let completion = jsonInt(row["completionTokens"])
                let status = row["status"] as? String ?? "ok"
                // Giữ cả request lỗi 0-token — trước đây bỏ → mất realtime status khi fail.
                if provider.isEmpty && model.isEmpty { continue }
                recent.append(
                    UsageRequestItem(
                        id: usageRowId(prefix: "r\(idx)", timestamp: ts, provider: provider, model: model, prompt: prompt, completion: completion),
                        timestamp: ts,
                        provider: provider,
                        model: model,
                        connectionId: "",
                        promptTokens: prompt,
                        completionTokens: completion,
                        status: status
                    )
                )
            }
        }

        let lastProvider = (recent.first?.provider ?? "").lowercased()
        let errorProvider = (obj["errorProvider"] as? String ?? "").lowercased()

        return UsageSSESnapshot(
            stats: stats,
            recent: recent,
            activeProviders: activeProviders,
            activeModels: activeModels,
            lastProvider: lastProvider,
            errorProvider: errorProvider
        )
    }

    private static func jsonInt(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let i = Int(s) { return i }
        return 0
    }

    private static func usageRowId(prefix: String, timestamp: String, provider: String, model: String, prompt: Int, completion: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(prefix)
        hasher.combine(timestamp)
        hasher.combine(provider)
        hasher.combine(model)
        hasher.combine(prompt)
        hasher.combine(completion)
        return hasher.finalize()
    }
}

enum NineRouterTopologySync {
    /// Active connections từ `/api/providers` (+ tên từ provider-nodes). Không filter catalog.
    static func fetch(authToken: String) -> [ProviderHealthItem]? {
        func getJSON(_ url: String) -> [String: Any]? {
            guard let u = URL(string: url) else { return nil }
            var req = URLRequest(url: u, timeoutInterval: 4)
            req.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
            req.setValue("AI-Gate-Topology/1.0", forHTTPHeaderField: "User-Agent")
            let sem = DispatchSemaphore(value: 0)
            var result: [String: Any]?
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { sem.signal() }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                result = obj
            }.resume()
            _ = sem.wait(timeout: .now() + 5)
            return result
        }
        guard let prov = getJSON("http://127.0.0.1:20128/api/providers") else { return nil }
        let nodesObj = getJSON("http://127.0.0.1:20128/api/provider-nodes")
        var nodeNames: [String: String] = [:]
        if let nodes = nodesObj?["nodes"] as? [[String: Any]] {
            for n in nodes {
                let id = n["id"] as? String ?? ""
                let name = (n["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty, !name.isEmpty { nodeNames[id] = name }
            }
        }
        let connections = prov["connections"] as? [[String: Any]] ?? []
        var best: [String: [String: Any]] = [:]
        for c in connections {
            if let active = c["isActive"] as? Bool, active == false { continue }
            if let n = c["isActive"] as? NSNumber, n.boolValue == false { continue }
            let pid = (c["provider"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pid.isEmpty else { continue }
            if let prev = best[pid] {
                if rank(c) > rank(prev) { best[pid] = c }
            } else {
                best[pid] = c
            }
        }
        var items: [ProviderHealthItem] = []
        for (pid, c) in best {
            let locked = lockedModel(from: c)
            let (status, usable, code, err) = health(c)
            let connName = c["name"] as? String ?? ""
            let display: String = {
                if let nn = nodeNames[pid], !nn.isEmpty { return nn }
                if !connName.isEmpty, !connName.contains("@"), !connName.contains("|") { return connName }
                return pid
            }()
            items.append(
                ProviderHealthItem(
                    model: locked.isEmpty ? pid : locked,
                    provider: pid,
                    name: connName,
                    displayName: display,
                    active: true,
                    testStatus: status,
                    errorCode: code,
                    lastError: err,
                    usable: usable,
                    latencyMs: nil,
                    live: false,
                    sourceIsFreeNoAuth: false,
                    connectionId: c["id"] as? String ?? ""
                )
            )
        }
        return items
    }

    private static func lockedModel(from c: [String: Any]) -> String {
        if let dm = c["defaultModel"] as? String, !dm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return dm.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var locks: [String] = []
        for (k, _) in c {
            guard k.hasPrefix("modelLock_") else { continue }
            let mid = String(k.dropFirst("modelLock_".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !mid.isEmpty { locks.append(mid) }
        }
        locks.sort { a, b in
            let aslash = a.contains("/") ? 0 : 1
            let bslash = b.contains("/") ? 0 : 1
            if aslash != bslash { return aslash < bslash }
            return a.count < b.count
        }
        return locks.first ?? ""
    }

    private static func health(_ c: [String: Any]) -> (String, Bool, Int?, String) {
        let raw = (c["testStatus"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let status = raw.isEmpty ? "active" : raw
        let code: Int? = {
            if let i = c["errorCode"] as? Int { return i }
            if let n = c["errorCode"] as? NSNumber { return n.intValue }
            if let s = c["errorCode"] as? String, let i = Int(s) { return i }
            return nil
        }()
        let rawErr = c["lastError"] as? String ?? ""
        let err: String = {
            if rawErr.isEmpty { return code.map { "[\($0)]" } ?? "" }
            if let start = rawErr.firstIndex(of: "{"),
               let data = String(rawErr[start...]).data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let e = obj["error"] as? [String: Any], let m = e["message"] as? String, !m.isEmpty {
                    return code.map { "[\($0)] \(m)" } ?? m
                }
                if let m = obj["message"] as? String, !m.isEmpty { return code.map { "[\($0)] \(m)" } ?? m }
                if let m = obj["detail"] as? String, !m.isEmpty { return code.map { "[\($0)] \(m)" } ?? m }
            }
            return code.map { "[\($0)] \(rawErr.prefix(120))" } ?? String(rawErr.prefix(120))
        }()
        let healthy = ["active", "ok", "ready"].contains(status)
        var usable = healthy
        if ["unavailable", "error", "failed", "inactive"].contains(status) { usable = false }
        else if let code, code >= 400 { usable = false }
        return (status, usable, code, usable && healthy ? "" : err)
    }

    private static func rank(_ c: [String: Any]) -> (Int, Int, Int) {
        let (_, usable, _, _) = health(c)
        let status = (c["testStatus"] as? String ?? "").lowercased()
        return (
            usable ? 1 : 0,
            ["active", "ok", "ready"].contains(status) ? 1 : 0,
            lockedModel(from: c).isEmpty ? 0 : 1
        )
    }
}

// MARK: - App State

enum AppWindow {
    private static var didFillScreenThisSession = false

    static func main() -> NSWindow? {
        NSApp.windows.first { window in
            guard window.canBecomeMain else { return false }
            let id = window.identifier?.rawValue ?? ""
            if id == "main" || id.hasPrefix("main-") { return true }
            return window.title == "AI Gate"
        }
    }

    static func present(_ window: NSWindow? = nil, fillScreen: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        guard let win = window ?? main() else { return }
        if win.isMiniaturized { win.deminiaturize(nil) }
        if fillScreen, !didFillScreenThisSession, let screen = win.screen ?? NSScreen.main {
            didFillScreenThisSession = true
            win.setFrame(screen.visibleFrame, display: true, animate: false)
        }
        win.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Focused observable stores (giảm redraw dây chuyền)

@MainActor
final class UsageStore: ObservableObject {
    @Published var usageStats = UsageStats()
    @Published var usagePeriod: UsagePeriod = .today
    @Published var recentUsage: [UsageRequestItem] = []
    @Published var activeUsageProviders: Set<String> = []
    @Published var activeUsageModels: Set<String> = []
    @Published var lastUsageProvider: String = ""
    @Published var errorUsageProvider: String = ""
}

@MainActor
final class LogsStore: ObservableObject {
    @Published var logs: [LogEntry] = [
        LogEntry(timestamp: Date().addingTimeInterval(-300), level: .info, source: "System", message: "AI Gate initialized and configuration loaded successfully", detail: nil),
        LogEntry(timestamp: Date().addingTimeInterval(-240), level: .info, source: "Environment", message: "Checked runtime dependencies: Darwin, Homebrew, Node v20, 9Router, Go, Git", detail: nil),
        LogEntry(timestamp: Date().addingTimeInterval(-180), level: .success, source: "9Router", message: "9Router Gateway is ready on port 20128", detail: "Dashboard: http://127.0.0.1:20128/dashboard"),
        LogEntry(timestamp: Date().addingTimeInterval(-120), level: .success, source: "AgentRouter", message: "AgentRouter Proxy connected on port 8318", detail: "Health URL: http://127.0.0.1:8318/health (1 ms)"),
        LogEntry(timestamp: Date().addingTimeInterval(-60), level: .info, source: "AutoHeal", message: "All services are operating normally in background", detail: nil)
    ]
}

@MainActor
final class TopologyStore: ObservableObject {
    @Published var pathHealth = PathHealthStatus()
    @Published var healthProbeBusy = false
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Usage / SSE / stats — views nặng chỉ observe store này.
    let usage = UsageStore()
    /// Log entries — tab Logs observe trực tiếp.
    let logsState = LogsStore()
    /// Topology + path health — graph observe trực tiếp.
    let topology = TopologyStore()

    private var storeCancellables = Set<AnyCancellable>()

    private init() {
        forwardStoreChanges(usage)
        forwardStoreChanges(logsState)
        forwardStoreChanges(topology)
    }

    private func forwardStoreChanges(_ store: some ObservableObject) {
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &storeCancellables)
    }

    // Aliases — giữ API cũ cho code/view chưa chuyển sang sub-store.
    var usageStats: UsageStats {
        get { usage.usageStats }
        set { usage.usageStats = newValue }
    }
    var usagePeriod: UsagePeriod {
        get { usage.usagePeriod }
        set { usage.usagePeriod = newValue }
    }
    var recentUsage: [UsageRequestItem] {
        get { usage.recentUsage }
        set { usage.recentUsage = newValue }
    }
    var activeUsageProviders: Set<String> {
        get { usage.activeUsageProviders }
        set { usage.activeUsageProviders = newValue }
    }
    var activeUsageModels: Set<String> {
        get { usage.activeUsageModels }
        set { usage.activeUsageModels = newValue }
    }
    var lastUsageProvider: String {
        get { usage.lastUsageProvider }
        set { usage.lastUsageProvider = newValue }
    }
    var errorUsageProvider: String {
        get { usage.errorUsageProvider }
        set { usage.errorUsageProvider = newValue }
    }
    var logs: [LogEntry] {
        get { logsState.logs }
        set { logsState.logs = newValue }
    }
    var pathHealth: PathHealthStatus {
        get { topology.pathHealth }
        set { topology.pathHealth = newValue }
    }
    var healthProbeBusy: Bool {
        get { topology.healthProbeBusy }
        set { topology.healthProbeBusy = newValue }
    }

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
    @Published var bridgeBusy: Bool = false
    @Published var bridgeHealing: Bool = false
    @Published var bridgeSetupRunning: Bool = false
    @Published var cursorApplyBusy: Bool = false
    @Published var cursorApplyMessage: String = ""
    @Published var nineRouterApiKey: String = ""
    @Published var availableModels: [String] = []
    /// Combo đang xem trên Overview (theo dõi model con) — không auto-apply IDE.
    @Published var previewCombo: String = "my-combo"
    /// Combo đang áp dụng thực tế vào từng IDE (đọc từ Cursor / Codex).
    @Published var cursorAppliedCombo: String = ""
    @Published var codexAppliedCombo: String = ""
    @Published var codexApplyBusy: Bool = false
    @Published var codexApplyMessage: String = ""
    @Published var testingCodex: Bool = false
    @Published var codexLatencyMs: Int? = nil
    @Published var codexTestOk: Bool? = nil
    @Published var testingCursor: Bool = false
    @Published var cursorLatencyMs: Int? = nil
    @Published var cursorTestOk: Bool? = nil
    @Published var showCursorDetails: Bool = false
    @Published var backupBusy: Bool = false
    @Published var backupMessage: String = ""
    private var lastBridgeHealAttempt: Date? = nil
    private var previousBridgeReady: Bool? = nil
    /// Bridge status: poll Tailscale thưa; khi đang recover thì dày hơn.
    private var bridgeInFlight = false
    private var lastBridgeProbeAt: Date?
    private let silentBridgeMinInterval: TimeInterval = 20
    private let recoveringBridgeMinInterval: TimeInterval = 5
    private var lastCredentialsAt: Date?
    private let silentCredentialsMinInterval: TimeInterval = 30
    private var healthInFlight = false
    private var lastSilentHealthAt: Date?
    private let silentHealthMinInterval: TimeInterval = 18
    private var usageInFlight = false
    private var lastUsageAt: Date?
    /// Fallback khi SSE chết — không dùng làm realtime chính.
    private let silentUsageMinInterval: TimeInterval = 30.0
    private var usageTimer: Timer?
    private var usageNeedsRefresh: Bool = false
    private var usageSSETask: Task<Void, Never>?
    private var usageSSEConnected: Bool = false
    private var usageSSEGeneration: UInt64 = 0
    private var usagePeriodInFlight = false
    private var lastUsagePeriodAt: Date?
    /// Debounce fetch stats — không gọi REST trên hot path SSE.
    private var usagePeriodRefreshTask: Task<Void, Never>?
    private let usagePeriodMinInterval: TimeInterval = 10.0
    /// Debounce badge topology — không xếp hàng Task trên mỗi frame SSE.
    private var topologyTrafficTask: Task<Void, Never>?
    private var lastTopologyTrafficKey: String = ""
    /// Topology sync HTTP `/api/providers` — ~1s để tắt/thêm provider hiện ngay.
    private var topologyTimer: Timer?
    private var topologyInFlight = false
    private var lastTopologyAt: Date?
    private let topologyMinInterval: TimeInterval = 0.9
    private let topologyIntervalLive: TimeInterval = 1.0
    private let topologyIntervalIdle: TimeInterval = 2.5
    /// Heartbeat nhẹ cho menu bar / sidebar khi không ở tab Overview/Proxies.
    private var menuBarTimer: Timer?
    private let menuBarHeartbeatInterval: TimeInterval = 20.0
    private var lastRouterCheckAt: Date?
    private let routerCheckMinInterval: TimeInterval = 3.0

    /// Hiển thị tham khảo; copy vẫn dùng full key.
    var maskedNineRouterApiKey: String {
        let key = nineRouterApiKey
        guard key.count > 12 else {
            return key.isEmpty ? "" : String(repeating: "•", count: min(8, key.count))
        }
        return "\(key.prefix(8))…\(key.suffix(4))"
    }

    /// Combo dùng khi auto-apply Cursor (bridge bật) — ưu tiên combo đang apply của Cursor.
    var cursorComboForApply: String {
        if !cursorAppliedCombo.isEmpty { return cursorAppliedCombo }
        if !previewCombo.isEmpty { return previewCombo }
        return "my-combo"
    }

    private var backend: Process?
    /// Poll theo tab đang mở — không chạy poll nền cho tab khác.
    private var sectionTimer: Timer?
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
        let model = cursorComboForApply
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
        AppWindow.main()
    }

    /// Hiện cửa sổ chính; `fillScreen` = chiếm full vùng làm việc lần đầu trong session.
    static func presentMainWindow(_ window: NSWindow? = nil, fillScreen: Bool = false) {
        AppWindow.present(window, fillScreen: fillScreen)
    }

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case proxies = "Proxies"
        case backup = "Backup"
        case environment = "Environment"
        case logs = "Logs"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: return "square.grid.2x2.fill"
            case .proxies: return "antenna.radiowaves.left.and.right"
            case .backup: return "externaldrive.fill"
            case .environment: return "cube.fill"
            case .logs: return "doc.text.fill"
            }
        }
        var subtitle: String {
            switch self {
            case .overview: return "Status & services"
            case .proxies: return "Local endpoints"
            case .backup: return "Save & restore config"
            case .environment: return "Runtime setup"
            case .logs: return "Live output"
            }
        }
        var accentColor: Color {
            switch self {
            case .overview: return Color(red: 0.20, green: 0.52, blue: 0.98)
            case .proxies: return Color(red: 0.38, green: 0.34, blue: 0.93)
            case .backup: return Color(red: 0.22, green: 0.72, blue: 0.45)
            case .environment: return Color(red: 0.96, green: 0.57, blue: 0.13)
            case .logs: return Color(red: 0.55, green: 0.55, blue: 0.62)
            }
        }
    }

    func start() {
        guard !quitting else { return }
        loadProxies()
        previewCombo = bridgeStore.loadPreviewCombo(default: "my-combo")
        cursorAppliedCombo = bridgeStore.loadCursorCombo(default: "")
        codexAppliedCombo = bridgeStore.loadCodexCombo(default: "")
        launchBackendIfNeeded()
        startMenuBarHeartbeat()
        syncSectionPolling()
    }

    /// Ping router nhẹ — giữ menu bar/sidebar không quá cũ khi không ở Overview/Proxies.
    private func startMenuBarHeartbeat() {
        menuBarTimer?.invalidate()
        refreshRouterStatusOnly(force: true)
        menuBarTimer = Timer.scheduledTimer(withTimeInterval: menuBarHeartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.quitting else { return }
                if self.selectedSection == .overview || self.selectedSection == .proxies {
                    return
                }
                self.refreshRouterStatusOnly(force: false)
            }
        }
    }

    private func topologyHasLiveTraffic() -> Bool {
        !usage.activeUsageProviders.isEmpty
            || !usage.activeUsageModels.isEmpty
            || topology.pathHealth.topologyProviders.contains(where: \.live)
    }

    private func scheduleTopologyTimer() {
        topologyTimer?.invalidate()
        guard selectedSection == .overview, !quitting else { return }
        let interval = topologyHasLiveTraffic() ? topologyIntervalLive : topologyIntervalIdle
        topologyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selectedSection == .overview else { return }
                self.refreshTopologySilent()
                self.scheduleTopologyTimer()
            }
        }
    }

    /// Bật poll/fetch đúng tab hiện tại; tắt hết khi chuyển tab.
    func syncSectionPolling() {
        guard !quitting else { return }
        stopSectionPolling()
        switch selectedSection {
        case .overview:
            startOverviewPolling()
        case .proxies:
            startProxiesPolling()
        case .environment:
            startEnvironmentPolling()
        case .logs:
            startLogsPolling()
        case .backup:
            break
        }
    }

    private func stopSectionPolling() {
        sectionTimer?.invalidate()
        sectionTimer = nil
        topologyTimer?.invalidate()
        topologyTimer = nil
        usageTimer?.invalidate()
        usageTimer = nil
        logTimer?.invalidate()
        logTimer = nil
        stopUsageSSE()
    }

    private func startOverviewPolling() {
        refresh()
        refreshCursorBridge(force: true)
        refreshTopologySilent(force: true)
        refreshUsageSilent(force: true)
        refreshUsagePeriodStats(force: true)
        startUsageSSE()

        scheduleTopologyTimer()

        usageTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selectedSection == .overview else { return }
                if !self.usageSSEConnected {
                    self.refreshUsageSilent(force: false)
                }
                self.refreshUsagePeriodStats(force: false)
            }
        }

        sectionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selectedSection == .overview else { return }
                self.refresh()
                self.refreshCursorBridge()
            }
        }
    }

    private func startProxiesPolling() {
        refresh()
        sectionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selectedSection == .proxies else { return }
                self.refresh()
            }
        }
    }

    private func startEnvironmentPolling() {
        checkEnvironment(force: true)
        sectionTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selectedSection == .environment else { return }
                self.checkEnvironment(force: true)
            }
        }
    }

    private func startLogsPolling() {
        startLiveLogStreaming()
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
        guard selectedSection == .logs else { return }
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
                // Overview đang nhìn graph: bỏ qua log thường để khỏi redraw cà giật; vẫn giữ error.
                let mirrorUI = selectedSection == .logs
                for line in lines {
                    let lvl: LogLevel = line.contains("Error") || line.contains("error") || line.contains("FAILED") ? .error :
                                        (line.contains("Warn") || line.contains("warn") ? .warning :
                                        (line.contains("200") || line.contains("POST") || line.contains("GET") || line.contains("OK") ? .success : .info))
                    if mirrorUI || lvl == .error {
                        addLog(line, level: lvl, source: source)
                    }
                }
            }
        } else {
            try? file.close()
        }
    }


    func refresh() {
        refreshRouterStatusOnly(force: true)
        refreshProxyStatuses()
    }

    /// Chỉ check 9Router — dùng heartbeat menu bar + auto-heal nhẹ.
    func refreshRouterStatusOnly(force: Bool = false) {
        guard !quitting else { return }
        if !force,
           let last = lastRouterCheckAt,
           Date().timeIntervalSince(last) < routerCheckMinInterval {
            return
        }
        lastRouterCheckAt = Date()

        let prevRouter = routerStatus
        check("http://127.0.0.1:20128/dashboard") { [weak self] ok in
            Task { @MainActor in
                guard let self = self else { return }
                let newStatus: ServiceStatus = ok ? .ready : .down
                let changed = prevRouter != newStatus
                if changed {
                    if newStatus == .ready {
                        self.addLog("9Router Gateway is connected and operational", level: .success, source: "9Router")
                    } else if !self.isManuallyStopped {
                        self.addLog("9Router Gateway connection lost! Attempting auto-recovery...", level: .error, source: "AutoHeal", detail: "Port: 20128 • Dashboard unresponsive")
                        if self.autoHealing && !self.isBusy {
                            self.launchBackendIfNeeded()
                        }
                    }
                    self.routerStatus = newStatus
                    if newStatus == .ready {
                        if self.selectedSection == .overview {
                            self.startUsageSSE()
                            self.refreshTopologySilent(force: true)
                            self.refreshUsagePeriodStats(force: true)
                            self.scheduleTopologyTimer()
                        }
                    } else {
                        self.stopUsageSSE()
                    }
                } else if newStatus == .ready {
                    if self.selectedSection == .overview {
                        self.ensureUsageSSE()
                    }
                }
                self.updateRefreshState(didChange: changed)
            }
        }
    }

    /// Health check từng proxy — tab Proxies / Overview.
    func refreshProxyStatuses() {
        guard !quitting else { return }

        for i in proxies.indices {
            let p = proxies[i]
            let prevProxyStatus = p.status
            if p.enabled {
                check(p.healthUrl) { [weak self] ok in
                    Task { @MainActor in
                        guard let self = self, i < self.proxies.count else { return }
                        let newStatus: ServiceStatus = ok ? .ready : .down
                        let changed = prevProxyStatus != newStatus
                        if changed {
                            if newStatus == .ready {
                                self.addLog("\(p.name) reconnected successfully", level: .success, source: p.name)
                            } else if !self.isManuallyStopped {
                                self.addLog("Detected \(p.name) disconnected or error", level: .warning, source: "AutoHeal", detail: "URL: \(p.healthUrl)")
                                if self.autoHealing && !self.isBusy {
                                    self.launchBackendIfNeeded()
                                }
                            }
                            self.proxies[i].status = newStatus
                        }
                        self.updateRefreshState(didChange: changed)
                    }
                }
            } else if proxies[i].status != .down {
                proxies[i].status = .down
                updateRefreshState(didChange: true)
            }
        }
    }

    /// Chỉ đụng @Published khi có thay đổi thật — tránh cà giật UI mỗi poll.
    private func updateRefreshState(didChange: Bool = false) {
        let next: String
        if isManuallyStopped {
            next = "Services manually stopped (Auto-recovery paused)."
        } else if overallReady {
            next = "All services are running normally."
        } else {
            next = "Checking and recovering services..."
        }
        if lastAction != next {
            lastAction = next
        }
        if didChange {
            lastCheck = Date()
        }
    }

    private func publishBridgeStatus(_ status: CursorBridgeStatus) {
        guard !bridgeStatus.stableEquals(status) else { return }
        bridgeStatus = status
    }

    private func publishPathHealth(_ next: PathHealthStatus) {
        guard !pathHealth.stableEquals(next) else { return }
        pathHealth = next
    }

    private static func sortedTopology(_ items: [ProviderHealthItem]) -> [ProviderHealthItem] {
        items.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Fingerprint ổn định — bỏ lastError dài / latency để khỏi publish nhiễu.
    private static func topologyFingerprint(_ items: [ProviderHealthItem]) -> String {
        items.map { p in
            "\(p.provider)|\(p.displayName)|\(p.model)|\(p.testStatus)|\(p.usable)|\(p.errorCode.map(String.init) ?? "")|\(p.sourceIsFreeNoAuth)"
        }.joined(separator: ";")
    }

    // MARK: Environment Checks & Bootstrap

    func checkEnvironment(force: Bool = false) {
        if !force, selectedSection != .environment { return }
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

            // 7. Tailscale (optional for local/Codex; needed when dùng Cursor)
            // Stopped ≠ chưa setup: app có thể ngủ, auto-heal sẽ mở lại khi bật Cursor.
            let tsPath = self.execShell("""
            \(envPath)
            if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then echo "/Applications/Tailscale.app/Contents/MacOS/Tailscale"; \
            elif command -v tailscale >/dev/null 2>&1; then command -v tailscale; \
            else echo Missing; fi
            """)
            let tsOk = !tsPath.contains("Missing") && !tsPath.isEmpty
            var tsState = "Missing"
            var tsDNS = ""
            if tsOk {
                let raw = self.execShell("""
                "\(tsPath)" status --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("BackendState") or "unknown")+"|"+(((d.get("Self") or {}).get("DNSName") or "").rstrip(".")))' 2>/dev/null || echo 'unknown|'
                """)
                let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                tsState = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                tsDNS = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            let tsLoggedIn = !tsDNS.isEmpty || tsState == "Running"
            let tsRunning = tsState == "Running"
            // Ready once installed + đã login (kể cả đang Stopped/sleep).
            let tsReady = tsOk && tsLoggedIn && tsState != "NeedsLogin" && tsState != "NoState"
            let tsInstalledLabel: String = {
                if !tsOk { return "Not installed" }
                if tsRunning { return "Running" }
                if tsLoggedIn && tsState == "Stopped" { return "Installed (sleeping)" }
                if tsLoggedIn { return "Installed (\(tsState.isEmpty ? "unknown" : tsState))" }
                return "Installed (\(tsState.isEmpty ? "NeedsLogin" : tsState))"
            }()
            let tsStatusDesc: String = {
                if !tsOk { return "Install Tailscale (free) — chỉ cần khi dùng Cursor" }
                if tsRunning { return "Ready for Cursor Funnel" }
                if tsLoggedIn && tsState == "Stopped" { return "OK — sẽ tự mở khi bật Cursor" }
                if tsLoggedIn { return "Logged in (\(tsState))" }
                return "Open Tailscale and log in"
            }()
            items.append(EnvItem(
                name: "Tailscale",
                category: "Cursor Bridge Tunnel",
                required: "App + Login",
                installed: tsInstalledLabel,
                isReady: tsReady,
                iconName: "network",
                statusDescription: tsStatusDesc
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
                    self.checkEnvironment(force: true)
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

    /// Nút Topology: lấy lại trạng thái provider / path (không restart dịch vụ).
    func refreshStatusNow(live: Bool = false) {
        guard !quitting, !healthProbeBusy else { return }
        refresh()
        reloadNineRouterCombos()
        if live {
            // Live probe tự lấy + test topology — không poll đè kết quả.
            refreshPathHealth(live: true, notify: true)
        } else {
            refreshTopologySilent(force: true)
            refreshPathHealth(live: false, notify: true)
        }
        refreshCursorBridge(force: true)
        refreshUsageSilent(force: true)
        refreshUsagePeriodStats(force: true)
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
                    message: "Đã dừng toàn bộ — Start / bật Cursor ở Overview khi cần."
                )
                for i in self?.proxies.indices ?? 0..<0 {
                    self?.proxies[i].status = .down
                }
                self?.updateRefreshState(didChange: true)
                self?.addLog("All related services stopped (no auto-restore until Start/Enable)", level: .success, source: "System", notify: true)
                self?.refreshCursorBridge(force: true)
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

    /// Chỉ đổi combo đang xem (Overview) — không apply vào IDE.
    func setPreviewCombo(_ model: String) {
        previewCombo = model
        bridgeStore.savePreviewCombo(model)
        refreshPathHealth(force: true)
    }

    /// Áp dụng combo vào Cursor (Base URL + key + model).
    func applyComboToCursor(_ model: String, relaunchNotice: Bool = true) {
        let m = model.isEmpty ? "my-combo" : model
        cursorAppliedCombo = m
        bridgeStore.saveCursorCombo(m)
        applyCursorConfig(model: m, relaunchNotice: relaunchNotice)
    }

    /// Áp dụng combo vào Codex (~/.codex/config.toml).
    func applyComboToCodex(_ model: String) {
        guard !codexApplyBusy else { return }
        let m = model.isEmpty ? "my-combo" : model
        codexApplyBusy = true
        addLog("Áp dụng combo «\(m)» vào Codex…", level: .info, source: "Codex", notify: true)
        runManager("--codex-apply", extraArgs: ["--model", m]) { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                self.codexApplyBusy = false
                if let obj = Self.parseJSONObject(output) {
                    let ok = obj["ok"] as? Bool ?? false
                    let msg = obj["message"] as? String ?? (ok ? "Applied" : "Apply failed")
                    self.codexApplyMessage = msg
                    if ok {
                        let applied = obj["model"] as? String ?? m
                        self.codexAppliedCombo = applied
                        self.bridgeStore.saveCodexCombo(applied)
                    }
                    self.addLog(msg, level: ok ? .success : .error, source: "Codex", notify: true)
                } else {
                    self.codexApplyMessage = "Apply Codex failed"
                    self.addLog("Apply Codex failed", level: .error, source: "Codex", detail: output, notify: true)
                }
                self.refreshPathHealth(force: true)
            }
        }
    }

    // MARK: - Cursor Bridge

    /// - force: bỏ throttle + luôn chạy Tailscale probe (toggle / Làm mới / sau setup).
    func refreshCursorBridge(force: Bool = false) {
        guard !quitting else { return }
        if !force, selectedSection != .overview { return }
        loadNineRouterCredentials(force: force)

        let recovering = bridgeStatus.isRecovering
        let minInterval = recovering ? recoveringBridgeMinInterval : silentBridgeMinInterval
        if !force {
            if bridgeInFlight { return }
            if let last = lastBridgeProbeAt, Date().timeIntervalSince(last) < minInterval {
                // Vẫn cho path-health tự throttle — không spawn Tailscale thừa.
                refreshPathHealth()
                return
            }
        }

        bridgeInFlight = true
        runManager("--bridge-status") { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                self.bridgeInFlight = false
                self.lastBridgeProbeAt = Date()
                if let parsed = Self.parseBridgeStatus(output) {
                    self.applyBridgeStatus(parsed, fromLiveProbe: true)
                } else if let cached = Self.readBridgeStatusFile() {
                    // Probe lỗi — dùng status.json gần nhất nếu có.
                    self.applyBridgeStatus(cached, fromLiveProbe: false)
                }
                // Path health throttle riêng — không buộc chạy mỗi lần bridge-status (tránh giật UI).
                self.refreshPathHealth()
            }
        }
    }

    private func applyBridgeStatus(_ parsed: CursorBridgeStatus, fromLiveProbe: Bool) {
        let wasReady = previousBridgeReady
        var status = parsed
        // Khi Cursor service đang bật: luôn tự khôi phục — không cần toggle.
        if status.wanted && !status.autoHeal {
            status.autoHeal = true
            if fromLiveProbe {
                runManager("--bridge-set-autoheal", extraArgs: ["on"]) { _ in }
            }
        }
        publishBridgeStatus(status)
        previousBridgeReady = status.isReady

        if wasReady == true && !status.isReady && status.wanted {
            addLog("Cursor Bridge Funnel dropped — auto-heal will retry", level: .warning, source: "CursorBridge", detail: status.message)
        } else if wasReady == false && status.isReady && status.wanted {
            addLog("Cursor Bridge Funnel restored: \(status.baseUrl)", level: .success, source: "CursorBridge")
        }

        // App-side nudge if shell loop hasn't healed yet (e.g. right after wake).
        if status.isRecovering && !bridgeBusy && !isManuallyStopped {
            maybeRequestBridgeHeal()
        }
    }

    /// Đọc ~/ai-stack/cursor-bridge/status.json — nhẹ, không gọi Tailscale.
    private static func readBridgeStatusFile() -> CursorBridgeStatus? {
        let path = ("~/ai-stack/cursor-bridge/status.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return parseBridgeStatus(raw)
    }

    /// - live: probe chat thật (chỉ Làm mới)
    /// - notify: toast + spinner UI
    /// - force: bỏ throttle refresh ngầm (đổi combo / sau apply)
    func refreshPathHealth(live: Bool = false, notify: Bool = false, force: Bool = false) {
        guard !quitting else { return }
        let showUI = notify || live
        if showUI {
            guard !healthProbeBusy else { return }
            healthProbeBusy = true
        } else {
            // Ngầm: không chồng request; không đụng UI; throttle spawn python.
            guard !healthProbeBusy, !healthInFlight else { return }
            if !force, let last = lastSilentHealthAt,
               Date().timeIntervalSince(last) < silentHealthMinInterval {
                return
            }
            healthInFlight = true
        }
        let model = previewCombo.isEmpty ? "my-combo" : previewCombo
        if notify {
            addLog(
                live
                    ? "Đang probe live tất cả provider trên Topology…"
                    : "Đang làm mới trạng thái…",
                level: .info,
                source: "Topology",
                notify: true
            )
        }
        var args = ["--model", model]
        if live {
            args.append("--live")
        } else if !showUI {
            // Silent poll: bỏ topology registry scrape + public probe thừa.
            args.append("--silent")
        }
        runManager("--bridge-health", extraArgs: args) { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                if showUI {
                    self.healthProbeBusy = false
                } else {
                    self.healthInFlight = false
                    self.lastSilentHealthAt = Date()
                    // User đang Làm mới — bỏ kết quả cache ngầm tới muộn.
                    if self.healthProbeBusy {
                        self.refreshUsageSilent(force: false)
                        return
                    }
                }
                if let parsed = Self.parsePathHealth(output) {
                    var next = parsed
                    if live, !parsed.topologyProviders.isEmpty {
                        // Kết quả probe Topology — luôn nhận, không giữ list cũ.
                        next.topologyProviders = Self.sortedTopology(parsed.topologyProviders)
                        next.topologyCount = next.topologyProviders.count
                        next.topologyActive = next.topologyProviders.filter(\.usable).count
                        self.lastTopologyAt = Date()
                    } else if !self.pathHealth.topologyProviders.isEmpty {
                        // Silent health: Topology do refreshTopologySilent giữ.
                        next.topologyProviders = self.pathHealth.topologyProviders
                        next.topologyCount = self.pathHealth.topologyCount
                        next.topologyActive = self.pathHealth.topologyActive
                    } else if !parsed.topologyProviders.isEmpty {
                        next.topologyProviders = Self.sortedTopology(parsed.topologyProviders)
                        next.topologyCount = next.topologyProviders.count
                        next.topologyActive = next.topologyProviders.filter(\.usable).count
                    }
                    self.publishPathHealth(next)
                    if !parsed.cursorAppliedModel.isEmpty,
                       self.cursorAppliedCombo != parsed.cursorAppliedModel {
                        self.cursorAppliedCombo = parsed.cursorAppliedModel
                        self.bridgeStore.saveCursorCombo(parsed.cursorAppliedModel)
                    }
                    if !parsed.codexAppliedModel.isEmpty,
                       self.codexAppliedCombo != parsed.codexAppliedModel {
                        self.codexAppliedCombo = parsed.codexAppliedModel
                        self.bridgeStore.saveCodexCombo(parsed.codexAppliedModel)
                    }
                    if notify {
                        let ok = live ? next.topologyActive : parsed.usableProviders
                        let total = live ? next.topologyCount : parsed.providerCount
                        self.addLog(
                            live
                                ? "Probe Topology: \(ok)/\(total) provider OK"
                                : "Xong: \(ok)/\(total) model OK",
                            level: {
                                if total == 0 { return .warning }
                                if ok >= total { return .success }
                                if ok == 0 { return .error }
                                return .warning  // một phần lỗi — không ghi SUCCESS gây hiểu nhầm
                            }(),
                            source: "Topology",
                            notify: true
                        )
                    }
                } else if notify {
                    self.addLog("Làm mới trạng thái thất bại", level: .error, source: "Topology", detail: output, notify: true)
                }
                self.refreshUsageSilent(force: showUI)
            }
        }
    }

    /// Topology live — poll 1s qua HTTP (tắt/thêm connection hiện ngay).
    /// `force`: sync Python đầy đủ (kèm free/noAuth).
    func refreshTopologySilent(force: Bool = false) {
        guard !quitting, routerStatus == .ready else { return }
        if !force, selectedSection != .overview { return }
        if topologyInFlight { return }
        if !force, let last = lastTopologyAt, Date().timeIntervalSince(last) < topologyMinInterval {
            return
        }
        if force {
            refreshTopologyViaPython()
            return
        }
        guard let token = NineRouterDashboardAuth.mintAuthToken() else {
            refreshTopologyViaPython()
            return
        }
        topologyInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetchedRaw = NineRouterTopologySync.fetch(authToken: token) ?? []
            Task { @MainActor in
                guard let self else { return }
                self.topologyInFlight = false
                guard !self.quitting else { return }
                self.lastTopologyAt = Date()
                self.applyFetchedTopology(fetchedRaw)
            }
        }
    }

    /// Sync Python đầy đủ (connections + free/noAuth) — dùng lúc mở app / refresh tay.
    private func refreshTopologyViaPython() {
        if topologyInFlight { return }
        topologyInFlight = true
        runManager("--bridge-topology") { [weak self] output in
            Task { @MainActor in
                guard let self else { return }
                self.topologyInFlight = false
                guard !self.quitting else { return }
                self.lastTopologyAt = Date()
                guard let obj = Self.parseJSONObject(output),
                      let arr = obj["topologyProviders"] as? [[String: Any]] else { return }
                self.applyFetchedTopology(arr.map { Self.parseProviderItem($0) })
            }
        }
    }

    private func applyFetchedTopology(_ fetchedIn: [ProviderHealthItem]) {
        var fetched = Self.sortedTopology(fetchedIn)
        // Giữ free/noAuth từ lần sync Python trước (HTTP connections không có chúng).
        let freeKeep = pathHealth.topologyProviders.filter { item in
            item.sourceIsFreeNoAuth && !fetched.contains(where: { $0.provider == item.provider })
        }
        if !freeKeep.isEmpty {
            fetched = Self.sortedTopology(fetched + freeKeep)
        }

        let merged: [ProviderHealthItem]
        if pathHealth.topologyProviders.contains(where: \.live) {
            var byPid = Dictionary(
                uniqueKeysWithValues: pathHealth.topologyProviders.map { ($0.provider, $0) }
            )
            let liveIds = Set(pathHealth.topologyProviders.filter(\.live).map(\.provider))
            for item in fetched {
                if liveIds.contains(item.provider) {
                    if var old = byPid[item.provider] {
                        if old.displayName.isEmpty || old.displayName == old.provider {
                            if !item.displayName.isEmpty { old.displayName = item.displayName }
                        }
                        if old.model.isEmpty || old.model == old.provider, !item.model.isEmpty {
                            old.model = item.model
                        }
                        if old.connectionId.isEmpty, !item.connectionId.isEmpty {
                            old.connectionId = item.connectionId
                        }
                        byPid[item.provider] = old
                    }
                    continue
                }
                byPid[item.provider] = item
            }
            let apiIds = Set(fetched.map(\.provider))
            byPid = byPid.filter { pid, item in liveIds.contains(pid) || apiIds.contains(pid) || item.sourceIsFreeNoAuth }
            merged = Self.sortedTopology(Array(byPid.values))
        } else {
            merged = fetched
        }

        let active = merged.filter(\.usable).count
        let count = merged.count
        guard Self.topologyFingerprint(topology.pathHealth.topologyProviders)
            != Self.topologyFingerprint(merged)
            || topology.pathHealth.topologyCount != count
            || topology.pathHealth.topologyActive != active else { return }
        var ph = topology.pathHealth
        ph.topologyProviders = merged
        ph.topologyCount = count
        ph.topologyActive = active
        topology.pathHealth = ph
    }

    /// Fallback SQLite khi SSE chưa sẵn sàng. Realtime chính: `startUsageSSE()`.
    /// An toàn CPU: tối đa 1 job sqlite tại một thời điểm — không chồng force.
    func refreshUsageSilent(force: Bool = false) {
        guard !quitting else { return }
        if !force, selectedSection != .overview { return }
        if usageSSEConnected, !force { return }
        if usageInFlight {
            if force { usageNeedsRefresh = true }
            return
        }
        if !force, let last = lastUsageAt, Date().timeIntervalSince(last) < silentUsageMinInterval {
            return
        }
        usageInFlight = true
        usageNeedsRefresh = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let db = ("~/.9router/db/data.sqlite" as NSString).expandingTildeInPath
            // Một process sqlite3 — không spawn 2 lần / mỗi poll.
            let bundled = self.execShell(
                "sqlite3 -separator '|' \"\(db)\" \"SELECT 'H', id, timestamp, IFNULL(provider,''), IFNULL(model,''), IFNULL(connectionId,''), IFNULL(promptTokens,0), IFNULL(completionTokens,0), IFNULL(status,'') FROM usageHistory ORDER BY id DESC LIMIT 20;\" 2>/dev/null"
            )
            var recent: [UsageRequestItem] = []
            for line in bundled.components(separatedBy: .newlines) {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard let tag = parts.first else { continue }
                if tag == "H", parts.count >= 9, let id = Int(parts[1]) {
                    recent.append(
                        UsageRequestItem(
                            id: id,
                            timestamp: parts[2],
                            provider: parts[3],
                            model: parts[4],
                            connectionId: parts[5],
                            promptTokens: Int(parts[6]) ?? 0,
                            completionTokens: Int(parts[7]) ?? 0,
                            status: parts[8]
                        )
                    )
                }
            }
            Task { @MainActor in
                self.usageInFlight = false
                self.lastUsageAt = Date()
                if !self.usageSSEConnected {
                    if self.recentUsage != recent { self.recentUsage = recent }
                }
                if self.usageNeedsRefresh {
                    self.usageNeedsRefresh = false
                    self.refreshUsageSilent(force: true)
                }
            }
        }
    }

    func startUsageSSE() {
        guard !quitting, selectedSection == .overview else { return }
        usageSSEGeneration &+= 1
        let gen = usageSSEGeneration
        usageSSETask?.cancel()
        usageSSETask = Task.detached(priority: .utility) { [weak self] in
            await self?.runUsageSSELoop(generation: gen)
        }
    }

    /// Không restart SSE nếu đang nối — tránh flicker mỗi poll 5s.
    func ensureUsageSSE() {
        guard !quitting, routerStatus == .ready, selectedSection == .overview else { return }
        if usageSSEConnected, usageSSETask != nil { return }
        startUsageSSE()
    }

    func stopUsageSSE() {
        usageSSEGeneration &+= 1
        usageSSETask?.cancel()
        usageSSETask = nil
        topologyTrafficTask?.cancel()
        topologyTrafficTask = nil
        usagePeriodRefreshTask?.cancel()
        usagePeriodRefreshTask = nil
        lastTopologyTrafficKey = ""
        if usageSSEConnected {
            usageSSEConnected = false
        }
        if !activeUsageProviders.isEmpty { activeUsageProviders = [] }
        if !activeUsageModels.isEmpty { activeUsageModels = [] }
        if !lastUsageProvider.isEmpty { lastUsageProvider = "" }
        if !errorUsageProvider.isEmpty { errorUsageProvider = "" }
    }

    nonisolated private func runUsageSSELoop(generation: UInt64) async {
        var backoffNs: UInt64 = 1_000_000_000
        while !Task.isCancelled {
            let state = await MainActor.run { () -> (quit: Bool, gen: UInt64, ready: Bool) in
                (self.quitting, self.usageSSEGeneration, self.routerStatus == .ready)
            }
            guard !state.quit, state.gen == generation else { break }
            guard state.ready else {
                await MainActor.run { self.usageSSEConnected = false }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            guard let token = NineRouterDashboardAuth.mintAuthToken() else {
                await MainActor.run {
                    self.usageSSEConnected = false
                    self.refreshUsageSilent(force: true)
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            do {
                try await consumeUsageSSE(token: token, generation: generation)
                backoffNs = 1_000_000_000
            } catch is CancellationError {
                break
            } catch {
                let still = await MainActor.run { () -> Bool in
                    self.usageSSEConnected = false
                    self.refreshUsageSilent(force: true)
                    return !self.quitting && self.usageSSEGeneration == generation
                }
                if !still || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: backoffNs)
                backoffNs = min(backoffNs * 2, 20_000_000_000)
            }
        }
        await MainActor.run {
            guard self.usageSSEGeneration == generation else { return }
            self.usageSSEConnected = false
        }
    }

    nonisolated private func consumeUsageSSE(token: String, generation: UInt64) async throws {
        guard let url = URL(string: "http://127.0.0.1:20128/api/usage/stream") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("auth_token=\(token)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 3600

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }

        let alive = await MainActor.run { () -> Bool in
            guard self.usageSSEGeneration == generation, !self.quitting else { return false }
            self.usageSSEConnected = true
            return true
        }
        guard alive else { return }

        // LIVE/ERROR: flush ngay. Stats/recent: coalesce ngắn.
        var pending: UsageSSESnapshot?
        var lastFlush = ContinuousClock.now
        let coalesce: Duration = .milliseconds(80)
        var lastActivityKey = ""
        var lineCount = 0

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            lineCount += 1
            if lineCount % 80 == 0 {
                let keepGoing = await MainActor.run {
                    !self.quitting && self.usageSSEGeneration == generation
                }
                guard keepGoing else { break }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(":") { continue }
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let snap = NineRouterUsageSSEParse.parse(payload) else { continue }
            pending = snap

            let activityKey =
                "\(snap.activeProviders.sorted().joined(separator: ","))|\(snap.activeModels.sorted().joined(separator: ","))|\(snap.errorProvider)|\(snap.lastProvider)"
            let activityChanged = activityKey != lastActivityKey
            let now = ContinuousClock.now
            if activityChanged || now - lastFlush >= coalesce, let flush = pending {
                pending = nil
                lastFlush = now
                lastActivityKey = activityKey
                let still = await MainActor.run { () -> Bool in
                    guard self.usageSSEGeneration == generation, !self.quitting else { return false }
                    self.applyUsageSSESnapshot(flush)
                    return true
                }
                if !still { break }
            }
        }

        if let flush = pending {
            await MainActor.run {
                guard self.usageSSEGeneration == generation, !self.quitting else { return }
                self.applyUsageSSESnapshot(flush)
            }
        }

        await MainActor.run {
            guard self.usageSSEGeneration == generation else { return }
            self.usageSSEConnected = false
        }
    }

    private func applyUsageSSESnapshot(_ snap: UsageSSESnapshot) {
        // LIVE trước — nhẹ nhất. Không đụng REST stats trên hot path.
        let recentChanged = recentUsage != snap.recent
        let liveChanged = activeUsageProviders != snap.activeProviders
            || activeUsageModels != snap.activeModels
        if liveChanged { activeUsageProviders = snap.activeProviders }
        if activeUsageModels != snap.activeModels { activeUsageModels = snap.activeModels }
        if lastUsageProvider != snap.lastProvider { lastUsageProvider = snap.lastProvider }
        if errorUsageProvider != snap.errorProvider { errorUsageProvider = snap.errorProvider }
        if recentChanged { recentUsage = snap.recent }
        lastUsageAt = Date()

        if liveChanged, selectedSection == .overview {
            scheduleTopologyTimer()
        }

        // Totals theo kỳ: debounce riêng — không block glow.
        if recentChanged, usagePeriod == .today {
            scheduleUsagePeriodStatsRefresh()
        }

        let trafficKey = "\(snap.errorProvider)|\(snap.recent.first.map { "\($0.provider):\($0.status):\($0.id)" } ?? "")"
        guard trafficKey != lastTopologyTrafficKey else { return }
        lastTopologyTrafficKey = trafficKey

        topologyTrafficTask?.cancel()
        let err = snap.errorProvider
        let recent = snap.recent
        topologyTrafficTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, !self.quitting else { return }
            self.applyTopologyStatusFromTraffic(errorProvider: err, recent: recent)
        }
    }

    func setUsagePeriod(_ period: UsagePeriod) {
        guard usagePeriod != period else { return }
        usagePeriod = period
        refreshUsagePeriodStats(force: true)
    }

    /// Debounce fetch stats sau traffic — giữ khỏi hot path SSE.
    private func scheduleUsagePeriodStatsRefresh() {
        usagePeriodRefreshTask?.cancel()
        usagePeriodRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, !self.quitting else { return }
            self.refreshUsagePeriodStats(force: false)
        }
    }

    /// REQ/IN/OUT/COST theo kỳ — `GET /api/usage/stats?period=` (tách khỏi SSE).
    func refreshUsagePeriodStats(force: Bool = false) {
        guard !quitting, routerStatus == .ready else { return }
        if !force, selectedSection != .overview { return }
        if usagePeriodInFlight { return }
        if !force, let last = lastUsagePeriodAt, Date().timeIntervalSince(last) < usagePeriodMinInterval {
            return
        }
        guard let token = NineRouterDashboardAuth.mintAuthToken() else { return }
        let period = usagePeriod.rawValue
        usagePeriodInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var stats = UsageStats()
            if let url = URL(string: "http://127.0.0.1:20128/api/usage/stats?period=\(period)") {
                var req = URLRequest(url: url, timeoutInterval: 6)
                req.setValue("auth_token=\(token)", forHTTPHeaderField: "Cookie")
                req.setValue("AI-Gate-Usage/1.0", forHTTPHeaderField: "User-Agent")
                let sem = DispatchSemaphore(value: 0)
                var obj: [String: Any]?
                URLSession.shared.dataTask(with: req) { data, _, _ in
                    defer { sem.signal() }
                    guard let data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    obj = json
                }.resume()
                _ = sem.wait(timeout: .now() + 7)
                if let obj {
                    func intVal(_ key: String) -> Int {
                        if let i = obj[key] as? Int { return i }
                        if let n = obj[key] as? NSNumber { return n.intValue }
                        return 0
                    }
                    stats.requests = intVal("totalRequests")
                    stats.promptTokens = intVal("totalPromptTokens")
                    stats.cachedTokens = intVal("totalCachedTokens")
                    stats.completionTokens = intVal("totalCompletionTokens")
                    if let c = obj["totalCost"] as? Double {
                        stats.cost = c
                    } else if let n = obj["totalCost"] as? NSNumber {
                        stats.cost = n.doubleValue
                    }
                }
            }
            Task { @MainActor in
                self.usagePeriodInFlight = false
                self.lastUsagePeriodAt = Date()
                guard self.usagePeriod.rawValue == period else { return }
                if self.usageStats != stats { self.usageStats = stats }
            }
        }
    }

    /// Khi traffic thật lỗi/OK qua SSE — cập nhật badge provider trên graph (giữ như live).
    private func applyTopologyStatusFromTraffic(errorProvider: String, recent: [UsageRequestItem]) {
        guard !pathHealth.topologyProviders.isEmpty else { return }
        var items = pathHealth.topologyProviders
        var changed = false

        func matchIndex(provider: String, model: String) -> Int? {
            let p = provider.lowercased()
            guard !p.isEmpty else { return nil }
            // Chỉ khớp theo provider id/alias — không match lỏng theo model (dễ gán nhầm Fail).
            for (i, item) in items.enumerated() {
                let keys = ComboActivity.providerKeys(for: item)
                if keys.contains(p) { return i }
                if keys.contains(where: { p == $0 || p.hasPrefix($0 + "-") }) { return i }
            }
            return nil
        }

        func markFail(at i: Int, statusRaw: String, detail: String) {
            var item = items[i]
            let code: Int? = {
                if let i = Int(statusRaw), (400...599).contains(i) { return i }
                let digits = String(statusRaw.filter(\.isNumber))
                if let i = Int(digits), (400...599).contains(i) { return i }
                return nil
            }()
            let nextStatus = code != nil ? "unavailable" : (statusRaw.isEmpty ? "error" : statusRaw)
            let nextUsable = false
            let nextCode = code ?? item.errorCode
            let nextErr = detail.isEmpty ? (code.map { "[\($0)]" } ?? item.lastError) : detail
            guard item.usable != nextUsable
                || item.testStatus != nextStatus
                || item.errorCode != nextCode
                || item.lastError != nextErr
                || !item.live else { return }
            item.usable = nextUsable
            item.testStatus = nextStatus
            item.errorCode = nextCode
            item.lastError = nextErr
            item.live = true
            items[i] = item
            changed = true
        }

        func markOK(at i: Int) {
            var item = items[i]
            guard !item.usable
                || item.testStatus != "active"
                || item.errorCode != nil
                || !item.lastError.isEmpty
                || !item.live else { return }
            item.usable = true
            item.testStatus = "active"
            item.errorCode = nil
            item.lastError = ""
            item.live = true
            items[i] = item
            changed = true
        }

        // Recent trước (cụ thể hơn): fail rồi mới OK theo thứ tự list (mới → cũ).
        // Duyệt cũ → mới rồi apply, để bản ghi mới nhất thắng.
        for row in recent.reversed() {
            let st = row.status.lowercased()
            guard let idx = matchIndex(provider: row.provider, model: row.model) else { continue }
            let ok = st.isEmpty || st == "ok" || st == "success"
            if ok {
                markOK(at: idx)
            } else {
                markFail(at: idx, statusRaw: st, detail: row.status)
            }
        }

        if !errorProvider.isEmpty, let idx = matchIndex(provider: errorProvider, model: "") {
            markFail(at: idx, statusRaw: "error", detail: "Request lỗi (SSE)")
        }

        guard changed else { return }
        var ph = topology.pathHealth
        ph.topologyProviders = items
        ph.topologyActive = items.filter(\.usable).count
        ph.topologyCount = items.count
        topology.pathHealth = ph
    }

    func applyCursorConfig(model: String? = nil, relaunchNotice: Bool = true) {
        guard !cursorApplyBusy else { return }
        cursorApplyBusy = true
        let m: String = {
            if let model, !model.isEmpty { return model }
            return cursorComboForApply
        }()
        addLog("Đang tắt Cursor, sửa config lỗi và ghi Bridge (Base URL + API key + \(m))...", level: .info, source: "CursorBridge", notify: true)
        runManager("--cursor-apply", extraArgs: ["--model", m]) { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                self.cursorApplyBusy = false
                if let obj = Self.parseJSONObject(output) {
                    let ok = obj["ok"] as? Bool ?? false
                    let msg = obj["message"] as? String ?? (ok ? "Applied" : "Apply failed")
                    self.cursorApplyMessage = msg
                    if ok {
                        let applied = obj["model"] as? String ?? m
                        self.cursorAppliedCombo = applied
                        self.bridgeStore.saveCursorCombo(applied)
                    }
                    self.addLog(msg, level: ok ? .success : .error, source: "CursorBridge", notify: relaunchNotice)
                } else {
                    self.cursorApplyMessage = "Apply failed (no response)"
                    self.addLog("Apply to Cursor failed", level: .error, source: "CursorBridge", detail: output, notify: true)
                }
                self.refreshPathHealth(force: true)
            }
        }
    }

    func setBridgeAutoHeal(_ enabled: Bool) {
        let flag = enabled ? "on" : "off"
        bridgeStatus.autoHeal = enabled
        runManager("--bridge-set-autoheal", extraArgs: [flag]) { [weak self] output in
            Task { @MainActor in
                if let parsed = Self.parseBridgeStatus(output) {
                    self?.publishBridgeStatus(parsed)
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
                    self?.publishBridgeStatus(parsed)
                    if parsed.isReady {
                        self?.addLog("Auto-heal restored Funnel: \(parsed.baseUrl)", level: .success, source: "CursorBridge", notify: true)
                    }
                }
            }
        }
    }

    /// Overview master switch: ON = auto Tailscale/Funnel + Apply Cursor; OFF = tắt Funnel.
    func setCursorBridgeEnabled(_ enabled: Bool) {
        if !enabled {
            disableCursorBridge()
            return
        }
        guard routerStatus == .ready else {
            addLog(
                "Bật 9Router (Start) trước khi bật Cursor",
                level: .warning,
                source: "CursorBridge",
                notify: true
            )
            return
        }
        bridgeStatus.wanted = true
        bridgeStatus.autoHeal = true
        runManager("--bridge-set-autoheal", extraArgs: ["on"]) { _ in }
        if bridgeStatus.installed && bridgeStatus.loggedIn {
            enableCursorBridge()
        } else {
            runBridgeAutoSetup()
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
                        self.lastBridgeProbeAt = Date()
                        if let parsed = Self.parseBridgeStatus(statusRaw) {
                            self.publishBridgeStatus(parsed)
                            self.previousBridgeReady = parsed.isReady
                        }
                        self.loadNineRouterCredentials(force: true)
                        if self.bridgeStatus.isReady {
                            self.addLog("Cursor sẵn sàng: \(self.bridgeStatus.baseUrl)", level: .success, source: "CursorBridge", notify: true)
                            self.applyCursorConfig()
                        } else {
                            // One more heal attempt when Tailscale is up but Funnel lagged.
                            self.addLog(
                                "Tunnel chưa sẵn sàng — đang thử lại…",
                                level: .warning,
                                source: "CursorBridge",
                                detail: self.bridgeStatus.message,
                                notify: true
                            )
                            self.maybeRequestBridgeHeal()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                self.refreshCursorBridge(force: true)
                                if self.bridgeStatus.isReady {
                                    self.applyCursorConfig()
                                }
                            }
                        }
                        self.refreshPathHealth(force: true)
                    }
                }
            }
        }
    }

    /// Giống Environment Auto Install: cài Tailscale → mở login → chờ Running → bật Funnel → Apply Cursor.
    func runBridgeAutoSetup() {
        guard !bridgeSetupRunning && !bridgeBusy else { return }
        bridgeSetupRunning = true
        bridgeBusy = true
        lastAction = "Auto-setup Cursor Bridge..."
        addLog("Starting Cursor Bridge auto setup (install Tailscale → login → Funnel → Apply Cursor)...", level: .info, source: "CursorBridge", notify: true)

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
                    self.checkEnvironment(force: true)
                    self.refreshCursorBridge(force: true)
                    if p.terminationStatus == 0 {
                        self.addLog("Cursor Bridge auto setup completed", level: .success, source: "CursorBridge", notify: true)
                        // Finish: ensure Funnel wanted + Apply into Cursor.
                        if self.bridgeStatus.isReady {
                            self.applyCursorConfig()
                        } else if self.bridgeStatus.installed && self.bridgeStatus.loggedIn {
                            self.enableCursorBridge()
                        }
                    } else {
                        self.addLog(
                            "Cần thêm 1 bước trên macOS (mật khẩu / Log in Tailscale)",
                            level: .warning,
                            source: "CursorBridge",
                            detail: self.bridgeStatus.message.isEmpty
                                ? "Hoàn tất hộp thoại macOS rồi bật lại toggle Cursor trên Overview."
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

    func restartCursorBridge() {
        guard !bridgeBusy && !bridgeSetupRunning else { return }
        addLog("Restarting Cursor Funnel...", level: .info, source: "CursorBridge", notify: true)
        bridgeBusy = true
        runManager("--bridge-stop") { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.bridgeBusy = false
                self.enableCursorBridge()
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
                self?.bridgeStatus.wanted = false
                self?.bridgeStatus.funnelEnabled = false
                self?.refreshCursorBridge(force: true)
                self?.addLog("Cursor Bridge tắt — local 9Router/Codex vẫn chạy", level: .info, source: "CursorBridge", notify: true)
            }
        }
    }

    private func loadNineRouterCredentials(force: Bool = false) {
        if !force, let last = lastCredentialsAt,
           Date().timeIntervalSince(last) < silentCredentialsMinInterval {
            return
        }
        lastCredentialsAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let db = ("~/.9router/db/data.sqlite" as NSString).expandingTildeInPath
            let key = self.execShell("sqlite3 \"\(db)\" \"SELECT key FROM apiKeys WHERE isActive=1 ORDER BY createdAt ASC LIMIT 1;\" 2>/dev/null")
            // Chỉ lấy Combo / Vision Adapter từ bảng combos của 9Router — không gộp model provider lẻ.
            let combos = self.execShell("sqlite3 \"\(db)\" \"SELECT name FROM combos ORDER BY updatedAt DESC;\" 2>/dev/null")
            var models = combos
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if models.isEmpty { models = ["my-combo"] }

            Task { @MainActor in
                if !key.isEmpty, self.nineRouterApiKey != key {
                    self.nineRouterApiKey = key
                }
                if self.availableModels != models {
                    self.availableModels = models
                }
                if !models.contains(self.previewCombo) {
                    self.previewCombo = models.contains("my-combo") ? "my-combo" : (models.first ?? "my-combo")
                }
            }
        }
    }

    func reloadNineRouterCombos() {
        loadNineRouterCredentials(force: true)
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
            providers = arr.map { Self.parseProviderItem($0) }
        }
        var topologyProviders: [ProviderHealthItem] = []
        if let arr = obj["topologyProviders"] as? [[String: Any]] {
            topologyProviders = arr.map { Self.parseProviderItem($0) }
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
            cursorAppliedModel: obj["cursorAppliedModel"] as? String ?? "",
            codexAppliedModel: obj["codexAppliedModel"] as? String ?? "",
            comboName: obj["comboName"] as? String ?? "my-combo",
            comboHealthy: obj["comboHealthy"] as? Bool ?? false,
            usableProviders: obj["usableProviders"] as? Int ?? 0,
            providerCount: obj["providerCount"] as? Int ?? 0,
            providers: providers,
            topologyProviders: topologyProviders,
            topologyActive: obj["topologyActive"] as? Int ?? topologyProviders.filter(\.usable).count,
            topologyCount: obj["topologyCount"] as? Int ?? topologyProviders.count,
            cursorPathOk: obj["cursorPathOk"] as? Bool ?? false,
            cursorStalePublic: obj["cursorStalePublic"] as? Bool ?? false,
            expectedCursorBaseUrl: obj["expectedCursorBaseUrl"] as? String ?? "",
            cursorShimRunning: obj["cursorShimRunning"] as? Bool ?? false,
            message: obj["message"] as? String ?? ""
        )
    }

    private static func parseProviderItem(_ item: [String: Any]) -> ProviderHealthItem {
        let code: Int? = {
            if let i = item["errorCode"] as? Int { return i }
            if let n = item["errorCode"] as? NSNumber { return n.intValue }
            if let s = item["errorCode"] as? String, let i = Int(s) { return i }
            return nil
        }()
        let latency: Int? = {
            if let i = item["latencyMs"] as? Int { return i }
            if let n = item["latencyMs"] as? NSNumber { return n.intValue }
            return nil
        }()
        return ProviderHealthItem(
            model: item["model"] as? String ?? "",
            provider: item["provider"] as? String ?? "",
            name: item["name"] as? String ?? "",
            displayName: item["displayName"] as? String ?? "",
            active: item["active"] as? Bool ?? false,
            testStatus: item["testStatus"] as? String ?? "",
            errorCode: code,
            lastError: item["lastError"] as? String ?? "",
            usable: item["usable"] as? Bool ?? false,
            latencyMs: latency,
            live: item["live"] as? Bool ?? false,
            sourceIsFreeNoAuth: (item["source"] as? String) == "noAuth",
            connectionId: item["connectionId"] as? String ?? ""
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

    /// Test thật đường Codex qua 9Router local (models + chat ping combo đang apply).
    func testCodex() {
        guard !testingCodex else { return }
        guard routerStatus == .ready else {
            addLog("9Router chưa chạy — không test được Codex", level: .warning, source: "Codex", notify: true)
            return
        }
        testingCodex = true
        codexTestOk = nil
        codexLatencyMs = nil
        let model = codexAppliedCombo.isEmpty ? "my-combo" : codexAppliedCombo
        addLog("Đang test Codex «\(model)»…", level: .info, source: "Codex", notify: true)
        runManager("--codex-test", extraArgs: ["--model", model]) { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                self.testingCodex = false
                if let obj = Self.parseJSONObject(output) {
                    let ok = obj["ok"] as? Bool ?? false
                    let ms = obj["latencyMs"] as? Int ?? 0
                    let msg = obj["message"] as? String ?? (ok ? "Codex OK" : "Codex test failed")
                    let detail = obj["detail"] as? String ?? ""
                    self.codexTestOk = ok
                    self.codexLatencyMs = ms > 0 ? ms : nil
                    if let cfg = obj["configModel"] as? String, !cfg.isEmpty,
                       let matches = obj["configMatches"] as? Bool, !matches {
                        self.addLog(
                            "config.toml model=\(cfg) khác combo UI «\(model)»",
                            level: .warning,
                            source: "Codex",
                            notify: true
                        )
                    }
                    let done = ok
                        ? (ms > 0 ? "Codex OK (\(ms) ms)" : "Codex OK")
                        : msg
                    self.addLog(done, level: ok ? .success : .error, source: "Codex", detail: detail.isEmpty ? nil : detail, notify: true)
                } else {
                    self.codexTestOk = false
                    self.addLog("Codex test failed (no response)", level: .error, source: "Codex", detail: output, notify: true)
                }
            }
        }
    }

    /// Test đường Cursor: Funnel public (nếu có) + chat ping combo đang apply.
    func testCursor() {
        guard !testingCursor else { return }
        guard routerStatus == .ready else {
            addLog("9Router chưa chạy — không test được Cursor", level: .warning, source: "Cursor", notify: true)
            return
        }
        guard bridgeStatus.wanted || bridgeStatus.isReady else {
            addLog("Bật Cursor trước khi Test", level: .warning, source: "Cursor", notify: true)
            return
        }
        testingCursor = true
        cursorTestOk = nil
        cursorLatencyMs = nil
        let model = cursorAppliedCombo.isEmpty ? "my-combo" : cursorAppliedCombo
        addLog("Đang test Cursor «\(model)»…", level: .info, source: "Cursor", notify: true)
        runManager("--cursor-test", extraArgs: ["--model", model]) { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                self.testingCursor = false
                if let obj = Self.parseJSONObject(output) {
                    let ok = obj["ok"] as? Bool ?? false
                    let warn = obj["warn"] as? Bool ?? obj["slowForAgent"] as? Bool ?? false
                    let ms = obj["latencyMs"] as? Int ?? 0
                    let msg = obj["message"] as? String ?? (ok ? "Cursor OK" : "Cursor test failed")
                    let detail = obj["detail"] as? String ?? ""
                    self.cursorTestOk = ok
                    self.cursorLatencyMs = ms > 0 ? ms : nil
                    let done: String
                    let level: LogLevel
                    if !ok {
                        done = msg
                        level = .error
                    } else if warn {
                        done = msg
                        level = .warning
                    } else {
                        done = ms > 0 ? "Cursor OK (\(ms) ms)" : "Cursor OK"
                        level = .success
                    }
                    self.addLog(done, level: level, source: "Cursor", detail: detail.isEmpty ? nil : detail, notify: true)
                } else {
                    self.cursorTestOk = false
                    self.addLog("Cursor test failed (no response)", level: .error, source: "Cursor", detail: output, notify: true)
                }
            }
        }
    }


    // MARK: - Lifecycle & Process Helpers

    func quit() {
        guard !quitting else { return }
        quitting = true
        menuBarTimer?.invalidate()
        menuBarTimer = nil
        sectionTimer?.invalidate()
        sectionTimer = nil
        topologyTimer?.invalidate()
        topologyTimer = nil
        logTimer?.invalidate()
        logTimer = nil
        usageTimer?.invalidate()
        usageTimer = nil
        stopUsageSSE()
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
        menuBarTimer?.invalidate()
        menuBarTimer = nil
        sectionTimer?.invalidate()
        sectionTimer = nil
        topologyTimer?.invalidate()
        topologyTimer = nil
        logTimer?.invalidate()
        logTimer = nil
        usageTimer?.invalidate()
        usageTimer = nil
        stopUsageSSE()
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

    // MARK: - Backup / Restore

    func exportBackup() {
        guard !backupBusy else { return }
        let panel = NSSavePanel()
        panel.title = "Lưu backup AI Gate"
        panel.nameFieldStringValue = Self.defaultBackupFilename()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.init(filenameExtension: "aigate")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        backupBusy = true
        backupMessage = "Đang tạo backup..."
        runManager("--backup-export", extraArgs: ["--output", url.path]) { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                self.backupBusy = false
                if let obj = Self.parseJSONObject(output), obj["ok"] as? Bool == true {
                    let msg = obj["message"] as? String ?? "Backup thành công"
                    self.backupMessage = msg
                    self.addLog(msg, level: .success, source: "Backup", notify: true)
                } else {
                    let msg = Self.parseJSONObject(output)?["message"] as? String ?? "Backup thất bại"
                    self.backupMessage = msg
                    self.addLog(msg, level: .error, source: "Backup", detail: output, notify: true)
                }
            }
        }
    }

    func importBackup() {
        guard !backupBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Chọn file backup AI Gate"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "aigate")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        backupBusy = true
        backupMessage = "Đang restore..."
        runManager("--backup-import", extraArgs: ["--input", url.path]) { [weak self] output in
            Task { @MainActor in
                guard let self = self else { return }
                self.backupBusy = false
                if let obj = Self.parseJSONObject(output), obj["ok"] as? Bool == true {
                    let msg = obj["message"] as? String ?? "Restore thành công"
                    self.backupMessage = msg
                    self.addLog(msg, level: .success, source: "Backup", notify: true)
                    self.finishBackupRestore()
                } else {
                    let msg = Self.parseJSONObject(output)?["message"] as? String ?? "Restore thất bại"
                    self.backupMessage = msg
                    self.addLog(msg, level: .error, source: "Backup", detail: output, notify: true)
                }
            }
        }
    }

    private func finishBackupRestore() {
        loadProxies()
        previewCombo = bridgeStore.loadPreviewCombo(default: previewCombo)
        cursorAppliedCombo = bridgeStore.loadCursorCombo(default: cursorAppliedCombo)
        codexAppliedCombo = bridgeStore.loadCodexCombo(default: codexAppliedCombo)
        isManuallyStopped = false
        launchBackendIfNeeded()
        runManager("--restart") { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshCursorBridge(force: true)
                self?.refreshTopologySilent(force: true)
                self?.addLog(
                    "Đã khởi động lại dịch vụ sau restore. Bật lại Cursor Bridge (Tailscale) nếu cần.",
                    level: .info,
                    source: "Backup",
                    notify: true
                )
            }
        }
    }

    private static func defaultBackupFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return "AI-Gate-Backup-\(fmt.string(from: Date())).aigate"
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

    private func load() -> [String: Any] {
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }

    private func save(_ obj: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? d.write(to: url, options: .atomic)
        }
    }

    func loadPreviewCombo(default defaultModel: String) -> String {
        let obj = load()
        if let m = obj["previewCombo"] as? String, !m.isEmpty { return m }
        // migrate legacy key
        if let m = obj["selectedModel"] as? String, !m.isEmpty { return m }
        return defaultModel
    }

    func savePreviewCombo(_ model: String) {
        var obj = load()
        obj["previewCombo"] = model
        save(obj)
    }

    func loadCursorCombo(default defaultModel: String) -> String {
        let obj = load()
        if let m = obj["cursorCombo"] as? String, !m.isEmpty { return m }
        return defaultModel
    }

    func saveCursorCombo(_ model: String) {
        var obj = load()
        obj["cursorCombo"] = model
        save(obj)
    }

    func loadCodexCombo(default defaultModel: String) -> String {
        let obj = load()
        if let m = obj["codexCombo"] as? String, !m.isEmpty { return m }
        return defaultModel
    }

    func saveCodexCombo(_ model: String) {
        var obj = load()
        obj["codexCombo"] = model
        save(obj)
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
    }
}

struct CodeBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
            )
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
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            ZStack {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                switch state.selectedSection {
                case .overview:
                    OverviewView()
                case .proxies:
                    ProxiesView(showingAdd: $showingAddProxy)
                case .backup:
                    BackupView()
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
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1100, minHeight: 700)
        .onChange(of: state.selectedSection) { _, _ in
            state.syncSectionPolling()
        }
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

    var body: some View {
        VStack(spacing: 0) {
            // Brand header
            HStack(spacing: 12) {
                AppLogoImage(kind: .app, size: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Gate")
                        .font(.system(size: 15, weight: .bold))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.overallReady ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(state.overallReady ? "Online" : "Attention")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(state.overallReady ? Color.green : Color.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider().opacity(0.5)

            // Nav items
            VStack(alignment: .leading, spacing: 4) {
                Text("NAVIGATION")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                ForEach(AppState.Section.allCases) { sec in
                    sidebarItem(sec)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)

            Spacer(minLength: 0)

            // Footer status
            VStack(alignment: .leading, spacing: 8) {
                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    SquircleIcon(
                        symbol: "server.rack",
                        color: state.routerStatus == .ready
                            ? Color(red: 0.19, green: 0.68, blue: 0.60)
                            : .orange,
                        size: 22,
                        inner: 10,
                        radius: 6
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("9Router")
                            .font(.system(size: 11, weight: .semibold))
                        Text(state.routerStatus == .ready ? "Gateway ready" : "Gateway offline")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                    Spacer(minLength: 0)
                    Text("\(state.readyProxiesCount)/\(max(state.proxies.count, 1))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .help("Proxies ready / configured")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func sidebarItem(_ sec: AppState.Section) -> some View {
        let selected = state.selectedSection == sec
        return Button {
            state.selectedSection = sec
        } label: {
            HStack(spacing: 11) {
                SquircleIcon(
                    symbol: sec.icon,
                    color: selected ? sec.accentColor : Color(nsColor: .tertiaryLabelColor).opacity(0.85),
                    size: 28,
                    inner: 13,
                    radius: 7
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(sec.rawValue)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                    Text(sec.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                Spacer(minLength: 0)
                if selected {
                    Circle()
                        .fill(sec.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? sec.accentColor.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? sec.accentColor.opacity(0.28) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cursor details sheet (opened from Overview)

struct CursorDetailsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var isOn: Bool { state.bridgeStatus.wanted || state.bridgeStatus.isReady }
    private var isBusy: Bool { state.bridgeBusy || state.bridgeSetupRunning || state.bridgeHealing }

    private var headline: String {
        if !isOn { return "Cursor đang tắt" }
        if isBusy || state.bridgeStatus.isRecovering { return "Đang thiết lập / khôi phục" }
        if state.pathHealth.cursorPathOk { return "Đường Cursor ổn định" }
        return "Cần kiểm tra"
    }

    private var subtitle: String {
        if !isOn {
            return "Bật toggle Cursor trong Active Services (Overview) khi cần."
        }
        if !state.pathHealth.message.isEmpty { return state.pathHealth.message }
        if !state.bridgeStatus.message.isEmpty { return state.bridgeStatus.message }
        return "Theo dõi tunnel công khai và cấu hình trong Cursor."
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cursor")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Đóng") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .center, spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill((state.pathHealth.cursorPathOk ? Color.green : Color.orange).opacity(isOn ? 0.15 : 0.08))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: state.pathHealth.cursorPathOk ? "checkmark.circle.fill" : "link.circle.fill")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(isOn ? (state.pathHealth.cursorPathOk ? Color.green : Color.orange) : Color(nsColor: .tertiaryLabelColor))
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(headline)
                                        .font(.system(size: 16, weight: .bold))
                                    Text(subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }

                            HStack(spacing: 8) {
                                Button {
                                    state.refreshCursorBridge(force: true)
                                } label: {
                                    Label("Làm mới", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .disabled(isBusy)

                                Button {
                                    state.testCursor()
                                } label: {
                                    if state.testingCursor {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Text("Test")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(state.testingCursor || !isOn || state.routerStatus != .ready)
                                .help("Test Funnel URL + chat ping")

                                Button("Khởi động lại tunnel") {
                                    state.restartCursorBridge()
                                }
                                .buttonStyle(.bordered)
                                .disabled(isBusy || !isOn)

                                Button(state.cursorApplyBusy ? "Đang ghi…" : "Ghi lại & mở lại Cursor") {
                                    state.applyCursorConfig()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(state.cursorApplyBusy || !state.bridgeStatus.isReady || state.nineRouterApiKey.isEmpty)
                                .help("Tắt Cursor, dọn config lỗi, ghi Base URL + API key + model, rồi mở lại Cursor")

                                Spacer()
                            }

                            if let ms = state.cursorLatencyMs {
                                Text("Latency lần test gần nhất: \(ms) ms")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            }

                            if !state.cursorApplyMessage.isEmpty {
                                Text(state.cursorApplyMessage)
                                    .font(.system(size: 11))
                                    .foregroundStyle(state.pathHealth.cursorConfigured ? Color.green : Color.orange)
                            }
                        }
                        .padding(16)
                    }

                    SettingsCard(header: "Checklist") {
                        VStack(spacing: 0) {
                            bridgeCheckRow(
                                title: "9Router local",
                                ok: state.routerStatus == .ready,
                                detail: state.routerStatus == .ready ? "Gateway :20128 đang chạy" : "Bật Start trên Overview"
                            )
                            Divider().padding(.leading, 46)
                            bridgeCheckRow(
                                title: "Tailscale",
                                ok: state.bridgeStatus.installed && state.bridgeStatus.loggedIn,
                                detail: !state.bridgeStatus.installed
                                    ? "Chưa cài — bật Cursor ở Overview để tự setup"
                                    : (state.bridgeStatus.loggedIn ? "Đã đăng nhập" : "Cần Log in Tailscale")
                            )
                            Divider().padding(.leading, 46)
                            bridgeCheckRow(
                                title: "Tunnel công khai",
                                ok: state.bridgeStatus.funnelEnabled && state.pathHealth.publicReachable,
                                detail: state.pathHealth.publicReachable
                                    ? "HTTPS tới được (\(state.pathHealth.publicMs) ms)"
                                    : (state.bridgeStatus.funnelEnabled ? "Funnel bật nhưng chưa tới được từ ngoài" : "Chưa có Funnel")
                            )
                            Divider().padding(.leading, 46)
                            bridgeCheckRow(
                                title: "Cấu hình trong Cursor",
                                ok: state.pathHealth.cursorConfigured,
                                detail: state.pathHealth.cursorConfigured
                                    ? "Base URL + API key + model khớp"
                                    : (state.pathHealth.cursorMessage.isEmpty ? "Chưa ghi vào Cursor" : state.pathHealth.cursorMessage)
                            )
                        }
                    }

                    SettingsCard(header: "Thông tin kết nối") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Model đang áp dụng (Cursor)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                HStack(spacing: 8) {
                                    Picker("", selection: Binding(
                                        get: {
                                            let cur = state.cursorAppliedCombo.isEmpty ? "my-combo" : state.cursorAppliedCombo
                                            return state.availableModels.contains(cur) ? cur : (state.availableModels.first ?? cur)
                                        },
                                        set: { state.applyComboToCursor($0) }
                                    )) {
                                        ForEach(state.availableModels.isEmpty ? ["my-combo"] : state.availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                    .labelsHidden()
                                    .disabled(state.cursorApplyBusy || !state.bridgeStatus.isReady)
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text("Đổi ở đây mới ghi vào Cursor — chọn combo ở Overview chỉ để xem.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            }

                            bridgeCopyRow(
                                title: "Base URL (Funnel → Cursor)",
                                value: state.bridgeStatus.baseUrl.isEmpty
                                    ? "Bật Cursor ở Overview để tạo URL"
                                    : state.bridgeStatus.baseUrl,
                                canCopy: !state.bridgeStatus.baseUrl.isEmpty
                            ) {
                                state.copy(state.bridgeStatus.baseUrl, notice: "Đã copy Base URL")
                            }

                            bridgeCopyRow(
                                title: "API Key (9Router)",
                                value: state.nineRouterApiKey.isEmpty
                                    ? "Chưa có — mở 9Router Dashboard tạo API key"
                                    : state.maskedNineRouterApiKey,
                                canCopy: !state.nineRouterApiKey.isEmpty
                            ) {
                                state.copy(state.nineRouterApiKey, notice: "Đã copy API key")
                            }
                        }
                        .padding(14)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 540, minHeight: 560)
        .onAppear { state.refreshCursorBridge(force: true) }
        .overlay(alignment: .bottom) {
            ToastStackView().padding(.bottom, 12)
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
            StatusPill(text: ok ? "OK" : "Chưa", color: ok ? .green : .orange)
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
}

// MARK: - Tab 1: Overview

struct OverviewView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        GeometryReader { geo in
            let topH = max(300.0, geo.size.height * 0.52)
            let pad: CGFloat = 14
            VStack(spacing: 12) {
                // Hàng 1: biểu đồ (2/3) + recent (1/3)
                HStack(alignment: .top, spacing: 12) {
                    OverviewGraphCard()
                        .frame(width: (geo.size.width - pad * 2 - 12) * (2.0 / 3.0))
                    OverviewRecentCard()
                        .frame(maxWidth: .infinity)
                }
                .frame(height: topH)

                // Hàng 2: status + services
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        compactHero
                        compactStats
                        activeServicesCard
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(pad)
        }
        .onAppear {
            state.refreshCursorBridge(force: true)
            state.refreshUsageSilent(force: true)
        }
        .sheet(isPresented: $state.showCursorDetails) {
            CursorDetailsSheet()
                .environmentObject(state)
        }
    }

    private var compactHero: some View {
        SettingsCard {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((state.overallReady ? Color.green : Color.orange).opacity(0.16))
                        .frame(width: 34, height: 34)
                    Image(systemName: state.overallReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(state.overallReady ? Color.green : Color.orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(state.statusHeadline)
                            .font(.system(size: 14, weight: .bold))
                        Circle()
                            .fill(state.overallReady ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                    }
                    Text(state.statusDetailLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button { state.restart() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 14, height: 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.isBusy)
                    .help("Làm mới / restart dịch vụ")

                    if !state.isManuallyStopped {
                        Button { state.stopAll() } label: {
                            Image(systemName: "stop.fill").foregroundStyle(Color.red).frame(width: 14, height: 14)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(state.isBusy)
                        .help("Dừng toàn bộ dịch vụ")
                    } else {
                        Button { state.startAll() } label: {
                            Image(systemName: "play.fill").foregroundStyle(Color.green).frame(width: 14, height: 14)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(state.isBusy)
                        .help("Start lại dịch vụ")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var compactStats: some View {
        SettingsCard(header: "System Overview") {
            HStack(spacing: 0) {
                overviewStatTile(
                    title: "9Router Gateway",
                    value: "Port 20128",
                    badgeText: state.routerStatus == .ready ? "ONLINE" : "OFFLINE",
                    badgeColor: state.routerStatus == .ready ? .green : .orange,
                    icon: "server.rack"
                )
                Divider().padding(.vertical, 8)
                overviewStatTile(
                    title: "Local Proxies",
                    value: "\(state.readyProxiesCount)/\(state.proxies.count) Ready",
                    badgeText: "\(state.proxies.count) Configured",
                    badgeColor: Color(red: 0.38, green: 0.45, blue: 0.98),
                    icon: "antenna.radiowaves.left.and.right"
                )
                Divider().padding(.vertical, 8)
                overviewStatTile(
                    title: "Runtime Environment",
                    value: "\(state.envReadyCount)/\(state.envItems.count) Ready",
                    badgeText: state.envReadyCount == state.envItems.count && !state.envItems.isEmpty ? "Complete" : "Setup Needed",
                    badgeColor: state.envReadyCount == state.envItems.count && !state.envItems.isEmpty ? .green : .orange,
                    icon: "cube.fill"
                )
            }
            .padding(.vertical, 6)
        }
    }

    private func overviewStatTile(
        title: String,
        value: String,
        badgeText: String,
        badgeColor: Color,
        icon: String
    ) -> some View {
        HStack(spacing: 10) {
            SquircleIcon(symbol: icon, color: badgeColor, size: 30, inner: 13, radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(value)
                        .font(.system(size: 12.5, weight: .bold))
                        .lineLimit(1)
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeServicesCard: some View {
        SettingsCard(header: "Active Services (\(state.proxies.count + 3))") {
            VStack(spacing: 0) {
                // 1. Cursor
                serviceRow(
                    icon: cursorOverviewIcon,
                    color: cursorOverviewIconColor,
                    title: "Cursor",
                    badge: "FUNNEL",
                    subtitle: cursorOverviewSubtitle,
                    monoSubtitle: cursorOverviewSubtitleIsURL,
                    latency: state.cursorLatencyMs.map { "\($0) ms" },
                    statusText: {
                        if state.testingCursor { return "Testing" }
                        if let ok = state.cursorTestOk { return ok ? "Running" : "Fail" }
                        return cursorServicePillText
                    }(),
                    statusColor: {
                        if let ok = state.cursorTestOk { return ok ? Color.green : Color.orange }
                        return cursorServicePillColor
                    }()
                ) {
                    if state.cursorApplyBusy { ProgressView().controlSize(.small) }
                    serviceComboPicker(
                        selection: Binding(get: { resolvedCombo(state.cursorAppliedCombo) }, set: { state.applyComboToCursor($0) }),
                        disabled: state.cursorApplyBusy || state.routerStatus != .ready || !(state.bridgeStatus.wanted || state.bridgeStatus.isReady)
                    )
                    Button {
                        state.testCursor()
                    } label: {
                        if state.testingCursor {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("Test")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.testingCursor || state.routerStatus != .ready || !(state.bridgeStatus.wanted || state.bridgeStatus.isReady))
                    .help("Test Funnel URL + chat ping combo đang apply")
                    Toggle("", isOn: Binding(
                        get: { state.bridgeStatus.wanted || state.bridgeStatus.isReady },
                        set: { state.setCursorBridgeEnabled($0) }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(state.bridgeBusy || state.bridgeSetupRunning || state.routerStatus != .ready)
                    Button("Info") { state.showCursorDetails = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Checklist + Base URL + API key")
                }

                // 2. Codex
                serviceRow(
                    icon: "terminal.fill",
                    color: Color(red: 0.20, green: 0.70, blue: 0.45),
                    title: "Codex",
                    badge: "LOCAL",
                    subtitle: "http://127.0.0.1:20128/v1",
                    latency: state.codexLatencyMs.map { "\($0) ms" },
                    statusText: state.testingCodex ? "Testing" : (state.codexTestOk == false ? "Fail" : (state.routerStatus == .ready ? "Running" : "Offline")),
                    statusColor: state.codexTestOk == false ? .orange : (state.routerStatus == .ready ? .green : .orange),
                    showDivider: true
                ) {
                    if state.codexApplyBusy { ProgressView().controlSize(.small) }
                    serviceComboPicker(
                        selection: Binding(get: { resolvedCombo(state.codexAppliedCombo) }, set: { state.applyComboToCodex($0) }),
                        disabled: state.codexApplyBusy || state.routerStatus != .ready
                    )
                    Button { state.testCodex() } label: {
                        if state.testingCodex { ProgressView().controlSize(.mini) } else { Text("Test") }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(state.testingCodex || state.routerStatus != .ready)
                    Button("Copy API") { state.copy("http://127.0.0.1:20128/v1") }
                        .buttonStyle(.bordered).controlSize(.small)
                }

                // 3. 9Router
                serviceRow(
                    icon: "server.rack",
                    color: Color(red: 0.19, green: 0.68, blue: 0.60),
                    title: "9Router Gateway",
                    badge: "PORT 20128",
                    subtitle: "http://127.0.0.1:20128",
                    subtitleCyan: true,
                    statusText: state.routerStatus == .ready ? "Running" : "Offline",
                    statusColor: state.routerStatus == .ready ? .green : .orange,
                    showDivider: true
                ) {
                    Button("Copy Endpoint") { state.copy("http://127.0.0.1:20128") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Open Dashboard") { state.openDashboard() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(state.routerStatus != .ready)
                }

                // 4. Proxies
                ForEach(state.proxies) { proxy in
                    serviceRow(
                        icon: proxy.iconName,
                        color: Color(red: 0.45, green: 0.40, blue: 0.95),
                        title: proxy.name,
                        badge: "PORT \(proxy.port)",
                        subtitle: "http://127.0.0.1:\(proxy.port)/v1",
                        latency: (proxy.enabled && proxy.status == .ready) ? "\(proxy.latency ?? 1) ms" : nil,
                        statusText: proxy.enabled ? (proxy.status == .ready ? "Running" : "Offline") : "Off",
                        statusColor: proxy.enabled && proxy.status == .ready ? .green : .orange,
                        showDivider: true
                    ) {
                        TestProxyButton(proxy: proxy)
                        Button("Copy API") { state.copy("http://127.0.0.1:\(proxy.port)/v1") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func serviceRow<Actions: View>(
        icon: String,
        color: Color,
        title: String,
        badge: String,
        subtitle: String,
        subtitleCyan: Bool = false,
        monoSubtitle: Bool = false,
        latency: String? = nil,
        statusText: String,
        statusColor: Color,
        showDivider: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 0) {
            if showDivider {
                Divider().padding(.leading, 50)
            }
            HStack(spacing: 10) {
                SquircleIcon(symbol: icon, color: color, size: 28, inner: 12, radius: 7)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 12.5, weight: .semibold))
                        CodeBadge(text: badge)
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5, design: monoSubtitle || subtitle.hasPrefix("http") ? .monospaced : .default))
                        .foregroundStyle(subtitleCyan ? Color(red: 0.35, green: 0.78, blue: 0.95) : Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if let latency {
                    Text(latency)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                StatusPill(text: statusText, color: statusColor)
                HStack(spacing: 6) {
                    actions()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private var serviceComboOptions: [String] {
        state.availableModels.isEmpty ? ["my-combo"] : state.availableModels
    }

    private func resolvedCombo(_ applied: String) -> String {
        let cur = applied.isEmpty ? (serviceComboOptions.first ?? "my-combo") : applied
        return serviceComboOptions.contains(cur) ? cur : (serviceComboOptions.first ?? cur)
    }

    private func serviceComboPicker(selection: Binding<String>, disabled: Bool) -> some View {
        Picker("", selection: selection) {
            ForEach(serviceComboOptions, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 130)
        .disabled(disabled)
    }

    private var cursorServicePillText: String {
        if state.bridgeBusy || state.bridgeSetupRunning || state.bridgeStatus.isRecovering { return "Setup" }
        if !(state.bridgeStatus.wanted || state.bridgeStatus.isReady) { return "Off" }
        if state.pathHealth.cursorPathOk { return "Running" }
        return "Check"
    }

    private var cursorServicePillColor: Color {
        if !(state.bridgeStatus.wanted || state.bridgeStatus.isReady) { return .orange }
        if state.pathHealth.cursorPathOk { return .green }
        return .orange
    }

    private var cursorOverviewSubtitle: String {
        if state.bridgeBusy || state.bridgeSetupRunning { return "Đang setup Cursor…" }
        if state.bridgeStatus.wanted || state.bridgeStatus.isReady {
            if !state.bridgeStatus.baseUrl.isEmpty { return state.bridgeStatus.baseUrl }
            return state.bridgeStatus.message.isEmpty ? "Đang mở Funnel" : state.bridgeStatus.message
        }
        return "Tắt — bật khi cần dùng trong Cursor"
    }

    private var cursorOverviewSubtitleIsURL: Bool {
        (state.bridgeStatus.wanted || state.bridgeStatus.isReady) && state.bridgeStatus.baseUrl.hasPrefix("http")
    }

    private var cursorOverviewIcon: String {
        if state.bridgeBusy || state.bridgeSetupRunning { return "arrow.triangle.2.circlepath" }
        if state.pathHealth.cursorPathOk { return "checkmark.circle.fill" }
        if state.bridgeStatus.wanted || state.bridgeStatus.isReady { return "link.circle.fill" }
        return "link.circle"
    }

    private var cursorOverviewIconColor: Color {
        if state.pathHealth.cursorPathOk { return .green }
        if state.bridgeStatus.wanted || state.bridgeStatus.isReady { return .orange }
        return Color(nsColor: .tertiaryLabelColor)
    }
}

// MARK: - Overview top: Graph (2/3) + Recent (1/3)

struct UsagePeriodPicker: View {
    let period: UsagePeriod
    let onSelect: (UsagePeriod) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsagePeriod.allCases) { p in
                Button {
                    onSelect(p)
                } label: {
                    Text(p.label)
                        .font(.system(size: 11, weight: period == p ? .semibold : .medium))
                        .foregroundStyle(period == p ? Color.white : Color.white.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(period == p ? Color.white.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Thanh filter + REQ/IN/OUT/COST — Equatable để stats đổi không kéo redraw graph nặng.
struct OverviewUsageMetricsBar: View, Equatable {
    let period: UsagePeriod
    let stats: UsageStats
    let onSelect: (UsagePeriod) -> Void

    static func == (lhs: OverviewUsageMetricsBar, rhs: OverviewUsageMetricsBar) -> Bool {
        lhs.period == rhs.period && lhs.stats == rhs.stats
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Spacer(minLength: 0)
                UsagePeriodPicker(period: period, onSelect: onSelect)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                miniMetric("REQ", "\(stats.requests)", Color(nsColor: .labelColor))
                miniMetric("IN", ComboFormat.tokens(stats.promptTokens), .orange)
                miniMetric("OUT", ComboFormat.tokens(stats.completionTokens), .green)
                miniMetric("COST", ComboFormat.cost(stats.cost), Color(red: 0.95, green: 0.75, blue: 0.25))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func miniMetric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct OverviewGraphCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var topology: TopologyStore

    /// Topology Usage 9Router — không lấy model list trong combo.
    private var topologyProviders: [ProviderHealthItem] {
        let topo = topology.pathHealth.topologyProviders
        return topo.isEmpty ? topology.pathHealth.providers : topo
    }

    private var providerTopologyRatio: String {
        let all = topologyProviders
        guard !all.isEmpty else {
            let c = topology.pathHealth.topologyCount
            if c > 0 { return "\(topology.pathHealth.topologyActive)/\(c)" }
            return "—/—"
        }
        let ok = all.filter(\.usable).count
        return "\(ok)/\(all.count)"
    }

    private var providerTopologyRatioColor: Color {
        let all = topologyProviders
        if all.isEmpty { return .green }
        let ok = all.filter(\.usable).count
        if ok == all.count { return .green }
        if ok == 0 { return .orange }
        return .yellow
    }

    private var topologySourceCaption: String {
        if state.bridgeStatus.wanted {
            let live = !usage.activeUsageProviders.isEmpty || !usage.activeUsageModels.isEmpty
            if live { return "· LIVE (request tới 9Router)" }
            if !topology.pathHealth.cursorPathOk {
                return "· Cursor chưa tới 9Router (Network Error?)"
            }
            return "· chờ request Cursor/IDE"
        }
        return topologyProviders.contains(where: \.live) ? "· live probe" : "· cache API"
    }

    var body: some View {
        SettingsCard(header: "Provider Topology") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(providerTopologyRatio)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(providerTopologyRatioColor)

                    Text(topologySourceCaption)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

                    Spacer(minLength: 0)

                    if topology.healthProbeBusy { ProgressView().controlSize(.mini) }

                    Button {
                        state.refreshStatusNow(live: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(topology.healthProbeBusy || state.routerStatus != .ready)
                    .help("Làm mới trạng thái provider")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                OverviewUsageMetricsBar(
                    period: usage.usagePeriod,
                    stats: usage.usageStats,
                    onSelect: { state.setUsagePeriod($0) }
                )
                .equatable()

                ZStack {
                    if state.routerStatus != .ready {
                        Text("Bật 9Router để xem topology")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    } else if topologyProviders.isEmpty {
                        Text(topology.healthProbeBusy ? "Đang tải…" : "Chưa có provider")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    } else {
                        ComboTopologyGraph(
                            comboName: "9Router",
                            providers: topologyProviders,
                            recentUsage: usage.recentUsage,
                            activeProviders: usage.activeUsageProviders,
                            activeModels: usage.activeUsageModels,
                            lastProvider: usage.lastUsageProvider,
                            errorProvider: usage.errorUsageProvider
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.07, green: 0.08, blue: 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 0))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OverviewRecentCard: View {
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var topology: TopologyStore

    private var comboKeys: Set<String> {
        Set(topology.pathHealth.providers.flatMap { item -> [String] in
            let mid = item.model
            let short = mid.split(separator: "/").last.map(String.init) ?? mid
            return [mid.lowercased(), short.lowercased()]
        })
    }

    var body: some View {
        SettingsCard(header: "Recent Requests") {
            VStack(alignment: .leading, spacing: 0) {
                if usage.recentUsage.isEmpty {
                    Text("Chưa có request.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(usage.recentUsage.prefix(18)) { row in
                                recentRow(row)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recentRow(_ row: UsageRequestItem) -> some View {
        let hit = matches(row.model)
        let ok = row.status.lowercased() == "ok"
        return HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.model)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.provider)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.38))
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(Color.white.opacity(0.2))
                    // IN cam · OUT xanh — không cần header cột
                    Text("\(ComboFormat.tokens(row.promptTokens))↑")
                        .foregroundStyle(Color.orange)
                    Text("\(ComboFormat.tokens(row.completionTokens))↓")
                        .foregroundStyle(Color.green)
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
            }

            Spacer(minLength: 4)

            Text(ComboFormat.relativeTime(row.timestamp))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.35))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hit ? Color.orange.opacity(0.08) : Color.clear)
    }

    private func matches(_ model: String) -> Bool {
        let m = model.lowercased()
        if comboKeys.contains(m) { return true }
        return comboKeys.contains { m.hasSuffix($0) || $0.hasSuffix(m) }
    }
}

enum ComboActivity {
    enum Level { case idle, warm, live, error }

    /// Khớp 9Router Topology:
    /// LIVE = `activeRequests[].provider` · WARM = `recentRequests[0].provider` · ERROR = `errorProvider`.
    static func levels(
        for providers: [ProviderHealthItem],
        activeProviders: Set<String>,
        activeModels: Set<String>,
        lastProvider: String,
        errorProvider: String,
        recent: [UsageRequestItem]
    ) -> [String: Level] {
        var out: [String: Level] = [:]
        out.reserveCapacity(providers.count)
        let active = Set(activeProviders.map { $0.lowercased() })
        let activeModelSet = Set(activeModels.map { $0.lowercased() })
        let last = lastProvider.lowercased()
        let err = errorProvider.lowercased()

        for item in providers {
            let keys = providerKeys(for: item)
            let mapKey = item.provider.isEmpty ? item.model : item.provider
            if !err.isEmpty, keys.contains(err) {
                out[mapKey] = .error
                continue
            }
            if keys.contains(where: { active.contains($0) }) || activeModelMatches(item, activeModelSet) {
                out[mapKey] = .live
                continue
            }
            if !last.isEmpty, keys.contains(last) {
                out[mapKey] = .warm
                continue
            }
            // Fallback: model từng xuất hiện trong recent ≤10 phút
            if let age = newestOk(recent, matching: { matches($0, item: item) }), age <= 600 {
                out[mapKey] = .warm
                continue
            }
            out[mapKey] = .idle
        }
        return out
    }

    static func activeModelMatches(_ item: ProviderHealthItem, _ activeModels: Set<String>) -> Bool {
        guard !activeModels.isEmpty else { return false }
        let full = item.model.lowercased()
        let short = (item.model.split(separator: "/").last.map(String.init) ?? item.model).lowercased()
        for am in activeModels {
            if modelLoose(am, full: full, short: short) { return true }
        }
        return false
    }

    static func providerKeys(for item: ProviderHealthItem) -> Set<String> {
        var keys = Set<String>()
        let prov = item.provider.lowercased()
        let prefix = (item.model.split(separator: "/").first.map(String.init) ?? "").lowercased()
        if !prov.isEmpty { keys.insert(prov) }
        if !prefix.isEmpty { keys.insert(prefix) }
        let aliases: [String: [String]] = [
            "ag": ["antigravity"],
            "antigravity": ["ag"],
            "tr": ["tokenrouter", "trouter"],
            "tokenrouter": ["tr", "trouter"],
            "cu": ["cursor"],
            "cursor": ["cu"],
            "cx": ["codex"],
            "codex": ["cx"],
            "kiraai": ["kira"],
            "agentrouter": ["agentrouter"],
            "mmf": ["mimo"],
            ".ai": ["ai"],
            "ai": [".ai"]
        ]
        for k in Array(keys) {
            if let list = aliases[k] {
                for a in list { keys.insert(a) }
            }
        }
        return keys
    }

    private static func newestOk(_ recent: [UsageRequestItem], matching: (UsageRequestItem) -> Bool) -> TimeInterval? {
        for row in recent where matching(row) {
            let st = row.status.lowercased()
            guard st == "ok" || st.isEmpty else { continue }
            if let d = ComboFormat.parseISO(row.timestamp) {
                return max(0, Date().timeIntervalSince(d))
            }
        }
        return nil
    }

    private static func matches(_ row: UsageRequestItem, item: ProviderHealthItem) -> Bool {
        let rm = row.model.lowercased()
        let rp = row.provider.lowercased()
        let full = item.model.lowercased()
        let parts = item.model.split(separator: "/").map(String.init)
        let short = (parts.last ?? item.model).lowercased()
        let keys = providerKeys(for: item)

        if !rp.isEmpty, keys.contains(rp) {
            if rm.isEmpty { return true }
            return modelLoose(rm, full: full, short: short)
        }
        guard modelLoose(rm, full: full, short: short) else { return false }
        return !rp.isEmpty && keys.contains(where: { rp == $0 || rp.contains($0) || $0.contains(rp) })
    }

    private static func modelLoose(_ rm: String, full: String, short: String) -> Bool {
        if rm.isEmpty { return false }
        if rm == full || rm == short { return true }
        if full.hasSuffix("/" + rm) { return true }
        if rm.hasSuffix("/" + short) || rm.hasSuffix(short) { return true }
        if short.count >= 6, rm.hasPrefix(short), let c = rm.dropFirst(short.count).first, c == "-" || c == "/" {
            return true
        }
        if rm.count >= 6, short.hasPrefix(rm), let c = short.dropFirst(rm.count).first, c == "-" || c == "/" {
            return true
        }
        return false
    }
}

/// Topology radial kiểu 9Router — cubic edges uyển chuyển; animate dash/particle khi live/warm.
private struct TopologyGridBackground: View, Equatable {
    let size: CGSize

    var body: some View {
        Canvas { ctx, canvasSize in
            let step: CGFloat = 26
            var p = Path()
            var x: CGFloat = 0
            while x <= canvasSize.width {
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: canvasSize.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= canvasSize.height {
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: canvasSize.width, y: y))
                y += step
            }
            ctx.stroke(p, with: .color(.white.opacity(0.04)), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// Topology radial kiểu 9Router — cubic edges uyển chuyển; animate dash/particle khi live/warm.
struct ComboTopologyGraph: View {
    struct Node: Identifiable {
        let id: String
        let title: String
        let model: String
        let statusText: String
        let statusColor: Color
        let symbol: String
        let activity: ComboActivity.Level
        let connected: Bool
        let accent: Color
        let help: String
        let enabled: Bool
    }

    private struct EdgeGeometry {
        let index: Int
        let node: Node
        let from: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let to: CGPoint
        let path: Path
    }

    let comboName: String
    let providers: [ProviderHealthItem]
    let recentUsage: [UsageRequestItem]
    let activeProviders: Set<String>
    let activeModels: Set<String>
    let lastProvider: String
    let errorProvider: String

    @State private var zoom: CGFloat = 1.0
    @State private var cachedNodes: [Node] = []

    /// Hiện đủ model trong combo 9Router (kể cả Cursor/Codex trong list).
    private var visibleProviders: [ProviderHealthItem] { providers }

    private var nodesInputKey: String {
        let provFP = providers.map {
            "\($0.provider)|\($0.displayName)|\($0.model)|\($0.testStatus)|\($0.usable)|\($0.active)"
        }.joined(separator: ";")
        let actFP = ComboActivity.levels(
            for: visibleProviders,
            activeProviders: activeProviders,
            activeModels: activeModels,
            lastProvider: lastProvider,
            errorProvider: errorProvider,
            recent: recentUsage
        ).map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
        return "\(provFP)#\(actFP)"
    }

    static func isIDEProvider(_ item: ProviderHealthItem) -> Bool {
        let prefix = (item.model.split(separator: "/").first.map(String.init) ?? item.provider).lowercased()
        return isIDEProvider(prefix: prefix, provider: item.provider.lowercased())
    }

    static func isIDEProvider(prefix: String, provider: String) -> Bool {
        let idePrefixes: Set<String> = ["cu", "cursor", "cx", "codex"]
        if idePrefixes.contains(prefix) { return true }
        if idePrefixes.contains(provider) { return true }
        if provider == "cursor" || provider == "codex" { return true }
        return false
    }

    private var anyLive: Bool { cachedNodes.contains { $0.activity == .live } }

    private func buildNodes() -> [Node] {
        let acts = ComboActivity.levels(
            for: visibleProviders,
            activeProviders: activeProviders,
            activeModels: activeModels,
            lastProvider: lastProvider,
            errorProvider: errorProvider,
            recent: recentUsage
        )
        return visibleProviders.enumerated().map { idx, item in
            let act = acts[item.provider] ?? acts[item.model] ?? .idle
            let prefix = item.provider.isEmpty
                ? (item.model.split(separator: "/").first.map(String.init) ?? item.model)
                : item.provider
            // Model thật từ connection (defaultModel / modelLock) — không hiện lại provider id.
            let modelSubtitle = topologyModelSubtitle(item)
            let (st, sc) = statusLabel(item)
            let connected = item.usable || st == "OK"
            let enabled = item.active || item.usable
            let nodeId = item.provider.isEmpty ? (item.model.isEmpty ? "p\(idx)" : item.model) : item.provider
            return Node(
                id: nodeId,
                title: nodeTitle(item, prefix: prefix),
                model: modelSubtitle,
                statusText: st,
                statusColor: sc,
                symbol: symbol(for: prefix.isEmpty ? item.provider : prefix),
                activity: act,
                connected: connected,
                accent: accent(idx: idx, level: act, enabled: enabled),
                help: help(item, act),
                enabled: enabled
            )
        }
    }

    /// Subtitle model trên node topology — bỏ qua khi model trùng provider id.
    private func topologyModelSubtitle(_ item: ProviderHealthItem) -> String {
        let raw = item.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let prov = item.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.lowercased() != prov.lowercased() else { return "" }
        if let slash = raw.lastIndex(of: "/") {
            let tail = String(raw[raw.index(after: slash)...])
            return tail.isEmpty ? raw : tail
        }
        return raw
    }

    /// Tên node từ DB (providerNodes.displayName) — fallback prefix model, không catalog cứng.
    private func nodeTitle(_ item: ProviderHealthItem, prefix: String) -> String {
        let d = item.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { return d }
        let n = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // name connection thường là email — bỏ qua
        if !n.isEmpty, !n.contains("@"), !n.contains("|") { return n }
        return prefix
    }

    var body: some View {
        GeometryReader { geo in
            // Snap size → tránh node nhảy khi sibling (Recent/SSE) làm GeometryReader dao động 1–2pt.
            let size = CGSize(
                width: (geo.size.width / 2).rounded() * 2,
                height: (geo.size.height / 2).rounded() * 2
            )
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let list = cachedNodes
            let pillW: CGFloat = list.count >= 10 ? 118 : 128
            let pillH: CGFloat = list.contains(where: { !$0.model.isEmpty }) ? 42 : 34
            let spots = layoutSpots(count: list.count, size: size, zoom: zoom, pillW: pillW, pillH: pillH)
            let hubInset: CGFloat = 32
            let nodeInset: CGFloat = pillW * 0.45
            let edges = buildEdges(
                list: list,
                spots: spots,
                center: center,
                hubInset: hubInset,
                nodeInset: nodeInset
            )
            let needsMotion = list.contains { $0.activity == .live }

            ZStack {
                TopologyGridBackground(size: size)
                    .equatable()

                // Layer tĩnh: idle/warm/error vẽ 1 lần mỗi lần layout đổi.
                staticEdgesCanvas(edges: edges, size: size)

                // Layer động: chỉ animate line live để giảm redraw toàn bộ topology.
                if needsMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: false)) { context in
                        liveEdgesCanvas(
                            edges: edges,
                            size: size,
                            phase: context.date.timeIntervalSinceReferenceDate
                        )
                    }
                }

                ForEach(Array(list.enumerated()), id: \.element.id) { idx, n in
                    pill(n)
                        .position(spots[idx])
                        .help(n.help)
                }

                hub(glow: anyLive || list.contains { $0.activity == .warm || $0.activity == .error }).position(center)

                VStack(spacing: 6) {
                    zoomBtn("plus") { zoom = min(1.35, zoom + 0.08) }
                    zoomBtn("minus") { zoom = max(0.55, zoom - 0.08) }
                    zoomBtn("arrow.up.left.and.arrow.down.right") { zoom = 1 }
                }
                .position(x: 26, y: size.height - 58)
            }
            .frame(width: size.width, height: size.height)
        }
        .clipShape(Rectangle())
        .transaction { $0.animation = nil }
        .task(id: nodesInputKey) {
            cachedNodes = buildNodes()
        }
        .onChange(of: providers.count) { _, _ in zoom = 1 }
    }

    private func buildEdges(
        list: [Node],
        spots: [CGPoint],
        center: CGPoint,
        hubInset: CGFloat,
        nodeInset: CGFloat
    ) -> [EdgeGeometry] {
        var edges: [EdgeGeometry] = []
        edges.reserveCapacity(list.count)
        for (idx, n) in list.enumerated() {
            guard idx < spots.count else { continue }
            let (a, b) = edgeAnchor(from: center, to: spots[idx], fromInset: hubInset, toInset: nodeInset)
            let (c1, c2) = cubicControls(from: a, to: b, hub: center)
            var path = Path()
            path.move(to: a)
            path.addCurve(to: b, control1: c1, control2: c2)
            edges.append(
                EdgeGeometry(
                    index: idx,
                    node: n,
                    from: a,
                    control1: c1,
                    control2: c2,
                    to: b,
                    path: path
                )
            )
        }
        return edges
    }

    private func staticEdgesCanvas(edges: [EdgeGeometry], size: CGSize) -> some View {
        Canvas { ctx, _ in
            for edge in edges {
                switch edge.node.activity {
                case .idle:
                    ctx.stroke(
                        edge.path,
                        with: .color(.white.opacity(edge.node.connected ? 0.12 : 0.05)),
                        lineWidth: 1.1
                    )
                case .warm:
                    ctx.stroke(edge.path, with: .color(Color.orange.opacity(0.14)), lineWidth: 4.5)
                    ctx.stroke(edge.path, with: .color(Color.orange.opacity(0.82)), lineWidth: 1.6)
                case .live:
                    // Live được render ở layer động riêng để tránh vẽ lại toàn bộ line tĩnh.
                    break
                case .error:
                    ctx.stroke(edge.path, with: .color(Color.red.opacity(0.14)), lineWidth: 4.5)
                    ctx.stroke(edge.path, with: .color(Color.red.opacity(0.9)), lineWidth: 1.6)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func liveEdgesCanvas(edges: [EdgeGeometry], size: CGSize, phase: TimeInterval) -> some View {
        Canvas { ctx, _ in
            let liveColor = Color(red: 0.20, green: 0.88, blue: 0.78)
            let dashPhase = CGFloat(phase * -30)
            for edge in edges where edge.node.activity == .live {
                ctx.stroke(edge.path, with: .color(liveColor.opacity(0.18)), lineWidth: 5.5)
                ctx.stroke(
                    edge.path,
                    with: .color(liveColor),
                    style: StrokeStyle(lineWidth: 1.9, lineCap: .round, dash: [5.5, 7.5], dashPhase: dashPhase)
                )

                // Dot nhỏ chạy dọc theo cung để giữ cảm giác "live" nhưng nhẹ GPU hơn glow lớn.
                let t = CGFloat((phase * 0.4 + Double(edge.index) * 0.17).truncatingRemainder(dividingBy: 1))
                let pt = cubic(edge.from, edge.control1, edge.control2, edge.to, t)
                let dot = Path(ellipseIn: CGRect(x: pt.x - 2.0, y: pt.y - 2.0, width: 4.0, height: 4.0))
                ctx.fill(dot, with: .color(liveColor))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// Một vòng quanh tâm (kiểu 9Router): góc đều, bán kính tự theo số node để không đè.
    private func layoutSpots(count: Int, size: CGSize, zoom: CGFloat, pillW: CGFloat, pillH: CGFloat) -> [CGPoint] {
        let n = max(count, 1)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        let maxRx = max(56, size.width / 2 - pillW / 2 - 18) * zoom
        let maxRy = max(48, size.height / 2 - pillH / 2 - 16) * zoom

        // Bán kính tối thiểu để khoảng cách 2 node kề ≥ bề ngang card + gap
        let gap: CGFloat = 14
        let needR: CGFloat = n <= 1 ? 0 : (pillW + gap) / (2 * sin(.pi / CGFloat(n)))

        // Ellipse ngang nhẹ; luôn 1 vòng — ưu tiên đủ chỗ (needR), không vượt khung.
        var rx = min(maxRx, max(needR, maxRx * 0.78))
        var ry = min(maxRy, max(needR * 0.82, maxRy * 0.78))
        if needR > 0 {
            rx = min(maxRx, max(rx, needR))
            ry = min(maxRy, max(ry, needR * 0.85))
        }
        // Thu nhẹ để không sát mép
        rx = min(rx, maxRx * 0.96)
        ry = min(ry, maxRy * 0.96)

        var spots: [CGPoint] = []
        spots.reserveCapacity(n)
        let phase = -CGFloat.pi / 2 // đỉnh vòng = node đầu
        for i in 0..<n {
            let ang = phase + 2 * CGFloat.pi * CGFloat(i) / CGFloat(n)
            spots.append(CGPoint(x: center.x + cos(ang) * rx, y: center.y + sin(ang) * ry))
        }
        return spots
    }

    /// Điểm neo line: lùi khỏi tâm hub / tâm card → đường nối vào mép như 9Router.
    private func edgeAnchor(from: CGPoint, to: CGPoint, fromInset: CGFloat, toInset: CGFloat) -> (CGPoint, CGPoint) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let len = max(hypot(dx, dy), 1)
        let ux = dx / len
        let uy = dy / len
        let a = CGPoint(x: from.x + ux * fromInset, y: from.y + uy * fromInset)
        let b = CGPoint(x: to.x - ux * toInset, y: to.y - uy * toInset)
        return (a, b)
    }

    private func zoomBtn(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: s)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func hub(glow: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.orange).frame(width: 20, height: 20)
                Text("9").font(.system(size: 12, weight: .black, design: .rounded)).foregroundStyle(.black)
            }
            Text(comboName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.14, green: 0.15, blue: 0.17))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.orange, lineWidth: 1.6))
        .shadow(color: Color.orange.opacity(glow ? 0.65 : 0.28), radius: glow ? 16 : 8)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// Card: icon + tên + model + status (chấm + text ngắn từ testStatus thật).
    private func pill(_ n: Node) -> some View {
        let dim = n.activity == .idle && (!n.enabled || !n.connected)
        let live = n.activity == .live
        let warm = n.activity == .warm
        let err = n.activity == .error
        let liveColor = Color(red: 0.20, green: 0.88, blue: 0.78)
        let tint: Color = live ? liveColor : (err ? .red : (warm ? .orange : n.accent))
        return HStack(spacing: 6) {
            Image(systemName: n.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(dim ? Color.white.opacity(0.35) : tint)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(n.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(dim ? 0.4 : 0.95))
                    .lineLimit(1)
                if !n.model.isEmpty {
                    Text(n.model)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(dim ? 0.28 : 0.5))
                        .lineLimit(1)
                        .frame(maxWidth: 96, alignment: .leading)
                }
            }

            VStack(spacing: 2) {
                Circle()
                    .fill(dim ? Color.white.opacity(0.25) : n.statusColor)
                    .frame(width: 6, height: 6)
                Text(n.statusText)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(dim ? Color.white.opacity(0.3) : n.statusColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(red: 0.14, green: 0.15, blue: 0.17).opacity(dim ? 0.75 : 1))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    live ? liveColor :
                    err ? Color.red :
                    warm ? Color.orange.opacity(0.7) :
                    Color.white.opacity(dim ? 0.08 : 0.14),
                    lineWidth: (live || err) ? 1.6 : 1
                )
        )
        .shadow(color: live ? liveColor.opacity(0.45) : (err ? Color.red.opacity(0.35) : .clear), radius: 8)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(dim ? 0.55 : 1)
    }

    private func statusLabel(_ item: ProviderHealthItem) -> (String, Color) {
        // Badge luôn là health/probe — traffic gần đây chỉ hiện bằng viền/glow (live/warm).
        if item.live {
            if item.usable { return ("OK", .green) }
            if let code = item.errorCode { return ("\(code)", .orange) }
            return ("Fail", .orange)
        }
        if item.usable { return ("OK", .green) }
        if item.testStatus == "stale" { return ("Cache", .yellow) }
        if item.testStatus == "unknown" || item.lastError.localizedCaseInsensitiveContains("no matching") {
            return ("N/A", Color(nsColor: .tertiaryLabelColor))
        }
        if let code = item.errorCode { return ("\(code)", .orange) }
        if !item.lastError.isEmpty { return ("Lỗi", .orange) }
        if item.testStatus == "inactive" || !item.active { return ("Off", Color(nsColor: .tertiaryLabelColor)) }
        return ("?", Color(nsColor: .tertiaryLabelColor))
    }

    /// Cubic lệch nhẹ ra ngoài hub — cong vừa, không đẩy line lệch khỏi node.
    private func cubicControls(from a: CGPoint, to b: CGPoint, hub: CGPoint) -> (CGPoint, CGPoint) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let ux = dx / len
        let uy = dy / len
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        var ox = mid.x - hub.x
        var oy = mid.y - hub.y
        let olen = hypot(ox, oy)
        if olen > 1 {
            ox /= olen
            oy /= olen
        } else {
            ox = -uy
            oy = ux
        }
        let tx = -uy
        let ty = ux
        let side: CGFloat = ((mid.x - hub.x) * tx + (mid.y - hub.y) * ty) >= 0 ? 1 : -1
        let bulge = min(52, max(16, len * 0.2))
        let sway = min(14, max(4, len * 0.06)) * side
        let c1 = CGPoint(
            x: a.x + ux * len * 0.31 + ox * bulge + tx * sway,
            y: a.y + uy * len * 0.31 + oy * bulge + ty * sway
        )
        let c2 = CGPoint(
            x: a.x + ux * len * 0.69 + ox * bulge * 0.86 - tx * sway * 0.45,
            y: a.y + uy * len * 0.69 + oy * bulge * 0.86 - ty * sway * 0.45
        )
        return (c1, c2)
    }

    private func cubic(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let tt = t * t
        let uu = u * u
        return CGPoint(
            x: uu * u * a.x + 3 * uu * t * c1.x + 3 * u * tt * c2.x + tt * t * b.x,
            y: uu * u * a.y + 3 * uu * t * c1.y + 3 * u * tt * c2.y + tt * t * b.y
        )
    }

    private func accent(idx: Int, level: ComboActivity.Level, enabled: Bool) -> Color {
        let palette: [Color] = [
            .orange,
            Color(red: 0.95, green: 0.32, blue: 0.42),
            Color(red: 0.25, green: 0.85, blue: 0.75),
            Color(red: 0.4, green: 0.6, blue: 1),
            Color(red: 0.95, green: 0.7, blue: 0.25)
        ]
        let c = palette[idx % palette.count]
        if !enabled { return Color.white.opacity(0.25) }
        switch level {
        case .warm, .live: return .orange
        case .error: return .red
        case .idle: return c
        }
    }

    private func pretty(_ raw: String) -> String {
        let map: [String: String] = [
            "cu": "Cursor IDE", "cx": "OpenAI Codex", "ag": "Antigravity",
            "tr": "TokenRouter", "mmf": "MiMo Code Free", "kiraai": "Kira",
            "openrouter": "OpenRouter", "agentrouter": "AgentRouter",
            "trouterchat": "trouterchat", "tokenrouter": "TokenRouter",
            "trouter": "trouter", ".ai": ".AI", "ai": ".AI"
        ]
        return map[raw.lowercased()] ?? raw
    }

    private func symbol(for prefix: String) -> String {
        switch prefix.lowercased() {
        case "cu", "cursor": return "laptopcomputer"
        case "cx", "codex": return "terminal"
        case "ag": return "sparkles"
        case "openrouter": return "globe"
        case "agentrouter": return "bolt.horizontal"
        case "tr", "tokenrouter", "trouterchat", "trouter": return "arrow.triangle.branch"
        case "kiraai": return "star.fill"
        case "mmf": return "cpu"
        default: return "circle.grid.cross"
        }
    }

    private func help(_ item: ProviderHealthItem, _ level: ComboActivity.Level) -> String {
        let t: String = {
            switch level {
            case .live: return " · LIVE"
            case .warm: return " · vừa dùng"
            case .error: return " · lỗi"
            case .idle: return ""
            }
        }()
        let title = item.displayName.isEmpty ? item.provider : item.displayName
        let model = topologyModelSubtitle(item)
        let head = model.isEmpty ? title : "\(title) · \(model)"
        if item.usable { return "\(head) · OK\(t)" }
        if item.testStatus == "stale" { return "\(head) · Cache\(t)" }
        if let code = item.errorCode { return "\(head) · [\(code)] \(item.lastError.isEmpty ? item.testStatus : item.lastError)\(t)" }
        return "\(head) · \(item.lastError.isEmpty ? (item.testStatus.isEmpty ? "Lỗi" : item.testStatus) : item.lastError)\(t)"
    }
}

enum ComboFormat {
    static func tokens(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func cost(_ v: Double) -> String {
        String(format: "~$%.2f", v)
    }

    static func parseISO(_ iso: String) -> Date? {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: iso) { return d }
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        return b.date(from: iso)
    }

    static func relativeTime(_ iso: String) -> String {
        guard let date = parseISO(iso) else { return "—" }
        let sec = max(0, Int(Date().timeIntervalSince(date)))
        if sec < 60 { return "\(sec)s" }
        if sec < 3600 { return "\(sec / 60)m" }
        if sec < 86400 { return "\(sec / 3600)h" }
        return "\(sec / 86400)d"
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
            SquircleIcon(symbol: icon, color: badgeColor, size: 36, inner: 15, radius: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(value)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .lineLimit(1)
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(badgeColor.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tab: Backup & Restore

struct BackupView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    symbol: AppState.Section.backup.icon,
                    color: AppState.Section.backup.accentColor,
                    title: "Backup & Restore",
                    subtitle: "Lưu cấu hình 9Router và AI Gate ra file — mang sang máy khác rồi Import."
                )

                SettingsCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Backup gồm: 9Router, proxy, combo Cursor/Codex. Sau Import app tự apply lại cấu hình.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))

                        HStack(spacing: 12) {
                            Button { state.exportBackup() } label: {
                                Label("Backup", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.backupBusy)

                            Button { state.importBackup() } label: {
                                Label("Import", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.bordered)
                            .disabled(state.backupBusy)
                        }

                        if state.backupBusy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(state.backupMessage.isEmpty ? "Đang xử lý..." : state.backupMessage)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            }
                        } else if !state.backupMessage.isEmpty {
                            Text(state.backupMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }
                    }
                    .padding(16)
                }
            }
            .padding(24)
        }
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
                Text("Cursor không gọi được localhost — request đi qua Cursor cloud. Bật «Dùng với Cursor» ở Overview (Tailscale Funnel), rồi Apply để ghi Base URL https://….ts.net/v1 + API key 9Router.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Mở Cursor Info") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        state.selectedSection = .overview
                        state.showCursorDetails = true
                    }
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
    @EnvironmentObject private var logsStore: LogsStore
    @State private var selectedLevel: LogLevel = .all
    @State private var searchKeyword: String = ""
    @State private var debouncedSearchKeyword: String = ""
    @State private var expandedLogId: UUID? = nil
    @State private var filteredLogs: [LogEntry] = []
    @State private var levelCounts: [LogLevel: Int] = [:]
    @State private var searchDebounceTask: Task<Void, Never>?

    private func recomputeLogCache() {
        let query = debouncedSearchKeyword.trimmingCharacters(in: .whitespaces).lowercased()
        filteredLogs = logsStore.logs.filter { entry in
            let matchesLevel = (selectedLevel == .all) || (entry.level == selectedLevel)
            let matchesQuery = query.isEmpty
                || entry.message.lowercased().contains(query)
                || entry.source.lowercased().contains(query)
                || (entry.detail?.lowercased().contains(query) ?? false)
            return matchesLevel && matchesQuery
        }
        var counts: [LogLevel: Int] = [.all: logsStore.logs.count]
        for lvl in LogLevel.allCases where lvl != .all {
            counts[lvl] = logsStore.logs.filter { $0.level == lvl }.count
        }
        levelCounts = counts
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
                                let count = levelCounts[lvl] ?? 0
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
        .onAppear { recomputeLogCache() }
        .onReceive(logsStore.$logs) { _ in recomputeLogCache() }
        .onChange(of: selectedLevel) { _, _ in recomputeLogCache() }
        .onChange(of: debouncedSearchKeyword) { _, _ in recomputeLogCache() }
        .onChange(of: searchKeyword) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    debouncedSearchKeyword = newValue
                }
            }
        }
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
                    // Cursor
                    Button {
                        openMainWindow()
                        state.selectedSection = .overview
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            state.showCursorDetails = true
                        }
                    } label: {
                        menuServiceRow(
                            icon: cursorMenuIcon,
                            color: cursorMenuIconColor,
                            title: "Cursor",
                            subtitle: cursorMenuSubtitle,
                            subtitleCyan: cursorMenuSubtitleIsURL,
                            statusText: cursorMenuStatusText,
                            statusColor: cursorMenuStatusColor
                        )
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 46)

                    // Codex
                    menuServiceRow(
                        icon: "terminal.fill",
                        color: Color(red: 0.20, green: 0.70, blue: 0.45),
                        title: "Codex",
                        subtitle: "127.0.0.1:20128/v1",
                        statusText: state.testingCodex ? "Testing" : (state.codexTestOk == false ? "Fail" : (state.routerStatus == .ready ? "Running" : "Offline")),
                        statusColor: state.codexTestOk == false ? .orange : (state.routerStatus == .ready ? .green : .orange)
                    )

                    Divider().padding(.leading, 46)

                    // 9Router Gateway
                    menuServiceRow(
                        icon: "server.rack",
                        color: Color(red: 0.19, green: 0.68, blue: 0.60),
                        title: "9Router Gateway",
                        subtitle: "127.0.0.1:20128",
                        subtitleCyan: true,
                        statusText: state.routerStatus == .ready ? "Running" : "Offline",
                        statusColor: state.routerStatus == .ready ? .green : .orange
                    )

                    ForEach(state.activeProxies) { p in
                        Divider().padding(.leading, 46)
                        menuServiceRow(
                            icon: p.iconName,
                            color: Color(red: 0.38, green: 0.34, blue: 0.93),
                            title: p.name,
                            subtitle: "127.0.0.1:\(p.port)",
                            statusText: p.status == .ready ? "Running" : "Offline",
                            statusColor: p.status == .ready ? .green : .orange
                        )
                    }
                }
            }

            // Actions Card Group
            SettingsCard(header: "Quick Actions") {
                VStack(spacing: 0) {
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

                    Divider().padding(.leading, 44)

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

                    Divider().padding(.leading, 44)

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

    private func menuServiceRow(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        subtitleCyan: Bool = false,
        statusText: String,
        statusColor: Color
    ) -> some View {
        HStack(spacing: 10) {
            SquircleIcon(symbol: icon, color: color, size: 26, inner: 12, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(subtitleCyan ? Color.cyan : Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            StatusPill(text: statusText, color: statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var cursorOn: Bool {
        state.bridgeStatus.wanted || state.bridgeStatus.isReady
    }

    private var cursorMenuStatusText: String {
        if state.bridgeBusy || state.bridgeSetupRunning || state.bridgeStatus.isRecovering { return "Setup" }
        if !cursorOn { return "Off" }
        if state.pathHealth.cursorPathOk { return "Running" }
        return "Check"
    }

    private var cursorMenuStatusColor: Color {
        if !cursorOn { return .orange }
        if state.pathHealth.cursorPathOk { return .green }
        return .orange
    }

    private var cursorMenuSubtitle: String {
        if state.bridgeBusy || state.bridgeSetupRunning { return "Đang setup…" }
        if cursorOn {
            if !state.bridgeStatus.baseUrl.isEmpty { return state.bridgeStatus.baseUrl }
            return state.bridgeStatus.message.isEmpty ? "Funnel" : state.bridgeStatus.message
        }
        return "FUNNEL · tắt"
    }

    private var cursorMenuSubtitleIsURL: Bool {
        cursorOn && state.bridgeStatus.baseUrl.hasPrefix("http")
    }

    private var cursorMenuIcon: String {
        if state.bridgeBusy || state.bridgeSetupRunning { return "arrow.triangle.2.circlepath" }
        if state.pathHealth.cursorPathOk { return "checkmark.circle.fill" }
        if cursorOn { return "link.circle.fill" }
        return "link.circle"
    }

    private var cursorMenuIconColor: Color {
        if state.pathHealth.cursorPathOk { return .green }
        if cursorOn { return .orange }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private func openMainWindow() {
        if let window = AppWindow.main() {
            AppWindow.present(window, fillScreen: true)
            return
        }
        openWindow(id: "main")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            AppWindow.present(fillScreen: true)
        }
    }
}
