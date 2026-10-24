// 机械指针 · macOS 菜单栏 App
// Two modes, switchable in Settings:
//   · Codex: reads the local Codex quota (codex app-server, read-only)
//   · Game:  reads a racing game's speed off the screen (game.swift) and shows
//            it as a speedometer or a simulated tachometer
// and drives the ESP32 "CodexGauge" over Bluetooth LE. Lives in the menu bar, no Dock icon.
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
        _ = try await request("initialize", ["clientInfo": ["name": "codex_gauge_mac", "title": "Mechanical Gauge", "version": "2.0.0"]])
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
        // "OK Q …" that nobody waits for is the ack of a push(); keep it out of the log
        let pushAck = line.hasPrefix("OK Q") && current.map({ !$0.0.hasPrefix("Q") }) ?? true
        if !pushAck { onReply?(line) }
        if !pushAck, let cur = current, line.hasPrefix("OK") || line.hasPrefix("ERR") || line.hasPrefix("STATUS") {
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

    /// Fire-and-forget write (Write Without Response) for the high-rate game stream.
    /// Skipped while an awaited command is in flight or the link is busy; returns whether it was sent.
    @discardableResult
    func push(_ cmd: String) -> Bool {
        guard ready, current == nil, pending.isEmpty, let p = peripheral, let rx, p.canSendWriteWithoutResponse else { return false }
        p.writeValue((cmd + "\n").data(using: .ascii)!, for: rx, type: .withoutResponse)
        return true
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
    // Game mode preferences.
    @Published var mode = UserDefaults.standard.string(forKey: "mode") ?? "codex" {
        didSet { UserDefaults.standard.set(mode, forKey: "mode"); if mode != oldValue { modeChanged() } } }
    /// "car": speedometer / tachometer; "flight": speedometer / altimeter (drum counters like "00897").
    @Published var gameKind = UserDefaults.standard.string(forKey: "gameKind") ?? "car" {
        didSet {
            UserDefaults.standard.set(gameKind, forKey: "gameKind")
            if !Self.dials(gameKind).contains(dial) { dial = Self.dials(gameKind)[0] } else if isGame { startGame() }
        } }
    @Published var dial = UserDefaults.standard.string(forKey: "dial") ?? "speed" {
        didSet { UserDefaults.standard.set(dial, forKey: "dial"); gameSentPct = nil; if isGame && dial != oldValue { startGame() } } }
    @Published var maxSpeed = UserDefaults.standard.object(forKey: "maxSpeed") as? Double ?? 200 {
        didSet { UserDefaults.standard.set(maxSpeed, forKey: "maxSpeed"); if isGame { startGame() } } }
    @Published var maxRPM = UserDefaults.standard.object(forKey: "maxRPM") as? Double ?? 7000 {
        didSet { UserDefaults.standard.set(maxRPM, forKey: "maxRPM") } }
    @Published var maxAirspeed = UserDefaults.standard.object(forKey: "maxAirspeed") as? Double ?? 500 {
        didSet { UserDefaults.standard.set(maxAirspeed, forKey: "maxAirspeed"); if isGame { startGame() } } }
    @Published var maxAlt = UserDefaults.standard.object(forKey: "maxAlt") as? Double ?? 10000 {
        didSet { UserDefaults.standard.set(maxAlt, forKey: "maxAlt"); if isGame { startGame() } } }
    /// Manual tachometer: rpm at the right end of the game's rpm bar, and the gear labels left to right.
    @Published var barMaxRPM = UserDefaults.standard.object(forKey: "barMaxRPM") as? Double ?? 8000 {
        didSet { UserDefaults.standard.set(barMaxRPM, forKey: "barMaxRPM") } }
    @Published var gearLabels = UserDefaults.standard.string(forKey: "gearLabels") ?? "R N 1 2 3 4 5 6 7" {
        didSet { UserDefaults.standard.set(gearLabels, forKey: "gearLabels"); if isGame && source == "bar" { startGame() } } }
    /// Screen regions, one per number on screen: car speed (also feeds the tachometer), flight speed, altitude.
    @Published var rois: [String: CGRect] = GaugeModel.loadROIs() {
        didSet { UserDefaults.standard.set(rois.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }, forKey: "rois") } }

    static func dials(_ kind: String) -> [String] { kind == "flight" ? ["speed", "alt"] : ["speed", "tach", "mtach"] }
    private static func loadROIs() -> [String: CGRect] {
        var out = ((UserDefaults.standard.dictionary(forKey: "rois") as? [String: [Double]]) ?? [:]).compactMapValues {
            $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        // Earlier versions kept a single car-speed region under "roi".
        if out["car"] == nil, let r = UserDefaults.standard.array(forKey: "roi") as? [Double], r.count == 4 {
            out["car"] = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        }
        return out
    }
    /// Which on-screen number the current dial reads.
    var source: String { gameKind == "flight" ? (dial == "alt" ? "alt" : "air") : dial == "mtach" ? "bar" : "car" }
    var roi: CGRect? {
        get { rois[source] }
        set { rois[source] = newValue }
    }
    var dialName: String {
        switch (gameKind, dial) {
        case ("car", "tach"): return t("Tachometer", "转速表")
        case ("car", "mtach"): return t("Manual tachometer", "手动挡转速表")
        case ("flight", "alt"): return t("Altimeter", "高度表")
        default: return t("Speedometer", "速度表")
        }
    }

    let ble = BLELink()
    let quotaSvc = QuotaService()
    let game = GameState()
    private let reader = SpeedReader()
    private let tach = TachModel()
    private var timer: Timer?
    private var gameTimer: Timer?
    private var nextRead = Date.distantPast
    private var lastGameTick = Date()
    private var gameSentPct: Double?
    private var gameSentAt = Date.distantPast
    private var gameStale = false
    private var gameFrames = 0
    private var gameWasLost: Bool?
    private var flightSmooth = OneEuroFilter()

    var window: QuotaWindow { QuotaWindow(rawValue: windowRaw) ?? .mostRestrictive }
    var isGame: Bool { mode == "game" }

    init() {
        ble.onState = { [weak self] text, ok in
            Task { @MainActor in
                guard let self else { return }
                let was = self.connected
                self.connText = text; self.connected = ok
                if ok && !was {
                    self.addLog(text); self.lastSent = nil; self.gameSentPct = nil
                    await self.refreshStatus(); self.nextRead = .distantPast
                }
                if !ok && was { self.addLog(text) }
            }
        }
        ble.onReply = { [weak self] line in Task { @MainActor in self?.addLog("← \(line)") } }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        reader.onError = { [weak self] e in Task { @MainActor in
            self?.game.status = t("Screen capture stopped: \(e)", "截屏停止：\(e)"); self?.addLog(self?.game.status ?? "") } }
        ble.connect()
        if isGame { startGame() }
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
        if isGame { return }
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
        guard !isGame, (autoSync || force), connected, calibrated, let pct = shownPercent else { return }
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

    func setSpeed(_ v: Int) async {
        let want = min(1000, max(10, v))
        // Firmware before the game update only accepts up to 400 deg/s.
        if await cmd("SPEED \(want)") == nil && want > 400 {
            addLog(t("This firmware stops at 400°/s; flash the new firmware for more", "当前固件最高 400°/s，想更快请刷新新固件"))
            await cmd("SPEED 400")
        }
        await refreshStatus()
    }

    // MARK: Game mode

    private func modeChanged() {
        addLog(isGame ? t("Switched to game mode", "切换到游戏指针") : t("Switched to Codex mode", "切换到 Codex 额度"))
        if isGame {
            quotaSvc.stop(); startGame()
            if !autoSync { autoSync = true; addLog(t("Live follow turned on", "已打开实时跟随")) }
        } else { stopGame(); lastSent = nil; nextRead = .distantPast }
    }

    var screenAllowed: Bool { CGPreflightScreenCaptureAccess() }

    func requestScreen() {
        CGRequestScreenCaptureAccess()
        game.status = t("After allowing it in System Settings, quit and reopen the app", "在系统设置里允许后，请退出并重新打开本 App")
    }

    func startGame() {
        SpeedOCR.warmUp()
        flightSmooth.reset()
        if gameTimer == nil {
            lastGameTick = Date()
            let tm = Timer(timeInterval: 1.0 / 40, repeats: true) { [weak self] _ in Task { @MainActor in self?.gameTick() } }
            RunLoop.main.add(tm, forMode: .common)  // keep ticking while a menu is open
            gameTimer = tm
        }
        guard let roi else { Task { await reader.stop() }; game.status = t("Pick the region of this dial's number first", "请先框选这个表盘要读的数字区域"); return }
        guard screenAllowed else { game.status = t("Needs Screen Recording permission", "需要屏幕录制权限"); return }
        Task {
            do {
                switch source {
                case "bar":
                    let labels = gearLabels.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
                    try await reader.startBar(bar: roi, gear: rois["gear"], labels: labels)
                // Flight: re-check anything that moves more than 1 % of full scale in one frame (rolling digits misread)
                case "alt": try await reader.start(roi: roi, limit: maxAlt * 10, maxJump: max(15, Int(maxAlt * 0.01)), fixedDigits: true)
                case "air": try await reader.start(roi: roi, limit: maxAirspeed * 1.5, maxJump: max(15, Int(maxAirspeed * 0.01)), fixedDigits: true)
                default: try await reader.start(roi: roi, limit: maxSpeed * 1.5)
                }
                game.status = t("Reading the screen", "正在识别屏幕")
            } catch {
                game.status = t("Screen capture failed: \(error.localizedDescription)", "截屏失败：\(error.localizedDescription)")
                addLog(game.status)
            }
        }
    }

    func stopGame() {
        gameTimer?.invalidate(); gameTimer = nil
        Task { await reader.stop() }
        game.live = false
    }

    /// delay: seconds to wait first, so the user can switch to a full-screen game from the settings window.
    /// key: which region to pick ("gear" for the manual tachometer's gear row); default = the current dial's number.
    func pickRegion(_ key: String? = nil, delay: Double = 0) {
        guard screenAllowed else { requestScreen(); return }
        if delay > 0 {
            game.status = t("Switch to the game: picking starts in \(Int(delay)) s", "请切到游戏画面：\(Int(delay)) 秒后开始框选")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pickRegion(key) }
            return
        }
        RegionPicker.pick { [weak self] r in
            guard let self, let r else { return }
            self.rois[key ?? self.source] = r
            self.addLog(t("Speed region \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))",
                          "速度区域 \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"))
            if self.isGame { self.startGame() }
        }
    }

    /// 40 Hz: advance the tach model, publish to the UI at 10 Hz, stream Q to the gauge.
    private func gameTick() {
        let now = Date(), dt = now.timeIntervalSince(lastGameTick); lastGameTick = now
        let s = reader.snapshot
        // Lost = no frame yet, or frames keep coming without a number for 3 s (left the car, menu open…)
        let lost = !reader.running || s.frames == 0 || s.missingSince.map { now.timeIntervalSince($0) > 3 } ?? false
        if lost != gameWasLost {
            if gameWasLost != nil || !lost {
                addLog(lost ? t("No speed on screen (\(s.frames) frames so far)", "屏幕上读不到速度（已收到 \(s.frames) 帧）")
                            : t("Reading speed: \(s.raw.map(String.init) ?? "--")", "识别到速度：\(s.raw.map(String.init) ?? "--")"))
            }
            gameWasLost = lost
        }
        let rpm = tach.update(speed: s.speed, dt: dt)
        var pct: Double?
        if !lost {
            switch source {
            case "bar": pct = s.fill.map { $0 * 100 }
            // Flight: drum counters keep rolling, so smooth (adaptive: steady → calm, climbing/diving → no lag)
            case "alt": pct = s.speed.map { flightSmooth.filter(Double($0) / maxAlt * 100, dt: dt) }
            case "air": pct = s.speed.map { flightSmooth.filter(Double($0) / maxAirspeed * 100, dt: dt) }
            default: pct = dial == "tach" ? rpm / maxRPM * 100 : s.speed.map { Double($0) / maxSpeed * 100 }
            }
            pct = pct.map { min(100, max(0, $0)) }  // never past the calibrated ends
        }
        gameFrames += 1
        if gameFrames % 4 == 0 {
            game.live = !lost; game.speed = s.speed; game.raw = s.raw; game.rpm = rpm
            game.gear = tach.gear; game.pct = pct; game.ms = s.ms; game.frames = s.frames
            game.gameGear = s.gear; game.barRPM = s.fill.map { $0 * barMaxRPM }
            if gameFrames % 8 == 0, let img = s.image { game.preview = NSImage(cgImage: img, size: .zero) }
        }
        guard autoSync, connected, calibrated else { return }
        if lost {
            if !gameStale && reader.running { gameStale = true; Task { await cmd("STALE") } }
            return
        }
        guard let pct else { return }
        // The tachometer shows small vibrations; flight ignores sub-0.5% wiggles so the servo stays still
        let threshold = ["alt", "air"].contains(source) ? 0.5 : dial == "tach" ? 0.15 : 0.3
        if let last = gameSentPct, abs(pct - last) < threshold, now.timeIntervalSince(gameSentAt) < 60 { return }
        let c = String(format: "Q %.1f", pct)
        if gameSentPct == nil {  // first one waits for the reply, so errors show up in the log
            gameSentPct = pct; gameSentAt = now; gameStale = false
            Task { if await cmd(c) == nil { gameSentPct = nil } }
        } else if ble.push(c) {
            gameSentPct = pct; gameSentAt = now; gameStale = false
        }
    }

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

/// What the game-mode UI shows; refreshed at 10 Hz so SwiftUI isn't redrawn 40 times a second.
@MainActor
final class GameState: ObservableObject {
    @Published var live = false
    @Published var speed: Int?
    @Published var raw: Int?
    @Published var rpm = 0.0
    @Published var gear = 1
    @Published var pct: Double?
    @Published var ms = 0.0
    @Published var frames = 0
    @Published var gameGear: String?   // manual tachometer: lit gear label read off the screen
    @Published var barRPM: Double?     // manual tachometer: rpm from the game's rpm bar
    @Published var preview: NSImage?
    @Published var status = ""
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
            if m.isGame {
                GameSummary()
            } else {
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
            }
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
            Toggle(m.isGame ? t("Follow the game live", "实时跟随游戏")
                            : t("Auto sync to gauge (every \(m.interval) s)", "自动同步到指针（每 \(m.interval) 秒）"), isOn: $m.autoSync)
                .onChange(of: m.autoSync) { on in if on && !m.isGame { Task { await m.refreshQuota(forceSend: true) } } }
            if !m.isGame, let s = m.lastSentAt, let v = m.lastSent {
                Text(String(format: t("Last sent %.1f%% · ", "上次发送 %.1f%% · "), v) + s.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if m.isGame {
                    Button(t("Pick region", "框选数字区域")) { m.pickRegion() }
                } else {
                    Button(t("Sync now", "立即同步")) { Task { await m.refreshQuota(forceSend: true) } }
                }
                Spacer()
                Button(t("Settings & Calibration…", "设置与校准…")) { NSApp.activate(ignoringOtherApps: true); openWindow(id: "settings") }
                Button(t("Quit", "退出")) { m.quotaSvc.stop(); m.ble.disconnect(); NSApp.terminate(nil) }
            }
        }
        .padding(16).frame(width: 320)
    }
}

/// Big readout for game mode: speed, altitude, or rpm + gear when the tachometer dial is on.
struct GameSummary: View {
    @EnvironmentObject var m: GaugeModel
    @EnvironmentObject var g: GameState
    var subtitle: String {
        switch m.source {
        case "alt": return t("Flight · altitude", "飞行 · 高度")
        case "air": return t("Flight · speed", "飞行 · 速度")
        case "bar":
            let gear = g.gameGear.map { ["R", "N"].contains($0) ? $0 : t("gear \($0)", "\($0) 挡") } ?? t("gear --", "档位 --")
            return t("rpm · manual · ", "rpm · 手动挡 · ") + gear
        default:
            if m.dial != "tach" { return t("Racing · km/h", "赛车 · km/h") }
            return g.live ? t("rpm · gear \(g.gear) · \(g.speed ?? 0) km/h", "rpm · \(g.gear) 挡 · \(g.speed ?? 0) km/h") : "rpm"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(!g.live ? "--" : m.source == "bar" ? String(format: "%.0f", ((g.barRPM ?? 0) / 10).rounded() * 10)
                     : m.source == "car" && m.dial == "tach" ? String(format: "%.0f", (g.rpm / 10).rounded() * 10) : "\(g.speed ?? 0)")
                    .font(.system(size: 40, weight: .bold).monospacedDigit())
                VStack(alignment: .leading) {
                    Text(m.dialName).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: (g.pct ?? 0) / 100).tint(m.source == "car" && m.dial == "tach" && (g.pct ?? 0) > 85 ? .red : .accentColor)
            Text(g.live ? t("Reading \(g.raw.map(String.init) ?? "--") · \(String(format: "%.1f", g.ms)) ms/frame · \(g.frames) frames",
                            "识别 \(g.raw.map(String.init) ?? "--") · 每帧 \(String(format: "%.1f", g.ms)) ms · 共 \(g.frames) 帧")
                 : (g.status.isEmpty ? t("No speed on screen", "屏幕上读不到速度") : g.status + t(" · \(g.frames) frames", " · 已收到 \(g.frames) 帧")))
                .font(.caption).foregroundStyle(g.live ? Color.secondary : Color.orange)
            if !m.autoSync {
                Text(t("Live follow is off; turn it on below.", "实时跟随已关闭，打开下面的开关指针才会动。")).font(.caption).foregroundStyle(.orange)
            } else if m.connected && !m.calibrated {
                Text(t("Gauge not calibrated.", "指针还没校准。")).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct GameTab: View {
    @EnvironmentObject var m: GaugeModel
    @EnvironmentObject var g: GameState
    var allowed: Bool { m.screenAllowed }
    func fullScale(_ label: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Text(label); Spacer()
            TextField("", value: value, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
            if !unit.isEmpty { Text(unit) }
        }
    }
    var body: some View {
        Form {
            if !m.isGame {
                Section {
                    HStack {
                        Text(t("The gauge is showing the Codex quota.", "指针现在显示 Codex 额度。")).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("Switch to game", "切换到游戏指针")) { m.mode = "game" }
                    }
                }
            }
            Section(t("1. Game and dial", "1. 游戏类型和表盘")) {
                Picker(t("Game", "游戏类型"), selection: $m.gameKind) {
                    Text(t("Racing", "赛车")).tag("car")
                    Text(t("Flight", "飞行")).tag("flight")
                }.pickerStyle(.segmented)
                Picker(t("Dial", "表盘"), selection: $m.dial) {
                    if m.gameKind == "flight" {
                        Text(t("Speedometer", "速度表")).tag("speed")
                        Text(t("Altimeter", "高度表")).tag("alt")
                    } else {
                        Text(t("Speedometer", "速度表")).tag("speed")
                        Text(t("Tachometer (simulated)", "转速表（模拟）")).tag("tach")
                        Text(t("Manual tachometer", "手动挡转速表")).tag("mtach")
                    }
                }.pickerStyle(.segmented)
                switch m.source {
                case "alt": fullScale(t("Full-scale altitude", "满格高度"), $m.maxAlt, "")
                case "air": fullScale(t("Full-scale speed", "满格速度"), $m.maxAirspeed, "")
                case "bar":
                    fullScale(t("rpm at the bar's right end", "转速条右端的转速"), $m.barMaxRPM, "rpm")
                    HStack {
                        Text(t("Gear labels, left to right", "档位，从左到右")); Spacer()
                        TextField("", text: $m.gearLabels).frame(width: 180).multilineTextAlignment(.trailing)
                    }
                    Text(t("Reads the game's own rpm bar (the needle follows how far it is lit, full bar = 100 %) and which gear label is lit. Pick two regions below: the rpm bar from its left end to its right end, and the gear row from the first label to the last.",
                           "直接读游戏自己的转速条（指针按转速条亮到哪里走，亮满 = 100%）和亮着的档位。下面要框两个区域：转速条从左端框到右端；档位行从第一个档位框到最后一个。"))
                        .font(.caption).foregroundStyle(.secondary)
                default:
                    if m.dial == "tach" {
                        fullScale(t("Full-scale rpm", "满格转速"), $m.maxRPM, "rpm")
                        Text(t("Tachometer: five-speed shift table (1st 0–20, 2nd 20–40, 3rd 40–60, 4th 60–80, 5th 80+ km/h). Hard acceleration shifts late, gentle early; idle wobble, clutch launch, upshift dip, downshift blip, engine vibration and a rev limiter.",
                               "转速表：五挡换挡表（1 挡 0–20、2 挡 20–40、3 挡 40–60、4 挡 60–80、5 挡 80 km/h 以上）。急加速晚升挡、缓加速早升挡；怠速抖动、起步半离合、升挡下冲、降挡补油、发动机抖动、断油回弹。"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        fullScale(t("Full-scale speed", "满格速度"), $m.maxSpeed, "km/h")
                    }
                }
            }
            Section(m.source == "alt" ? t("2. Altitude on screen", "2. 屏幕上的高度")
                    : m.source == "bar" ? t("2. Rpm bar and gear on screen", "2. 屏幕上的转速条和档位") : t("2. Speed on screen", "2. 屏幕上的速度")) {
                HStack(spacing: 12) {
                    ZStack {
                        Color.black
                        if let img = g.preview { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) }
                        else { Text(m.roi == nil ? t("Not picked", "还没框选") : "--").foregroundStyle(.secondary) }
                    }.frame(width: 160, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        if m.source == "bar" {
                            HStack {
                                Button(t("Pick rpm bar (3 s)", "框选转速条（3 秒后）")) { m.pickRegion("bar", delay: 3) }.buttonStyle(.borderedProminent)
                                Button(t("Pick gear row (3 s)", "框选档位行（3 秒后）")) { m.pickRegion("gear", delay: 3) }
                            }
                            Text(m.rois["gear"] == nil ? t("Gear row not picked: only rpm is read.", "还没框档位行：只读转速。")
                                 : t("Gear: \(g.gameGear ?? "--")", "档位：\(g.gameGear ?? "--")"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button(t("Pick region (in 3 s)", "框选数字区域（3 秒后）")) { m.pickRegion(delay: 3) }.buttonStyle(.borderedProminent)
                        }
                        Text(m.gameKind == "flight"
                             ? t("Box the counter's digit window only, not the scale numbers beside it. Each dial keeps its own region. Full screen: switch to the game within 3 s, or use the menu bar icon.",
                                 "只框计数器的数字窗口，不要框到旁边刻度上的数字。速度和高度各自保存区域。全屏游戏：3 秒内切回游戏，或在游戏里点菜单栏图标框选。")
                             : t("Box the digits only, not the gear (N/D). For a full-screen game, switch to it within 3 s, or use the menu bar icon.",
                                 "只框数字，不要框到档位 N/D。全屏游戏：3 秒内切回游戏，或在游戏里点菜单栏图标框选。"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if m.isGame {
                            Text(g.live ? t("Reading \(g.raw.map(String.init) ?? "--")", "识别：\(g.raw.map(String.init) ?? "--")") : g.status)
                                .font(.caption).foregroundStyle(g.live ? Color.secondary : Color.orange)
                        }
                    }
                }
                HStack {
                    Text(t("Frames the two recognisers read differently are saved for diagnosis.", "快速/精确两种识别读得不一样的画面会自动保存，方便排查。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Open samples", "打开样本文件夹")) {
                        try? FileManager.default.createDirectory(at: OCRSamples.dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(OCRSamples.dir)
                    }
                }
                if !allowed {
                    HStack {
                        Text(t("Needs Screen Recording permission; reopen the app after allowing it.", "需要屏幕录制权限，允许后请重新打开 App。"))
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button(t("Allow", "去授权")) { m.requestScreen() }
                    }
                }
            }
        }
        .formStyle(.grouped)
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
            Section(t("Mode", "模式")) {
                Picker(t("The gauge shows", "指针显示"), selection: $m.mode) {
                    Text(t("Codex quota", "Codex 额度")).tag("codex")
                    Text(t("Game gauge", "游戏指针")).tag("game")
                }.pickerStyle(.segmented)
                Text(m.isGame ? t("Reads the racing game's speed off the screen in real time; set it up on the Game tab.", "实时识别屏幕上的赛车速度，在「游戏」页设置。")
                              : t("Shows the remaining Codex quota.", "显示 Codex 剩余额度。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(t("Gauge", "指针")) {
                Picker(t("Quota shown", "显示哪个额度"), selection: $m.windowRaw) {
                    ForEach(QuotaWindow.allCases) { Text($0.label).tag($0.rawValue) }
                }.onChange(of: m.windowRaw) { _ in Task { await m.syncIfNeeded(force: true) } }
                VStack(alignment: .leading) {
                    HStack {
                        Text(t("Servo speed", "转动速度")); Spacer()
                        Text(String(format: t("%.0f°/s · full stroke ≈ %.1f s", "%.0f°/秒 · 全程约 %.1f 秒"), m.speedUI, 139.4 / m.speedUI)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $m.speedUI, in: 20...1000, step: 10) { editing in if !editing { Task { await m.setSpeed(Int(m.speedUI)) } } }
                    Text(t("Game mode wants 400 or more. If the board resets or stops answering when the servo moves, the servo supply is too weak: slow down, add a 470–1000 µF capacitor, or power the servo separately (shared GND).",
                           "游戏模式建议 400 以上。如果舵机一动板子就重启或不响应，说明舵机供电不够：调慢、加 470–1000 µF 电容，或者给舵机单独供电（共地）。")).font(.caption).foregroundStyle(.secondary)
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
            GameTab().tabItem { Text(t("Game", "游戏")) }
            TestTab().tabItem { Text(t("Test", "测试")) }
            CalTab().tabItem { Text(t("Calibration", "校准")) }
            SettingsTab().tabItem { Text(t("Settings", "设置")) }
            LogTab().tabItem { Text(t("Log", "日志")) }
        }
        .padding(8)
        .frame(width: 520, height: 600)
        .task { if m.connected { await m.refreshStatus() } }
    }
}

/// Menu bar text: quota % in Codex mode, speed or rpm in game mode.
struct BarLabel: View {
    @ObservedObject var m: GaugeModel
    @ObservedObject var g: GameState
    var body: some View {
        let pct = m.isGame ? g.pct : m.shownPercent
        HStack(spacing: 3) {
            if m.showIcon { Image(nsImage: gaugeIcon(pct, connected: m.connected)).renderingMode(.original) }
            if m.isGame {
                Text(!g.live ? "--" : m.source == "bar" ? String(format: "%.1fk", (g.barRPM ?? 0) / 1000)
                     : m.source == "car" && m.dial == "tach" ? String(format: "%.1fk", g.rpm / 1000) : "\(g.speed ?? 0)")
                    .monospacedDigit()
            } else {
                Text(m.shownPercent.map { String(format: "%.0f%%", $0) } ?? "--")
            }
        }
    }
}

@main
struct MechanicalGaugeApp: App {
    @StateObject private var model = GaugeModel()
    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model).environmentObject(model.game)
        } label: {
            BarLabel(m: model, g: model.game)
        }
        .menuBarExtraStyle(.window)

        Window(t("Mechanical Gauge · Settings & Calibration", "机械指针 · 设置与校准"), id: "settings") {
            SettingsWindow().environmentObject(model).environmentObject(model.game)
        }
        .windowResizability(.contentSize)
    }
}
