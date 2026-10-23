// Codex 额度指针 · macOS 菜单栏 App
// Reads the local Codex quota (codex app-server, read-only) and drives the
// ESP32 "CodexGauge" over Bluetooth LE. Lives in the menu bar, no Dock icon.
import SwiftUI
import CoreBluetooth
import ServiceManagement

// MARK: - Language

/// UI language: "en" (default) or "zh". Changing it re-renders every view.
var appLang = UserDefaults.standard.string(forKey: "lang") ?? "en"
func t(_ en: String, _ zh: String) -> String { appLang == "zh" ? zh : en }

// MARK: - Constants

let deviceName = "CodexGauge"
let serviceUUID = CBUUID(string: "6e400001-c0de-4a11-9a5e-000000000001")
let rxUUID = CBUUID(string: "6e400002-c0de-4a11-9a5e-000000000001")
let txUUID = CBUUID(string: "6e400003-c0de-4a11-9a5e-000000000001")

enum QuotaWindow: String, CaseIterable, Identifiable {
    case mostRestrictive = "most-restrictive", primary, secondary
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mostRestrictive: return t("Lower of the two", "两者取小")
        case .primary: return t("5-hour window", "5 小时窗口")
        case .secondary: return t("Weekly limit", "每周额度")
        }
    }
}

struct WindowInfo { var remaining: Double; var resetsAt: Date? }
struct Quota { var primary: WindowInfo?; var secondary: WindowInfo?; var readAt: Date }

struct GaugeError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Codex quota (JSON-RPC over `codex app-server --stdio`)

final class QuotaService {
    private var proc: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var waiting: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private let queue = DispatchQueue(label: "quota")

    static func findCodex() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func start() throws {
        guard let path = QuotaService.findCodex() else { throw GaugeError(t("Codex not found (install the ChatGPT desktop app or the codex CLI)", "找不到 Codex（需要已安装 ChatGPT 桌面版或 codex 命令行）")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["app-server", "--stdio"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            self?.queue.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.failAll(GaugeError(t("Codex process exited", "Codex 进程已退出"))) ; self?.proc = nil }
        }
        try p.run()
        proc = p; stdin = inPipe.fileHandleForWriting
    }

    private func consume(_ d: Data) {
        if d.isEmpty { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int, let cb = waiting.removeValue(forKey: id) else { continue }
            if let err = obj["error"] as? [String: Any] {
                cb(.failure(GaugeError((err["message"] as? String) ?? t("Codex returned an error", "Codex 返回错误"))))
            } else {
                cb(.success((obj["result"] as? [String: Any]) ?? [:]))
            }
        }
    }

    private func failAll(_ e: Error) {
        let w = waiting; waiting = [:]
        w.values.forEach { $0(.failure(e)) }
    }

    private func send(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try stdin?.write(contentsOf: data)
    }

    private func request(_ method: String, _ params: [String: Any]? = nil, timeout: Double = 25) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.nextID += 1
                let id = self.nextID
                var done = false
                self.waiting[id] = { r in if !done { done = true; cont.resume(with: r) } }
                var msg: [String: Any] = ["id": id, "method": method]
                if let params { msg["params"] = params }
                do { try self.send(msg) } catch {
                    self.waiting.removeValue(forKey: id); done = true; cont.resume(throwing: error); return
                }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let cb = self.waiting.removeValue(forKey: id) { cb(.failure(GaugeError(t("Timed out reading the Codex quota", "读取 Codex 额度超时")))) }
                }
            }
        }
    }

    private func ensureStarted() async throws {
        let running: Bool = queue.sync { proc?.isRunning ?? false }
        if running { return }
        try queue.sync { try start() }
        _ = try await request("initialize", ["clientInfo": ["name": "codex_gauge_mac", "title": "Codex Gauge", "version": "1.0.0"]])
        try queue.sync { try send(["method": "initialized", "params": [:]]) }
    }

    func read() async throws -> Quota {
        for attempt in 1...2 {
            do {
                try await ensureStarted()
                let r = try await request("account/rateLimits/read")
                return try parse(r)
            } catch {
                queue.sync { proc?.terminate(); proc = nil }
                if attempt == 2 { throw error }
            }
        }
        throw GaugeError(t("Read failed", "读取失败"))
    }

    private func parse(_ r: [String: Any]) throws -> Quota {
        var snap = r["rateLimits"] as? [String: Any]
        if let by = r["rateLimitsByLimitId"] as? [String: Any], let c = by["codex"] as? [String: Any] { snap = c }
        guard let s = snap else { throw GaugeError(t("No Codex quota data", "没有 Codex 额度数据")) }
        func win(_ k: String) -> WindowInfo? {
            guard let w = s[k] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return WindowInfo(remaining: max(0, min(100, 100 - used)), resetsAt: reset)
        }
        let q = Quota(primary: win("primary"), secondary: win("secondary"), readAt: Date())
        if q.primary == nil && q.secondary == nil { throw GaugeError(t("Quota windows unavailable", "额度窗口暂不可用")) }
        return q
    }

    func stop() { queue.sync { proc?.terminate(); proc = nil } }
}

// MARK: - Bluetooth LE link to the ESP32

final class BLELink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onState: ((String, Bool) -> Void)?
    var onReply: ((String) -> Void)?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var pending: [(String, CheckedContinuation<String, Error>)] = []
    private var current: (String, CheckedContinuation<String, Error>)?
    private var timeoutWork: DispatchWorkItem?
    private(set) var ready = false
    var wantConnection = true

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect() {
        wantConnection = true
        guard central.state == .poweredOn else { return }
        if ready { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        onState?(t("Searching for \(deviceName)…", "正在搜索 \(deviceName)…"), false)
        central.scanForPeripherals(withServices: [serviceUUID])
    }

    func disconnect() {
        wantConnection = false
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: if wantConnection { connect() }
        case .unauthorized: onState?(t("No Bluetooth permission: System Settings → Privacy & Security → Bluetooth", "没有蓝牙权限：系统设置 → 隐私与安全性 → 蓝牙"), false)
        case .poweredOff: onState?(t("Bluetooth is off", "Mac 蓝牙已关闭"), false)
        default: onState?(t("Bluetooth unavailable", "蓝牙不可用"), false)
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        c.stopScan()
        peripheral = p; p.delegate = self
        onState?(t("Connecting…", "正在连接…"), false)
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { lost(t("connection failed", "连接失败")) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { lost(t("disconnected", "已断开")) }

    private func lost(_ why: String) {
        ready = false; rx = nil
        failAll(GaugeError(t("Bluetooth \(why)", "蓝牙\(why)")))
        onState?(wantConnection ? t("\(why), reconnecting in 3 s", "\(why)，3 秒后重连") : t("Not connected", "未连接"), false)
        if wantConnection { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.connect() } }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == serviceUUID }) else { lost(t("service not found", "找不到服务")); return }
        p.discoverCharacteristics([rxUUID, txUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == rxUUID { rx = ch }
            if ch.uuid == txUUID { p.setNotifyValue(true, for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == txUUID && ch.isNotifying && rx != nil {
            ready = true
            onState?(t("Connected to \(p.name ?? deviceName)", "已连接 \(p.name ?? deviceName)"), true)
            pump()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == txUUID, let d = ch.value, let line = String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        onReply?(line)
        if let cur = current, line.hasPrefix("OK") || line.hasPrefix("ERR") || line.hasPrefix("STATUS") {
            timeoutWork?.cancel(); current = nil
            if line.hasPrefix("ERR") { cur.1.resume(throwing: GaugeError("ESP32: \(line)")) } else { cur.1.resume(returning: line) }
            pump()
        }
    }

    /// Sends one text command and waits for its OK/ERR/STATUS reply. Commands are serialised.
    func send(_ cmd: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                guard self.ready else { cont.resume(throwing: GaugeError(t("Bluetooth not connected", "蓝牙未连接"))); return }
                self.pending.append((cmd, cont)); self.pump()
            }
        }
    }

    private func pump() {
        guard current == nil, ready, let p = peripheral, let rx, !pending.isEmpty else { return }
        let item = pending.removeFirst(); current = item
        p.writeValue((item.0 + "\n").data(using: .ascii)!, for: rx, type: .withResponse)
        let w = DispatchWorkItem { [weak self] in
            guard let self, let cur = self.current, cur.0 == item.0 else { return }
            self.current = nil; cur.1.resume(throwing: GaugeError(t("No reply from ESP32: \(item.0)", "ESP32 没有回应：\(item.0)"))); self.pump()
        }
        timeoutWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    private func failAll(_ e: Error) {
        timeoutWork?.cancel()
        if let c = current { c.1.resume(throwing: e); current = nil }
        pending.forEach { $0.1.resume(throwing: e) }; pending = []
    }
}

// MARK: - App state

@MainActor
final class GaugeModel: ObservableObject {
    @Published var connText = t("Not connected", "未连接")
    @Published var connected = false
    @Published var quota: Quota?
    @Published var quotaError: String?
    @Published var lastSent: Double?
    @Published var lastSentAt: Date?
    @Published var calibrated = false
    @Published var devEmpty = 0
    @Published var devFull = 0
    @Published var devSpeed = 90
    @Published var devPulse = 1500
    @Published var log: [String] = []
    @Published var busy = false
    // Form state for the settings window.
    @Published var testPct = 50.0
    @Published var jog = 1500
    @Published var calEmpty = 730
    @Published var calFull = 2270
    @Published var calLoaded = false
    @Published var speedUI = 90.0
    @Published var loginOn = SMAppService.mainApp.status == .enabled

    // Persisted preferences.
    @Published var lang = appLang { didSet { appLang = lang; UserDefaults.standard.set(lang, forKey: "lang") } }
    @Published var showIcon = UserDefaults.standard.object(forKey: "showIcon") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showIcon, forKey: "showIcon") } }
    @Published var windowRaw = UserDefaults.standard.string(forKey: "window") ?? QuotaWindow.mostRestrictive.rawValue {
        didSet { UserDefaults.standard.set(windowRaw, forKey: "window") } }
    @Published var autoSync = UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSync, forKey: "autoSync") } }
    @Published var interval = UserDefaults.standard.object(forKey: "interval") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(interval, forKey: "interval"); nextRead = .distantPast } }

    let ble = BLELink()
    let quotaSvc = QuotaService()
    private var timer: Timer?
    private var nextRead = Date.distantPast

    var window: QuotaWindow { QuotaWindow(rawValue: windowRaw) ?? .mostRestrictive }

    init() {
        ble.onState = { [weak self] text, ok in
            Task { @MainActor in
                guard let self else { return }
                let was = self.connected
                self.connText = text; self.connected = ok
                if ok && !was { self.addLog(text); self.lastSent = nil; await self.refreshStatus(); self.nextRead = .distantPast }
                if !ok && was { self.addLog(text) }
            }
        }
        ble.onReply = { [weak self] line in Task { @MainActor in self?.addLog("← \(line)") } }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        ble.connect()
    }

    func addLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date())) \(s)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    var shownPercent: Double? {
        guard let q = quota else { return nil }
        switch window {
        case .primary: return q.primary?.remaining
        case .secondary: return q.secondary?.remaining
        case .mostRestrictive: return [q.primary?.remaining, q.secondary?.remaining].compactMap { $0 }.min()
        }
    }

    private func tick() {
        if Date() >= nextRead {
            nextRead = Date().addingTimeInterval(Double(max(10, interval)))
            Task { await refreshQuota(forceSend: false) }
        }
    }

    func refreshQuota(forceSend: Bool) async {
        do {
            let q = try await quotaSvc.read()
            quota = q; quotaError = nil
            await syncIfNeeded(force: forceSend)
        } catch {
            quotaError = error.localizedDescription
            if connected && autoSync { _ = try? await ble.send("STALE") }
        }
    }

    func syncIfNeeded(force: Bool) async {
        guard (autoSync || force), connected, calibrated, let pct = shownPercent else { return }
        // Resend every 5 min even if unchanged so the firmware keeps the data "fresh".
        let stale = lastSentAt.map { Date().timeIntervalSince($0) > 300 } ?? true
        if force || lastSent == nil || abs(pct - (lastSent ?? -99)) >= 0.5 || stale {
            if await cmd(String(format: "Q %.1f", pct)) != nil { lastSent = pct; lastSentAt = Date() }
        }
    }

    @discardableResult
    func cmd(_ c: String) async -> String? {
        addLog("→ \(c)")
        do {
            let r = try await ble.send(c)
            if r.hasPrefix("STATUS") { parseStatus(r) }
            return r
        } catch {
            addLog(t("Error: \(error.localizedDescription)", "错误：\(error.localizedDescription)")); return nil
        }
    }

    func refreshStatus() async { await cmd("STATUS") }

    private func parseStatus(_ line: String) {
        var m: [String: String] = [:]
        for part in line.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { m[String(kv[0])] = String(kv[1]) }
        }
        calibrated = m["cal"] == "1"
        devEmpty = Int(m["empty_us"] ?? "") ?? devEmpty
        devFull = Int(m["full_us"] ?? "") ?? devFull
        devSpeed = Int(Double(m["speed"] ?? "") ?? Double(devSpeed))
        devPulse = Int(Double(m["us"] ?? "") ?? Double(devPulse))
    }

    func pauseAuto() { if autoSync { autoSync = false; addLog(t("Auto sync paused for testing/calibration; turn it back on in the menu when done", "已暂停自动同步（测试/校准中），完成后在菜单里重新打开")) } }

    func test(_ pct: Double) async {
        guard calibrated else { addLog(t("Please calibrate first", "请先完成校准")); return }
        pauseAuto(); await cmd(String(format: "T %.1f", pct))
    }

    func pulse(_ us: Int) async {
        let v = min(2500, max(500, us)); devPulse = v
        pauseAuto(); await cmd("P \(v)")
    }

    func saveCal(empty: Int, full: Int) async -> Bool {
        guard (500...2500).contains(empty), (500...2500).contains(full), abs(empty - full) >= 200 else {
            addLog(t("Calibration values must be 500–2500 µs and at least 200 apart", "校准值需在 500–2500 µs 之间，且两端至少相差 200")); return false
        }
        let ok = await cmd("CAL \(empty) \(full)") != nil
        await refreshStatus()
        return ok
    }

    func setSpeed(_ v: Int) async { await cmd("SPEED \(min(400, max(10, v)))"); await refreshStatus() }

    func sweep() async {
        guard calibrated else { addLog(t("Please calibrate first", "请先完成校准")); return }
        pauseAuto(); busy = true
        let stroke = 139.4  // servo degrees for 0-100% on V5
        let wait = UInt64((stroke / 4 / Double(max(devSpeed, 10)) + 0.8) * 1_000_000_000)
        for q in [0, 25, 50, 75, 100, 75, 50, 25, 0, 50] {
            guard await cmd("T \(q)") != nil else { break }
            try? await Task.sleep(nanoseconds: wait)
        }
        busy = false
    }
}

// MARK: - Views

/// Menu bar glyph: a tiny white plate with a vertical tick scale and a red
/// arrow at the current percentage (grey when not connected).
func gaugeIcon(_ pct: Double?, connected: Bool) -> NSImage {
    let size = NSSize(width: 16, height: 18)
    let img = NSImage(size: size, flipped: false) { _ in
        let plate = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 15, height: 17), xRadius: 3, yRadius: 3)
        NSColor.white.setFill(); plate.fill()
        NSColor(calibratedWhite: 0.55, alpha: 1).setStroke(); plate.lineWidth = 0.75; plate.stroke()
        NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
        let base: CGFloat = 8, y0: CGFloat = 4, y1: CGFloat = 14
        NSBezierPath(rect: NSRect(x: base - 0.8, y: y0 - 0.4, width: 0.8, height: y1 - y0 + 0.8)).fill()
        for i in 0...4 {
            let y = y0 + (y1 - y0) * CGFloat(i) / 4
            let len: CGFloat = i % 2 == 0 ? 4.5 : 3
            NSBezierPath(rect: NSRect(x: base - len, y: y - 0.4, width: len, height: 0.8)).fill()
        }
        let ay = y0 + (y1 - y0) * CGFloat(min(100, max(0, pct ?? 50)) / 100)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: base + 0.6, y: ay))
        arrow.line(to: NSPoint(x: base + 4.2, y: ay + 2.3)); arrow.line(to: NSPoint(x: base + 4.2, y: ay + 1.0))
        arrow.line(to: NSPoint(x: 14.2, y: ay + 1.0)); arrow.line(to: NSPoint(x: 14.2, y: ay - 1.0))
        arrow.line(to: NSPoint(x: base + 4.2, y: ay - 1.0)); arrow.line(to: NSPoint(x: base + 4.2, y: ay - 2.3))
        arrow.close()
        (connected && pct != nil ? NSColor(calibratedRed: 0.89, green: 0.20, blue: 0.18, alpha: 1) : NSColor.systemGray).setFill()
        arrow.fill()
        return true
    }
    img.isTemplate = false
    return img
}

func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: appLang == "zh" ? "zh_CN" : "en_US")
    f.dateFormat = Calendar.current.isDateInToday(d) ? t("'Resets today' HH:mm", "今天 HH:mm 重置") : t("'Resets' MMM d, HH:mm", "M月d日 HH:mm 重置")
    return f.string(from: d)
}

struct QuotaRow: View {
    let title: String; let info: WindowInfo?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(info.map { String(format: "%.0f%%", $0.remaining) } ?? "--").font(.callout.monospacedDigit()).bold()
            }
            ProgressView(value: (info?.remaining ?? 0) / 100).tint((info?.remaining ?? 0) < 20 ? .red : .accentColor)
            Text(resetText(info?.resetsAt)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MenuPanel: View {
    @EnvironmentObject var m: GaugeModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.shownPercent.map { String(format: "%.0f%%", $0) } ?? "--%").font(.system(size: 40, weight: .bold).monospacedDigit())
                VStack(alignment: .leading) {
                    Text(t("Codex quota left", "Codex 剩余额度")).font(.headline)
                    Text(m.window.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            QuotaRow(title: t("5-hour window", "5 小时窗口"), info: m.quota?.primary)
            QuotaRow(title: t("Weekly limit", "每周额度"), info: m.quota?.secondary)
            if let e = m.quotaError { Text(e).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Circle().fill(m.connected ? .green : .orange).frame(width: 8, height: 8)
                Text(m.connText).font(.callout).lineLimit(1)
                Spacer()
                if !m.connected { Button(t("Connect", "连接")) { m.ble.connect() } }
            }
            if m.connected && !m.calibrated {
                Text(t("Gauge not calibrated yet. Open Settings & Calibration.", "指针还没校准，请打开「设置与校准」")).font(.caption).foregroundStyle(.orange)
            }
            Toggle(t("Auto sync to gauge (every \(m.interval) s)", "自动同步到指针（每 \(m.interval) 秒）"), isOn: $m.autoSync)
                .onChange(of: m.autoSync) { on in if on { Task { await m.refreshQuota(forceSend: true) } } }
            if let s = m.lastSentAt, let v = m.lastSent {
                Text(String(format: t("Last sent %.1f%% · ", "上次发送 %.1f%% · "), v) + s.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(t("Sync now", "立即同步")) { Task { await m.refreshQuota(forceSend: true) } }
                Spacer()
                Button(t("Settings & Calibration…", "设置与校准…")) { NSApp.activate(ignoringOtherApps: true); openWindow(id: "settings") }
                Button(t("Quit", "退出")) { m.quotaSvc.stop(); m.ble.disconnect(); NSApp.terminate(nil) }
            }
        }
        .padding(16).frame(width: 320)
    }
}

struct TestTab: View {
    @EnvironmentObject var m: GaugeModel
    var body: some View {
        Form {
            Section(t("Drag a percentage (sent on release)", "拖动百分比（松手后发送）")) {
                HStack {
                    Slider(value: $m.testPct, in: 0...100, step: 1) { editing in if !editing { Task { await m.test(m.testPct) } } }
                    Text("\(Int(m.testPct))%").monospacedDigit().frame(width: 44)
                }
                HStack {
                    ForEach([0, 25, 50, 75, 100], id: \.self) { q in
                        Button("\(q)%") { m.testPct = Double(q); Task { await m.test(Double(q)) } }
                    }
                    Spacer()
                    Button(m.busy ? t("Sweeping…", "扫描中…") : t("Full sweep", "全程扫描")) { Task { await m.sweep() } }.disabled(m.busy)
                }
            }
            Section {
                Text(m.calibrated ? t("Testing pauses auto sync; turn it back on in the menu afterwards.", "测试时会暂停自动同步，测完在菜单里重新打开。") : t("Calibrate on the Calibration tab first.", "需要先在「校准」页完成校准。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(t("Release servo", "放松舵机")) { Task { await m.cmd("OFF") } }
            }
        }.formStyle(.grouped)
    }
}

struct CalTab: View {
    @EnvironmentObject var m: GaugeModel
    var body: some View {
        Form {
            Section(t("1. Move the servo until the arrow sits on a tick", "1. 移动舵机，让箭头对准刻度")) {
                HStack {
                    Text(t("Pulse", "脉宽"))
                    TextField("", value: $m.jog, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                        .onSubmit { Task { await m.pulse(m.jog) } }
                    Text("µs")
                    Spacer()
                    Button(t("Move", "移动")) { Task { await m.pulse(m.jog) } }
                    Button(t("Center 1500", "回中 1500")) { m.jog = 1500; Task { await m.pulse(1500) } }
                }
                HStack {
                    ForEach([-50, -10, -2, 2, 10, 50], id: \.self) { d in
                        Button(d > 0 ? "+\(d)" : "\(d)") { m.jog = min(2500, max(500, m.jog + d)); Task { await m.pulse(m.jog) } }
                    }
                }
                HStack {
                    Button(t("Set current as 0%", "当前位置设为 0%")) { m.calEmpty = m.jog }
                    Button(t("Set current as 100%", "当前位置设为 100%")) { m.calFull = m.jog }
                }
            }
            Section(t("2. Calibration values (type them in)", "2. 校准数值（可直接填写）")) {
                HStack {
                    Text(t("0% pulse", "0% 脉宽")); Spacer()
                    TextField("", value: $m.calEmpty, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                    Text("µs"); Button(t("Try", "试一下")) { m.jog = m.calEmpty; Task { await m.pulse(m.calEmpty) } }
                }
                HStack {
                    Text(t("100% pulse", "100% 脉宽")); Spacer()
                    TextField("", value: $m.calFull, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                    Text("µs"); Button(t("Try", "试一下")) { m.jog = m.calFull; Task { await m.pulse(m.calFull) } }
                }
                HStack {
                    Text(m.calibrated ? t("On ESP32: 0% = \(m.devEmpty), 100% = \(m.devFull)", "ESP32 当前：0% = \(m.devEmpty)，100% = \(m.devFull)") : t("On ESP32: not calibrated", "ESP32 当前：未校准"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Save to ESP32", "保存到 ESP32")) { Task { if await m.saveCal(empty: m.calEmpty, full: m.calFull) { m.addLog(t("Calibration saved", "校准已保存")) } } }
                        .buttonStyle(.borderedProminent)
                }
            }
            Section {
                Text(t("V5 (74-tooth gear) reference ≈ 730 / 2270 µs. Move in small steps and never push into the end stops; back off if the servo buzzes.", "V5（74 齿）参考值约 730 / 2270 µs。小步调整，不要顶到上下止挡；听到嗡嗡声就往回调。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !m.calLoaded && m.calibrated { m.calEmpty = m.devEmpty; m.calFull = m.devFull }
            m.calLoaded = true; m.jog = m.devPulse
        }
    }
}

struct SettingsTab: View {
    @EnvironmentObject var m: GaugeModel
    var body: some View {
        Form {
            Section(t("Gauge", "指针")) {
                Picker(t("Quota shown", "显示哪个额度"), selection: $m.windowRaw) {
                    ForEach(QuotaWindow.allCases) { Text($0.label).tag($0.rawValue) }
                }.onChange(of: m.windowRaw) { _ in Task { await m.syncIfNeeded(force: true) } }
                VStack(alignment: .leading) {
                    HStack {
                        Text(t("Servo speed", "转动速度")); Spacer()
                        Text(String(format: t("%.0f°/s · full stroke ≈ %.1f s", "%.0f°/秒 · 全程约 %.1f 秒"), m.speedUI, 139.4 / m.speedUI)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $m.speedUI, in: 20...300, step: 5) { editing in if !editing { Task { await m.setSpeed(Int(m.speedUI)) } } }
                    Text(t("With the servo on 3V3, very high speeds can reset the board. Slow down if that happens.", "舵机接 3V3 时太快可能让板子重启，出现就调慢。")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(t("Sync", "同步")) {
                Picker(t("Refresh interval", "刷新间隔"), selection: $m.interval) {
                    ForEach([15, 30, 60, 120, 300], id: \.self) { Text($0 < 60 ? t("\($0) s", "\($0) 秒") : t("\($0 / 60) min", "\($0 / 60) 分钟")).tag($0) }
                }
                Toggle(t("Auto sync to gauge", "自动同步到指针"), isOn: $m.autoSync)
            }
            Section(t("Appearance", "外观")) {
                Picker(t("Language", "语言"), selection: $m.lang) {
                    Text("English").tag("en"); Text("简体中文").tag("zh")
                }
                Toggle(t("Show gauge icon in the menu bar", "菜单栏显示指针图标"), isOn: $m.showIcon)
            }
            Section(t("System", "系统")) {
                Toggle(t("Launch at login", "开机自动启动"), isOn: $m.loginOn).onChange(of: m.loginOn) { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { m.addLog(t("Launch-at-login failed: \(error.localizedDescription)", "开机启动设置失败：\(error.localizedDescription)")); m.loginOn = SMAppService.mainApp.status == .enabled }
                }
                LabeledContent("Codex", value: QuotaService.findCodex() ?? t("Not found", "未找到"))
                LabeledContent(t("Bluetooth", "蓝牙"), value: m.connText)
            }
        }
        .formStyle(.grouped)
        .onAppear { m.speedUI = Double(m.devSpeed) }
    }
}

struct LogTab: View {
    @EnvironmentObject var m: GaugeModel
    var body: some View {
        ScrollViewReader { r in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(m.log.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .onChange(of: m.log.count) { n in r.scrollTo(n - 1) }
        }
    }
}

struct SettingsWindow: View {
    @EnvironmentObject var m: GaugeModel
    var body: some View {
        TabView {
            TestTab().tabItem { Text(t("Test", "测试")) }
            CalTab().tabItem { Text(t("Calibration", "校准")) }
            SettingsTab().tabItem { Text(t("Settings", "设置")) }
            LogTab().tabItem { Text(t("Log", "日志")) }
        }
        .padding(8)
        .frame(width: 500, height: 520)
        .task { if m.connected { await m.refreshStatus() } }
    }
}

@main
struct CodexGaugeApp: App {
    @StateObject private var model = GaugeModel()
    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            HStack(spacing: 3) {
                if model.showIcon {
                    Image(nsImage: gaugeIcon(model.shownPercent, connected: model.connected)).renderingMode(.original)
                }
                Text(model.shownPercent.map { String(format: "%.0f%%", $0) } ?? "--")
            }
        }
        .menuBarExtraStyle(.window)

        Window(t("Codex Gauge · Settings & Calibration", "Codex 额度指针 · 设置与校准"), id: "settings") {
            SettingsWindow().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
