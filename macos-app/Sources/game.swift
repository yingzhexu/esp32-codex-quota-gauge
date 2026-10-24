// 游戏指针：截取屏幕上的车速数字（ScreenCaptureKit），Vision OCR 识别，
// 再换算成速度表或转速表的百分比。由 GaugeModel 驱动发送。
import AppKit
import SwiftUI
import ScreenCaptureKit
import Vision
import CoreImage

// MARK: - OCR

enum SpeedOCR {
    /// Vision 把粗体数字偶尔认成字母，映射回来
    static let lookalike: [Character: Character] = [
        "o": "0", "O": "0", "D": "0", "Q": "0", "l": "1", "I": "1", "|": "1", "i": "1",
        "S": "5", "s": "5", "B": "8", "Z": "2", "z": "2", "g": "9"]

    /// fast：每帧 3–8 ms，单个数字也能读，是主力。
    /// accurate：预热后约 16 ms，多位数更准，只用来复核可疑帧；第一次调用要加载模型（几十秒），所以先 warmUp()。
    /// band：只识别数字那一行及以上（不含下面的 KM/H），精确模式能从约 25 ms 降到约 20 ms。
    static func recognize(_ img: CGImage, accurate: Bool = false, band: Glyphs? = nil) -> [VNRecognizedTextObservation] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = accurate ? .accurate : .fast
        req.usesLanguageCorrection = false
        if let band {  // 从数字下沿到画面顶部（去掉下面的 KM/H）；Vision 的坐标 0–1、原点在左下
            let h = CGFloat(img.height), m = CGFloat(band.bottom - band.top) * 0.15
            let y0 = max(0, h - CGFloat(band.bottom) - 1 - m)
            req.regionOfInterest = CGRect(x: 0, y: y0 / h, width: 1, height: 1 - y0 / h)
        }
        try? VNImageRequestHandler(cgImage: img).perform([req])
        return req.results ?? []
    }

    static func isDigit(_ c: Character) -> Bool { ("0"..."9").contains(c) }

    /// 读到的数字和它的位数。位数按字面算：飞行游戏的滚轮计数器 "00897" 是 5 位。
    struct Reading: Equatable { var value: Int; var digits: Int }

    static func reading(_ s: String) -> Reading? {
        let text = s.replacingOccurrences(of: " ", with: "")
        let mapped = String(text.map { lookalike[$0] ?? $0 })
        if (1...6).contains(mapped.count), mapped.allSatisfy(isDigit) { return Int(mapped).map { Reading(value: $0, digits: mapped.count) } }
        // "N 0" 这种混在一起的，只取最长的一串数字
        let runs = text.split(whereSeparator: { !isDigit($0) }).filter { $0.count <= 6 }
        return runs.max(by: { $0.count < $1.count }).flatMap { r in Int(String(r)).map { Reading(value: $0, digits: r.count) } }
    }

    static func number(_ s: String) -> Int? { reading(s)?.value }

    private static let readyLock = NSLock()
    private static var ready = false, warming = false
    static var accurateReady: Bool { readyLock.lock(); defer { readyLock.unlock() }; return ready }

    /// 在后台加载精确模式的模型（用一张画着数字的小图跑一次）。可以重复调用。
    static func warmUp() {
        readyLock.lock(); let go = !ready && !warming; warming = true; readyLock.unlock()
        guard go else { return }
        DispatchQueue.global(qos: .utility).async {
            let ctx = CGContext(data: nil, width: 160, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(gray: 0.15, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
            NSAttributedString(string: "128", attributes: [.font: NSFont.boldSystemFont(ofSize: 52), .foregroundColor: NSColor.white])
                .draw(at: NSPoint(x: 30, y: 10))
            NSGraphicsContext.restoreGraphicsState()
            if let img = ctx.makeImage() { _ = recognize(img, accurate: true) }
            readyLock.lock(); ready = true; readyLock.unlock()
        }
    }

    /// 数一数速度数字有几个字形：找到最高的一行文字（速度数字；KM/H 更矮），
    /// 在这一行里按"整列都没有字"的空白把字形分开。不到 1 ms。
    /// 这个游戏字体里的 "1" 很窄，Fast 模式常把 117 读成 7——位数和字形数对不上，就知道读错了。
    struct Glyphs { var count: Int; var top: Int; var bottom: Int }  // top/bottom：数字那一行的像素行号（0 = 顶部）

    static func glyphCount(_ img: CGImage) -> Int? { glyphs(img)?.count }

    static func glyphs(_ img: CGImage) -> Glyphs? {
        let w = img.width, h = img.height
        guard w > 4, h > 4, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lum = [UInt8](repeating: 0, count: w * h), sum = 0
        for i in 0..<(w * h) { let l = (Int(p[i * 4]) + Int(p[i * 4 + 1]) + Int(p[i * 4 + 2])) / 3; lum[i] = UInt8(l); sum += l }
        let lightText = sum / (w * h) < 128  // 深色背景上的浅色字（大多数游戏）
        func ink(_ x: Int, _ y: Int) -> Bool { let l = lum[y * w + x]; return lightText ? l > 140 : l < 115 }
        // 最高的一段连续有字的行（允许 2 行空隙）；内存第 0 行是图像顶部
        var best = (0, -1), start = -1, gap = 0
        for y in 0...h {
            if y < h && (0..<w).contains(where: { ink($0, y) }) { if start < 0 { start = y }; gap = 0; continue }
            if start >= 0 {
                gap += 1
                if gap > 2 || y == h {
                    let end = y - gap
                    if end - start > best.1 - best.0 { best = (start, end) }
                    start = -1; gap = 0
                }
            }
        }
        let bandH = best.1 - best.0 + 1
        guard bandH > 6 else { return nil }
        // 在这一行里数字形：连续有字的列算一个，太窄的（噪点）不算
        var count = 0, run = 0
        for x in 0...w {
            let has = x < w && (best.0...best.1).contains(where: { ink(x, $0) })
            if has { run += 1 } else { if run >= max(2, bandH / 12) { count += 1 }; run = 0 }
        }
        return Glyphs(count: count, top: best.0, bottom: best.1)
    }

    static func speed(_ img: CGImage, accurate: Bool = false, band: Glyphs? = nil) -> Int? {
        read(img, accurate: accurate, band: band)?.value
    }

    static func read(_ img: CGImage, accurate: Bool = false, band: Glyphs? = nil) -> Reading? {
        let obs = recognize(img, accurate: accurate, band: band)
        if let r = bestReading(obs) { return r }
        if accurate { return nil }
        // 旁边有 KM/H 等文字时，Fast 模式会漏掉孤立的个位数：盖掉那些文字再认一次
        guard !obs.isEmpty, let masked = mask(img, obs.map(\.boundingBox)) else { return nil }
        return recognize(masked).lazy.compactMap { $0.topCandidates(1).first.flatMap { reading($0.string) } }.first
    }

    /// 有多串数字时取字最大的那串（飞行游戏里旁边刻度上的 950、850 比计数器小）
    static func bestReading(_ obs: [VNRecognizedTextObservation]) -> Reading? {
        var best: (CGFloat, Reading)?
        for o in obs {
            guard let s = o.topCandidates(1).first?.string, let r = reading(s) else { continue }
            if best == nil || o.boundingBox.height > best!.0 { best = (o.boundingBox.height, r) }
        }
        return best?.1
    }

    static func bestNumber(_ obs: [VNRecognizedTextObservation]) -> Int? { bestReading(obs)?.value }

    private static func mask(_ img: CGImage, _ boxes: [CGRect]) -> CGImage? {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // 左上角的像素当背景色（内存第一行是图像顶部）
        ctx.setFillColor(red: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
        for b in boxes {  // Vision 坐标 0–1、原点左下，和 CGContext 一致
            ctx.fill(CGRect(x: b.minX * CGFloat(w) - 2, y: b.minY * CGFloat(h) - 2,
                            width: b.width * CGFloat(w) + 4, height: b.height * CGFloat(h) + 4))
        }
        return ctx.makeImage()
    }
}

/// 去掉识别错误，但不加延迟：
///  · 超出量程的直接丢；
///  · 和当前值相差不超过 maxJump 的，立即接受；
///  · 大跳变如果已经被精确模式复核过（verified），立即接受——真的急停不会被拖慢；
///  · 没能复核的大跳变，要连续 need 帧一致才接受（30 帧/秒下约 66 ms）。
struct SpeedFilter {
    var limit: Double; var maxJump = 25; var need = 2
    /// 飞行计数器：先取最近 3 帧的中位数，滚动中某一位读错的单帧直接剔除（只多 1 帧延迟）
    var median3 = false
    var value: Int?
    private var pending: Int?, count = 0
    private var recent: [Int] = []

    init(limit: Double) { self.limit = limit }

    func suspicious(_ raw: Int?) -> Bool {
        guard let raw, let v = value else { return false }
        return abs(raw - v) > maxJump
    }

    mutating func feed(_ input: Int?, verified: Bool = false) -> Int? {
        guard var raw = input, Double(raw) <= limit else { return value }
        if median3 {
            recent.append(raw); if recent.count > 3 { recent.removeFirst() }
            if recent.count == 3 { raw = recent.sorted()[1] }
        }
        if verified || !suspicious(raw) { value = raw; pending = nil; return value }
        if let p = pending, abs(raw - p) <= maxJump { count += 1 } else { pending = raw; count = 1 }
        if count >= need { value = raw; pending = nil }
        return value
    }
}

/// 快速和精确两种识别读得不一样的画面，存到「应用支持/MechanicalGauge/ocr-samples」，方便排查。最多 200 张。
enum OCRSamples {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MechanicalGauge/ocr-samples")
    private static var saved: Int?

    static func save(_ img: CGImage, fast: Int?, accurate: Int) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if saved == nil { saved = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0 }
        guard saved! < 200 else { return }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("\(f.string(from: Date()))_fast-\(fast.map(String.init) ?? "none")_accurate-\(accurate).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        if CGImageDestinationFinalize(dest) { saved! += 1 }
    }
}

// MARK: - 手动挡转速表：读游戏的转速条和档位行（像素分析，不用 OCR）

enum BarGauge {
    private static func rgba(_ img: CGImage) -> (Int, Int, [UInt8])? {
        let w = img.width, h = img.height
        guard w > 2, h > 2, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, Array(UnsafeBufferPointer(start: p, count: w * h * 4)))
    }

    /// 转速条亮了多少（0–1）：从左往右找最右边一段亮着的格子。
    /// 亮格 = 白/淡紫（三个通道都高）或亮红（红区）；没亮的格子是深灰/暗红；
    /// 格子之间的缝隙会透出背景（雪地反光也很亮），所以要求连续几列都亮才算。
    static func fill(_ img: CGImage) -> Double? {
        guard let (w, h, p) = rgba(img) else { return nil }
        let y0 = h / 5, y1 = max(y0 + 1, h * 4 / 5)  // 只看中间 60% 的行
        func lit(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4, r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
            let hi = max(r, g, b), lo = min(r, g, b)
            return (hi > 190 && lo > 170) || (r > 140 && r > g + 60 && r > b + 60)  // 白/淡紫，或亮红（含偏暗的闪烁红）
        }
        let minRun = max(3, (y1 - y0) / 5)
        var run = 0, right = -1
        for x in 0..<w {
            let n = (y0..<y1).filter { lit(x, $0) }.count
            if n * 2 >= (y1 - y0) { run += 1; if run >= minRun { right = x } } else { run = 0 }
        }
        return Double(right + 1) / Double(w)
    }

    /// 当前档位：把档位行平均分成 labels.count 格（R N 1 2 …），数每格里接近纯白的像素（三个通道都 ≥ 225），
    /// 最多的那格就是当前档位。亮着的档位字是纯白的；背景反光（雪地、天空）偏蓝灰，到不了这么白。
    /// 细的 "1" 像素少，所以按数量比、不按平均亮度比。
    static func gear(_ img: CGImage, labels: [String]) -> String? {
        guard labels.count >= 2, let (w, h, p) = rgba(img) else { return nil }
        var counts: [Int] = []
        for i in 0..<labels.count {
            let x0 = w * i / labels.count, x1 = max(x0 + 1, w * (i + 1) / labels.count)
            var n = 0
            for y in 0..<h { for x in x0..<x1 { let k = (y * w + x) * 4; if min(p[k], p[k + 1], p[k + 2]) >= 225 { n += 1 } } }
            counts.append(n)
        }
        let ranked = counts.enumerated().sorted { $0.element > $1.element }
        let minPixels = max(4, w * h / labels.count / 200)
        guard let best = ranked.first, best.element >= minPixels, best.element >= ranked[1].element * 2 else { return nil }
        return labels[best.offset]
    }
}

/// 红线闪烁保持：转速打满后游戏会让转速条白红交替闪，读数在满格和较低值之间来回跳。
///  · 从接近满格掉下来时先等 dropDelay 秒：又回到满格（闪烁）就不显示这次下跌；一直低（换挡）才跟过去；
///  · 最近 window 秒里来回大跳了两次以上 = 正在闪：保持满格，直到连续 release 秒都没回到满格。
struct RedlineHold {
    var window = 1.0, high = 0.9, swing = 0.15, dropDelay = 0.2, release = 0.35
    private var history: [(Date, Double)] = []

    mutating func reset() { history = [] }

    mutating func feed(_ fill: Double, now: Date = Date()) -> Double {
        history.append((now, fill))
        history.removeAll { now.timeIntervalSince($0.0) > window }
        guard fill < high - swing, let lastHigh = history.last(where: { $0.1 >= high }) else { return fill }
        let lowFor = now.timeIntervalSince(lastHigh.0)
        let swings = zip(history, history.dropFirst()).filter { abs($1.1 - $0.1) > swing }.count
        if swings >= 2 && lowFor < release { return 1 }      // 正在闪：直接满格
        if lowFor < dropDelay { return lastHigh.1 }           // 刚掉下来：先停在掉之前的位置
        return fill
    }
}

/// One-Euro 滤波（Casiez 2012）：数值稳定时强力平滑（消掉滚轮最后一位 ±1 的跳动），
/// 变化快时截止频率自动升高、几乎没有延迟（爬升、俯冲照样跟手）。输入用百分比（0–100）。
struct OneEuroFilter {
    var minCutoff = 0.6   // Hz：静止时的平滑程度，越小越稳
    var beta = 0.25       // 速度系数：每秒变化 10% 时截止频率约 3 Hz
    var dCutoff = 1.0
    private var x: Double?, dx = 0.0

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff); return 1 / (1 + tau / dt)
    }

    mutating func reset() { x = nil; dx = 0 }

    mutating func filter(_ v: Double, dt rawDt: Double) -> Double {
        let dt = max(rawDt, 0.001)
        guard let prev = x else { x = v; return v }
        dx += Self.alpha(dCutoff, dt) * ((v - prev) / dt - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let out = prev + Self.alpha(cutoff, dt) * (v - prev)
        x = out; return out
    }
}

// MARK: - 转速表模型

/// 根据车速模拟五挡手动车的发动机转速：
/// 怠速抖动、起步半离合、急加速晚升挡/缓加速早升挡、升挡下冲、降挡补油、加速负载、
/// 发动机抖动（转速越高越明显）、断油回弹。
/// 档位：1 挡 0–20 km/h（15–20 升挡），2 挡 20–40（30–40），3 挡 40–60（50–60），4 挡 60–80（70–80），5 挡 80 以上。
final class TachModel {
    static let idle = 800.0, redline = 7000.0, limiter = 7200.0
    static let upshift: [(Double, Double)] = [(15, 20), (30, 40), (50, 60), (70, 80)]
    static let ratio: [Double] = [225, 112, 75, 56, 32]  // 每 km/h 的转速：升挡区间上沿约 4500 转
    static let downshiftGap = 3.0, fullThrottle = 12.0    // 12 km/h/s 视为油门到底

    private(set) var gear = 1
    private var rpm = idle, noise = 0.0, accel = 0.0, t = 0.0
    private var lastSpeed: Double?
    private var shiftLeft = 0.0, shiftUp = true

    private func gauss() -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1), u2 = Double.random(in: 0..<1)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    func update(speed s: Int?, dt rawDt: Double) -> Double {
        let dt = min(max(rawDt, 0.001), 0.2); t += dt
        let speed = s.map(Double.init) ?? lastSpeed ?? 0
        if let last = lastSpeed {  // 车速是整数，加速度用 0.25 s 低通平滑
            accel += ((speed - last) / dt - accel) * (1 - exp(-dt / 0.25))
        }
        lastSpeed = speed
        let th = min(1, max(0, accel / Self.fullThrottle))

        if gear <= Self.upshift.count {
            let (lo, hi) = Self.upshift[gear - 1]
            if speed >= lo + (hi - lo) * th { gear += 1; shiftLeft = 0.22; shiftUp = true }
        }
        if gear > 1 && speed < Self.upshift[gear - 2].0 - Self.downshiftGap { gear -= 1; shiftLeft = 0.18; shiftUp = false }

        var target = max(Self.idle, speed * Self.ratio[gear - 1])
        if gear == 1 && speed < 12 && th > 0.05 { target = max(target, 1200 + 2200 * th) }  // 起步半离合
        target += 800 * th                                                                   // 加速负载
        let tau: Double
        if shiftLeft > 0 {
            shiftLeft -= dt; target += shiftUp ? -150 : 250; tau = 0.05  // 升挡下冲 / 降挡补油
        } else {
            tau = target > rpm ? 0.09 : 0.16
        }
        target = min(target, Self.limiter)
        rpm += (target - rpm) * (1 - exp(-dt / tau))
        if rpm >= Self.limiter - 30 { rpm -= 300 + 150 * Double.random(in: 0..<1) }  // 断油

        // 发动机抖动：Ornstein-Uhlenbeck 噪声；怠速再叠加慢速起伏
        let sigma = 45 + rpm * 0.012, k = 0.06
        noise += -noise * dt / k + sigma * sqrt(2 * dt / k) * gauss()
        var out = rpm + noise
        if speed < 1 { out += 35 * sin(2 * .pi * 1.3 * t) + 15 * sin(2 * .pi * 3.7 * t) }
        return max(0, out)
    }
}

// MARK: - 截屏

/// 用 SCStream 只截速度数字那一小块（主屏幕，点坐标），每帧做 OCR。
final class SpeedReader: NSObject, SCStreamOutput, SCStreamDelegate {
    /// frames: 收到的完整画面数；missingSince: 最近一次开始读不到数字的时间（读到了就清空）。
    /// 画面不变时 SCStream 可能一帧都不给，所以"没收到新画面"不算读不到。
    struct Snapshot {
        var raw: Int?; var speed: Int?; var frames = 0; var missingSince: Date?; var ms = 0.0; var image: CGImage?
        var fill: Double?; var gear: String?  // 手动挡转速表：转速条亮了多少（0–1）、当前档位
    }
    /// 手动挡转速表：截取范围内转速条和档位行的位置（像素，原点左上）
    private struct BarSetup { var bar: CGRect; var gear: CGRect?; var labels: [String] }
    private var barSetup: BarSetup?  // 只在采集队列上读写
    private var redline = RedlineHold()  // 只在采集队列上读写
    var onError: ((String) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "speed-capture")
    private let ci = CIContext()
    private let lock = NSLock()
    private var snap = Snapshot()
    private var filter = SpeedFilter(limit: 300)
    private var preferAccurate = false  // 只在采集队列上读写
    /// 飞行游戏的滚轮计数器位数固定（"00897" 是 5 位）：记住最近读数的位数，读少了就是漏读。
    private var fixedDigits = false
    private var digitHistory: [Int] = []
    private var expectedDigits: Int? {
        guard fixedDigits, digitHistory.count >= 10 else { return nil }
        let counts = Dictionary(digitHistory.map { ($0, 1) }, uniquingKeysWith: +)
        guard let (d, n) = counts.max(by: { $0.value < $1.value }), n * 10 >= digitHistory.count * 6 else { return nil }
        return d
    }

    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return snap }
    var running: Bool { stream != nil }

    /// limit：超过就当识别错误丢掉；maxJump：单帧变化超过它就用精确模式复核（高度表按满格的 5% 算）；
    /// fixedDigits：数字位数固定的滚轮计数器（飞行游戏）。
    func start(roi: CGRect, limit: Double, maxJump: Int = 25, fixedDigits: Bool = false, fps: Int = 30) async throws {
        await stop()
        reset(limit: limit, maxJump: maxJump)
        lock.lock(); filter.median3 = fixedDigits; lock.unlock()
        queue.sync { self.fixedDigits = fixedDigits; self.digitHistory = []; self.barSetup = nil }
        try await startStream(roi: roi, fps: fps)
    }

    /// 手动挡转速表：一次截取包含转速条和档位行的范围，每帧分别分析。
    func startBar(bar: CGRect, gear: CGRect?, labels: [String], fps: Int = 30) async throws {
        await stop()
        reset(limit: 1e9, maxJump: Int.max / 2)
        let u = gear.map { bar.union($0) } ?? bar
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - u.minX) * scale, y: (r.minY - u.minY) * scale, width: r.width * scale, height: r.height * scale).integral
        }
        let setup = BarSetup(bar: px(bar), gear: gear.map(px), labels: labels)
        queue.sync { self.fixedDigits = false; self.barSetup = setup; self.redline.reset() }
        try await startStream(roi: u, fps: fps)
    }

    private func startStream(roi: CGRect, fps: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw GaugeError(t("No display found", "找不到屏幕")) }
        let cfg = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        cfg.sourceRect = roi
        cfg.width = max(8, Int(roi.width * scale)); cfg.height = max(8, Int(roi.height * scale))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 3; cfg.showsCursor = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    private func reset(limit: Double, maxJump: Int) {
        lock.lock(); snap = Snapshot(); filter = SpeedFilter(limit: limit); filter.maxJump = maxJump; lock.unlock()
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // 画面没变化时是 idle 帧，没有新图：沿用上一次的读数
        if let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete { return }
        guard let pb = sb.imageBuffer else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        let img = ci.createCGImage(CIImage(cvPixelBuffer: pb), from: rect)
        if let b = barSetup {  // 手动挡转速表：像素分析，不用 OCR，约 1 ms
            let fill = img?.cropping(to: b.bar).flatMap(BarGauge.fill).map { redline.feed($0) }
            let gear = b.gear.flatMap { img?.cropping(to: $0) }.flatMap { BarGauge.gear($0, labels: b.labels) }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            lock.lock()
            snap.fill = fill; snap.gear = gear; snap.raw = fill.map { Int(($0 * 1000).rounded()) }
            snap.ms = ms; snap.image = img; snap.frames += 1
            if fill != nil { snap.missingSince = nil } else if snap.missingSince == nil { snap.missingSince = Date() }
            lock.unlock()
            return
        }
        var raw: Int?, verified = false
        if let img {
            let g = SpeedOCR.glyphs(img), glyphs = g?.count ?? 0
            // 字形比读出的位数多 = 漏读了（117 读成 7、00897 读成 0089）。
            // 字形比位数少说明框到了边框之类，字形数不可信，不拿它判断。
            let expected = expectedDigits
            var readDigits: Int?  // 这一帧最终采用的读数的位数（按字面）
            func accurate() -> SpeedOCR.Reading? {
                guard SpeedOCR.accurateReady, let a = SpeedOCR.read(img, accurate: true, band: g), a.digits >= glyphs else { return nil }
                // 精确模式有时把计数器前面的灰色 0 丢掉（"00049" 读成 "49"）：位数不够但和当前值接近，也算对
                lock.lock(); let close = !filter.suspicious(a.value) && filter.value != nil; lock.unlock()
                return a.digits >= (expected ?? 0) || close ? a : nil
            }
            // 三位数时 Fast 常吃掉窄的 "1"：上一帧就靠精确模式的话，这帧直接用精确模式，省掉 Fast 那几毫秒
            if preferAccurate, let a = accurate() {
                raw = a.value; verified = true; readDigits = a.digits
            } else {
                let fastReading = SpeedOCR.read(img), fast = fastReading?.value
                raw = fast; readDigits = fastReading?.digits
                // 漏读了数字（比字形少，或者比计数器固定的位数少），或者和当前值差太多：用精确模式重读同一帧
                let wrongDigits = (glyphs > 0 && (fastReading?.digits ?? 0) < glyphs)
                    || (fastReading != nil && fastReading!.digits < (expected ?? 0))
                lock.lock(); let suspicious = filter.suspicious(fast); lock.unlock()
                if wrongDigits || suspicious {
                    if let a = accurate() {
                        if a.value != fast { OCRSamples.save(img, fast: fast, accurate: a.value) }
                        raw = a.value; verified = true; readDigits = max(a.digits, expected ?? 0)
                    } else if wrongDigits {
                        raw = nil; readDigits = nil  // 读错了又没法复核：这一帧当作没读到，指针保持不动
                    }
                }
            }
            preferAccurate = verified && (raw ?? 0) >= 100
            if fixedDigits, let d = readDigits {
                digitHistory.append(d); if digitHistory.count > 60 { digitHistory.removeFirst() }
            }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        lock.lock()
        snap.raw = raw; snap.speed = filter.feed(raw, verified: verified); snap.ms = ms; snap.image = img; snap.frames += 1
        if raw != nil { snap.missingSince = nil } else if snap.missingSince == nil { snap.missingSince = Date() }
        lock.unlock()
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        stream = nil
        onError?(error.localizedDescription)
    }
}

// MARK: - 框选速度区域

/// 盖在主屏幕上的半透明窗口：拖动鼠标框住速度数字，松开即确定；Esc 取消。
@MainActor
enum RegionPicker {
    /// Non-activating panel: shows over a full-screen game without switching Spaces.
    private final class Panel: NSPanel { override var canBecomeKey: Bool { true } }
    /// The first click starts the drag (no click needed to focus the panel first).
    private final class FirstMouseHost<V: View>: NSHostingView<V> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    private static var window: NSWindow?
    private static var monitor: Any?

    static func pick(_ done: @escaping (CGRect?) -> Void) {
        guard window == nil, let screen = NSScreen.screens.first else { return }  // screens[0] 是主屏幕
        let w = Panel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.isFloatingPanel = true; w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        func finish(_ r: CGRect?) {
            if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil
            window?.orderOut(nil); window = nil
            // 四周留余量：速度变成三位数时会变宽
            done(r.map { $0.insetBy(dx: -$0.height * 0.15, dy: -$0.height * 0.15).integral })
        }
        w.contentView = FirstMouseHost(rootView: PickerView(finish: finish))
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { finish(nil); return nil }  // Esc
            return e
        }
        window = w
        w.orderFrontRegardless(); w.makeKey()  // no NSApp.activate: that would leave the game's full-screen Space
    }

    // Command Line Tools ship without the SwiftUI macro plugin, so no @State here.
    private final class Drag: ObservableObject { @Published var start: CGPoint?; @Published var rect: CGRect = .zero }

    private struct PickerView: View {
        let finish: (CGRect?) -> Void
        @StateObject private var d = Drag()
        var body: some View {
            let rect = d.rect
            return
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.35)
                Rectangle().stroke(Color.red, lineWidth: 2)
                    .background(Color.white.opacity(0.08))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                VStack {
                    Text(t("Drag a box around the number (digits only: not the gear, not scale labels). Esc to cancel.",
                           "拖动鼠标框住数字（只框数字，不要框到档位或旁边刻度），松开即确定；Esc 取消"))
                        .font(.title3.bold()).foregroundStyle(.white)
                        .padding(12).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 60)
                    Spacer()
                }.frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .local)
                .onChanged { g in
                    let s = d.start ?? g.startLocation; d.start = s
                    d.rect = CGRect(x: min(s.x, g.location.x), y: min(s.y, g.location.y),
                                  width: abs(g.location.x - s.x), height: abs(g.location.y - s.y))
                }
                .onEnded { _ in
                    let r = d.rect; d.start = nil
                    finish(r.width >= 5 && r.height >= 5 ? r : nil)
                })
            .ignoresSafeArea()
        }
    }
}
