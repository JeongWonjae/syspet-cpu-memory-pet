//
//  🐾 SysPet — 맥 화면 아래를 걸어 다니는 픽셀 고양이
//
//  ┌ 컴퓨터 상태 ─────────────────────────────────────────────┐
//  │ CPU   한가 → 잠 · 보통 → 걷기 · 바쁨 → 달리기 · 85%↑ 땀       │
//  │ 메모리 차오를수록 털 색 주황 → 빨강 · 80%↑면 1위 앱 이름을 말함   │
//  │ 네트워크 다운로드 중엔 털실 놀이 · 배터리 낮으면 지침, 충전 중 신남 │
//  └─────────────────────────────────────────────────────────┘
//  ┌ 같이 놀기 ───────────────────────────────────────────────┐
//  │ 마우스 올리기 → 수치 말풍선 · 좌우로 문지르기 → 쓰다듬기(하트)     │
//  │ 클릭 → 폴짝(배고플 땐 밥) · 오른쪽 클릭 → 메뉴                   │
//  │ 바닥 근처 커서 → 쫓아옴 · 가끔 앞 창 위로 올라감 · 밤엔 하품       │
//  └─────────────────────────────────────────────────────────┘
//
//  빌드: ./build.sh   (Swift 파일 하나 + AppKit/IOKit, 외부 의존성 없음)
//
import AppKit
import Darwin
import IOKit.ps

// MARK: - 시스템 수치

class SystemStats {
    private var prevTicks: (busy: UInt64, total: UInt64)?
    private var cpuValue: Double = 0
    private var memValue: Double = 0
    var cpu: Double { cpuValue }        // 0...1
    var memory: Double { memValue }     // 0...1
    private var usedBytes: UInt64 = 0
    let totalBytes = ProcessInfo.processInfo.physicalMemory
    var memUsedGB: Double { Double(usedBytes) / 1_073_741_824 }
    var memTotalGB: Double { Double(totalBytes) / 1_073_741_824 }
    var topApp: (name: String, gb: Double)?                       // 메모리 제일 많이 쓰는 앱
    var downKBps: Double = 0                                       // 받는 속도
    var upKBps: Double = 0                                         // 보내는 속도
    var battery: (level: Double, onAC: Bool, charging: Bool)?      // 배터리 없으면 nil
    private var prevNet: [String: (UInt32, UInt32)] = [:]

    func sample() {
        cpuValue = readCPU() ?? cpuValue
        memValue = readMemory() ?? memValue
        if let n = readNet() { downKBps = n.down; upKBps = n.up }
        battery = readBattery()
    }

    private func readCPU() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for i in 0..<Int(count) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let sys = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        defer { prevTicks = (busy, total) }
        guard let prev = prevTicks, total > prev.total else { return nil }
        return Double(busy - prev.busy) / Double(total - prev.total)
    }

    private func readMemory() -> Double? {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard ok == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        // 활성 상태 보기의 "사용된 메모리"에 가깝게: 앱(활성) + 고정 + 압축
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        usedBytes = min(used, totalBytes)
        return min(1, Double(used) / Double(totalBytes))
    }

    /// 1초 동안 받은·보낸 양(KB/s). Wi-Fi·유선(en*)만 합산 — VPN(utun)은 중복이라 뺌
    private func readNet() -> (down: Double, up: Double)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var down: UInt64 = 0, up: UInt64 = 0
        var cur: [String: (UInt32, UInt32)] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = head
        while let ifa = p {
            p = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            cur[name] = (d.ifi_ibytes, d.ifi_obytes)
            if let old = prevNet[name] {                                   // 32비트 넘침도 처리
                down += UInt64(d.ifi_ibytes &- old.0); up += UInt64(d.ifi_obytes &- old.1)
            }
        }
        let firstTime = prevNet.isEmpty
        prevNet = cur
        return firstTime ? nil : (Double(down) / 1024, Double(up) / 1024)
    }

    private func readBattery() -> (level: Double, onAC: Bool, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0 else { continue }
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (Double(cap) / Double(mx), onAC, d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }

    /// 앱별 메모리(도우미 프로세스는 바깥 .app 기준으로 합침) → 1위
    func sampleTopApp() {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.stride))
        }
        var sums: [String: UInt64] = [:]
        var buf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(max(0, min(Int(got), pids.count))) where pid > 0 {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            let name = path.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
                ?? (path as NSString).lastPathComponent
            sums[name, default: 0] += info.ri_phys_footprint
        }
        if let top = sums.max(by: { $0.value < $1.value }) { topApp = (top.key, Double(top.value) / 1_073_741_824) }
    }
}

// MARK: - 픽셀 스프라이트 (16칸 × 13줄, 오른쪽을 보는 아기 고양이)
// B 털 · I 귀 안쪽 · E 눈 · W 눈 반짝 · L 감은 눈 · C 볼터치 · N 코

enum Sprite {
    static let walkA = [
        "........B.....B.",
        "........BB...BB.",
        "........BIBBBIB.",
        ".......BBBBBBBBB",
        ".......BBEWBBEWB",
        ".......BBEEBBEEB",
        ".......BCBBNBBCB",
        "B.......BBBBBBB.",
        "BB..BBBBBBBBBB..",
        ".BBBBBBBBBBBBB..",
        "...BBBBBBBBBBB..",
        "...BBBBBBBBBBB..",
        "...B.B....B.B...",
    ]
    static let walkB = [
        "........B.....B.",
        "........BB...BB.",
        "........BIBBBIB.",
        ".......BBBBBBBBB",
        ".......BBEWBBEWB",
        ".......BBEEBBEEB",
        ".......BCBBNBBCB",
        ".B......BBBBBBB.",
        "B...BBBBBBBBBB..",
        "BBBBBBBBBBBBBB..",
        "...BBBBBBBBBBB..",
        "...BBBBBBBBBBB..",
        "....B.B..B.B....",
    ]
    static let sleep = [
        "................",
        "................",
        "................",
        "........B.....B.",
        "........BB...BB.",
        "........BIBBBIB.",
        ".......BBBBBBBBB",
        ".......BBLLBBLLB",
        ".......BCBBNBBCB",
        "BB.BBBBBBBBBBBBB",
        ".BBBBBBBBBBBBBB.",
        "..BBBBBBBBBBBBB.",
        "................",
    ]
}

// MARK: - 펫 화면

final class PetView: NSView {
    let stats: SystemStats
    var frameIndex = 0
    var facingRight = true
    var sleeping = false
    var tired = false            // 배터리 부족 → 엎드림
    var charging = false         // 충전 중 → 번개 표시
    var jump: CGFloat = 0
    var showStats = false
    var pinStats = false
    var hearts = 0               // 쓰다듬기 하트 남은 틱
    var food = 0                 // 밥 먹는 중 남은 틱
    var yarn = false             // 다운로드 중 털실 놀이
    var yarnPhase: CGFloat = 0
    var fullness: Double = 1     // 배부름 0...1
    var speech: String?
    var chaseEnabled = true
    var rideEnabled = true
    var onClick: (() -> Void)?
    var onFeed: (() -> Void)?
    let px: CGFloat = 5          // 한 칸 크기
    let spriteW = 16, spriteH = 13

    init(stats: SystemStats, frame: NSRect) {
        self.stats = stats
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func furColor() -> NSColor {
        // 메모리 50% 이하 주황 → 100% 빨강
        let t = max(0, min(1, (stats.memory - 0.5) / 0.5))
        let a = NSColor(srgbRed: 0.93, green: 0.64, blue: 0.36, alpha: 1)
        let b = NSColor(srgbRed: 0.86, green: 0.25, blue: 0.25, alpha: 1)
        return a.blended(withFraction: t, of: b) ?? a
    }

    static let heart = [".X.X.", "XXXXX", "XXXXX", ".XXX.", "..X.."]

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set(); dirtyRect.fill()
        let lying = sleeping || tired
        let rows = lying ? Sprite.sleep : (frameIndex % 2 == 0 ? Sprite.walkA : Sprite.walkB)
        let fur = furColor()
        let ox = (bounds.width - CGFloat(spriteW) * px) / 2
        let floorY = bounds.height - 2
        let oy = floorY - CGFloat(spriteH) * px - jump
        let frontX = facingRight ? ox + CGFloat(spriteW) * px + 4 : ox - 4   // 고양이 앞쪽 바닥
        let grid = rows.map { Array($0) }
        func filled(_ r: Int, _ c: Int) -> Bool { r >= 0 && r < grid.count && c >= 0 && c < spriteW && grid[r][c] != "." }
        func cell(_ r: Int, _ c: Int) -> NSRect {
            let col = facingRight ? c : spriteW - 1 - c
            return NSRect(x: ox + CGFloat(col) * px, y: oy + CGFloat(r) * px, width: px, height: px)
        }
        // 털실 공: 고양이 앞에서 굴러감
        if yarn && !lying {
            let r: CGFloat = 8
            let c = NSPoint(x: frontX + (facingRight ? r : -r), y: floorY - r)
            NSColor(srgbRed: 0.55, green: 0.45, blue: 0.95, alpha: 1).set()
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
            NSColor(white: 1, alpha: 0.7).set()
            for k in 0..<3 {
                let a = yarnPhase + CGFloat(k) * .pi / 3
                let line = NSBezierPath()
                line.move(to: NSPoint(x: c.x - cos(a) * r * 0.8, y: c.y - sin(a) * r * 0.8))
                line.line(to: NSPoint(x: c.x + cos(a) * r * 0.8, y: c.y + sin(a) * r * 0.8))
                line.lineWidth = 1.2; line.stroke()
            }
        }
        // 밥: 앞쪽에 생선
        if food > 0 {
            let fish = "🐟" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18)]
            let s = fish.size(withAttributes: attrs)
            fish.draw(at: NSPoint(x: facingRight ? frontX : frontX - s.width, y: floorY - s.height), withAttributes: attrs)
        }
        // 테두리: 몸 바로 바깥 칸을 진한 털색으로 (귀엽고 또렷하게)
        (fur.shadow(withLevel: 0.45) ?? fur).set()
        for r in -1...grid.count { for c in -1...spriteW where !filled(r, c) {
            if filled(r-1, c) || filled(r+1, c) || filled(r, c-1) || filled(r, c+1) { cell(r, c).fill() }
        } }
        for (r, line) in grid.enumerated() {
            for (c, ch) in line.enumerated() where ch != "." {
                let rect = cell(r, c)
                switch ch {
                case "B", "C", "N", "I", "W", "E", "L": fur.set(); rect.fill()
                default: continue
                }
                switch ch {
                case "I": NSColor(srgbRed: 1, green: 0.72, blue: 0.78, alpha: 1).set(); rect.insetBy(dx: px * 0.15, dy: px * 0.15).fill()
                case "C": NSColor(srgbRed: 1, green: 0.55, blue: 0.62, alpha: 0.75).set(); rect.fill()
                case "N": NSColor(srgbRed: 0.95, green: 0.42, blue: 0.55, alpha: 1).set(); rect.fill()
                case "E": NSColor(white: 0.1, alpha: 1).set(); rect.fill()
                case "W": NSColor(white: 0.1, alpha: 1).set(); rect.fill()
                    NSColor.white.set(); NSRect(x: rect.minX + px * 0.15, y: rect.minY + px * 0.15, width: px * 0.5, height: px * 0.5).fill()
                case "L": NSColor(white: 0.1, alpha: 1).set(); NSRect(x: rect.minX, y: rect.midY, width: px, height: px * 0.4).fill()
                default: break
                }
            }
        }
        let headX = ox + CGFloat(facingRight ? 15 : 0) * px
        // 땀: CPU 85% 이상 또는 메모리 85% 이상
        if !lying && (stats.cpu > 0.85 || stats.memory > 0.85) {
            NSColor(srgbRed: 0.35, green: 0.7, blue: 1, alpha: 1).set()
            let bob = CGFloat(frameIndex % 3) * 2
            NSRect(x: headX + (facingRight ? px : -px), y: oy + 1 * px + bob, width: px, height: px * 1.4).fill()
        }
        // 충전 중: 번개
        if charging {
            ("⚡" as NSString).draw(at: NSPoint(x: facingRight ? ox - 14 : ox + CGFloat(spriteW) * px, y: oy + px * 2),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        // 잠: Zzz
        if sleeping {
            let z = ["z", "Z", "Z"][frameIndex / 4 % 3]
            (z as NSString).draw(at: NSPoint(x: ox + CGFloat(facingRight ? 14 : 0) * px, y: oy - px * 1.5),
                                 withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
        }
        // 쓰다듬기 하트: 머리 위로 올라감
        if hearts > 0 {
            NSColor(srgbRed: 1, green: 0.4, blue: 0.55, alpha: min(1, CGFloat(hearts) / 8)).set()
            let rise = CGFloat(25 - hearts) * 1.4
            for (k, dx) in [CGFloat(-18), 0, 18].enumerated() {
                let hx = headX + dx - 5, hy = oy - 8 - rise - CGFloat(k % 2) * 6
                for (r, line) in Self.heart.enumerated() { for (c, ch) in line.enumerated() where ch == "X" {
                    NSRect(x: hx + CGFloat(c) * 2, y: hy + CGFloat(r) * 2, width: 2, height: 2).fill()
                } }
            }
        }
        // 말풍선: 쓰다듬는 중엔 대사, 마우스 올리면 수치, 그 외엔 대사
        if hearts == 0 && (showStats || pinStats) {
            var lines = [String(format: "CPU %d%%   배부름 %d%%", Int(stats.cpu * 100), Int(fullness * 100)),
                         String(format: "MEM %d%%  %.1f / %.0f GB", Int(stats.memory * 100), stats.memUsedGB, stats.memTotalGB)]
            if let top = stats.topApp { lines.append(String(format: "1위 %@ %.1fGB", String(top.name.prefix(14)), top.gb)) }
            func rate(_ kb: Double) -> String { kb >= 1024 ? String(format: "%.1f MB/s", kb / 1024) : String(format: "%.0f KB/s", kb) }
            lines.append("↓ \(rate(stats.downKBps))   ↑ \(rate(stats.upKBps))")
            bubble(lines.joined(separator: "\n"), dark: true, above: oy)
        } else if let speech {
            bubble(speech, dark: false, above: oy)
        }
    }

    private func bubble(_ s: String, dark: Bool, above oy: CGFloat) {
        let text = s as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: dark ? NSColor.white : NSColor(white: 0.15, alpha: 1)]
        let size = text.size(withAttributes: attrs)
        let w = min(bounds.width, size.width + 16)
        let rect = NSRect(x: (bounds.width - w) / 2, y: max(0, oy - size.height - 12), width: w, height: size.height + 6)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        (dark ? NSColor(white: 0.1, alpha: 0.82) : NSColor(white: 1, alpha: 0.95)).set(); path.fill()
        if !dark { NSColor(white: 0.2, alpha: 0.5).set(); path.lineWidth = 1; path.stroke() }
        text.draw(in: rect.insetBy(dx: 8, dy: 3), withAttributes: attrs)
    }

    // 투명한 곳 클릭은 아래 창으로 통과시키기 위해 고양이 몸 근처만 클릭 영역으로
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let body = NSRect(x: (bounds.width - CGFloat(spriteW) * px) / 2, y: bounds.height - CGFloat(spriteH) * px - 2,
                          width: CGFloat(spriteW) * px, height: CGFloat(spriteH) * px)
        return body.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?(); needsDisplay = true }

    /// 화면 좌표의 마우스가 고양이 몸 위에 있는지 (창이 움직여서 추적 영역 대신 매 틱 직접 확인)
    func isHovered() -> Bool {
        guard let win = window else { return false }
        let p = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        return hitTest(p) != nil   // hitTest 는 상위(창) 좌표를 받음
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        func item(_ title: String, _ sel: Selector, _ on: Bool? = nil) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            if let on { it.state = on ? .on : .off }
            menu.addItem(it)
        }
        item("밥 주기 🐟", #selector(feed))
        menu.addItem(.separator())
        item("수치 항상 보기", #selector(togglePin), pinStats)
        item("커서 쫓아가기", #selector(toggleChase), chaseEnabled)
        item("창 위에 올라타기", #selector(toggleRide), rideEnabled)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "SysPet 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func feed() { onFeed?() }
    @objc private func togglePin() { pinStats.toggle(); needsDisplay = true }
    @objc private func toggleChase() { chaseEnabled.toggle() }
    @objc private func toggleRide() { rideEnabled.toggle() }
}

// MARK: - 움직임

final class PetController {
    let stats = SystemStats()
    let window: NSPanel
    let view: PetView
    var x: CGFloat = 0           // 화면 절대 좌표
    var tick = 0
    let size = NSSize(width: 220, height: 140)

    // 배고픔: 3시간이면 꽉 참. 앱을 껐다 켜도 이어짐
    var hunger: Double
    let hungerPerTick = 1.0 / (3 * 3600 * 10)
    // 말풍선
    var speechTicks = 0
    // 쓰다듬기 감지
    var lastMouse = NSPoint.zero
    var lastMouseMoveTick = -1000
    var petDir = 0
    var petTurns: [Int] = []
    // 창 위에 올라타기
    var rideWindow: CGWindowID?
    var rideUntil = 0
    // 상태 변화 감지
    var wasCharging = false
    var wasNight = false

    init() {
        window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        view = PetView(stats: stats, frame: NSRect(origin: .zero, size: size))
        window.contentView = view

        let d = UserDefaults.standard
        let saved = d.object(forKey: "hunger") as? Double ?? 0
        let at = d.object(forKey: "hungerAt") as? Double ?? Date().timeIntervalSince1970
        hunger = min(1, saved + (Date().timeIntervalSince1970 - at) * 10 * hungerPerTick)

        x = floorFrame.minX + 200
        stats.sample()
        stats.sampleTopApp()
        view.onClick = { [weak self] in self?.click() }
        view.onFeed = { [weak self] in self?.feed() }
        place(y: floorFrame.minY)
        window.orderFrontRegardless()

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.stats.sample() }
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in self?.stats.sampleTopApp() }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.step() }
    }

    private var floorFrame: NSRect { (NSScreen.main ?? NSScreen.screens[0]).visibleFrame }

    private func place(y: CGFloat) { window.setFrameOrigin(NSPoint(x: x, y: y)) }

    private func say(_ text: String, seconds: Double, force: Bool = false) {
        guard force || speechTicks == 0 else { return }
        view.speech = text
        speechTicks = Int(seconds * 10)
    }

    private func click() {
        if hunger > 0.4 { feed() } else { view.jump = 14 }
    }

    private func feed() {
        hunger = 0
        view.food = 30
        view.jump = 10
        say("냠냠! 고마워옹 🐟", seconds: 3, force: true)
        saveHunger()
    }

    private func saveHunger() {
        UserDefaults.standard.set(hunger, forKey: "hunger")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "hungerAt")
    }

    // MARK: 창 위에 올라타기

    /// 지금 앞에 있는 앱의 맨 앞 창
    private func frontWindow() -> CGWindowID? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 && (w[kCGWindowOwnerPID as String] as? pid_t) == front {
            return w[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }

    /// 창 윗변을 걸을 수 있는 구간 (x 최소·최대, 바닥 y). 너무 작거나 화면 위에 붙은 창이면 nil
    private func windowSpan(_ id: CGWindowID) -> (minX: CGFloat, maxX: CGFloat, y: CGFloat)? {
        guard frontWindow() == id,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let bd = list.first?[kCGWindowBounds as String], let b = CGRect(dictionaryRepresentation: bd as! CFDictionary)
        else { return nil }
        let top = NSScreen.screens[0].frame.height - b.minY      // 화면 좌표(아래가 0)로 변환
        let f = floorFrame
        guard b.width >= size.width + 40, top + size.height <= f.maxY, top > f.minY + 80,
              b.minX >= f.minX - 20, b.maxX <= f.maxX + 20 else { return nil }
        return (b.minX, b.maxX - size.width, top)
    }

    // MARK: 한 틱 (0.1초)

    private func step() {
        tick += 1
        let cpu = stats.cpu
        let f = floorFrame
        let mouse = NSEvent.mouseLocation
        if mouse != lastMouse { lastMouseMoveTick = tick }

        // 배터리: 20% 미만 + 전원 안 꽂힘 → 지침, 충전 중 → 신남
        let bat = stats.battery
        let tired = bat.map { !$0.onAC && $0.level < 0.2 } ?? false
        let charging = bat?.charging ?? false
        view.tired = tired
        view.charging = charging
        if charging && !wasCharging { say("충전 중! 신난다 ⚡", seconds: 3, force: true) }
        wasCharging = charging

        // 배고픔
        hunger = min(1, hunger + hungerPerTick)
        view.fullness = 1 - hunger
        if tick % 600 == 0 { saveHunger() }

        // 마우스 올리기 → 수치, 그 위에서 좌우로 문지르기 → 쓰다듬기
        let hovered = view.isHovered()
        view.showStats = hovered
        if hovered {
            let dx = mouse.x - lastMouse.x
            if abs(dx) > 1.5 {
                let dir = dx > 0 ? 1 : -1
                if dir != petDir { petDir = dir; petTurns.append(tick) }
            }
            petTurns.removeAll { tick - $0 > 15 }
            if petTurns.count >= 4 {
                petTurns = []
                view.hearts = 25
                say(["골골골… 💕", "좋아옹~", "더 해줘!"].randomElement()!, seconds: 2.5, force: true)
            }
        }
        lastMouse = mouse

        // 창 위에 올라타기: 가끔 앞 창 윗변으로 폴짝
        var span: (minX: CGFloat, maxX: CGFloat, y: CGFloat) = (f.minX, f.maxX - size.width, f.minY)
        if let id = rideWindow {
            if tick < rideUntil, view.rideEnabled, let s = windowSpan(id) { span = s }
            else { rideWindow = nil; view.jump = 14 }
        } else if view.rideEnabled && tick % 300 == 150 && Int.random(in: 0..<3) == 0 && !view.sleeping && !tired,
                  let id = frontWindow(), let s = windowSpan(id) {
            rideWindow = id
            rideUntil = tick + Int.random(in: 300...700)
            span = s
            view.jump = 14
            say("올라가 볼까?", seconds: 2)
        }

        // 커서 쫓아가기: 바닥 근처에서 커서를 움직이면 달려옴
        var target: CGFloat?
        if view.chaseEnabled && rideWindow == nil && !hovered && !tired && view.food == 0
            && tick - lastMouseMoveTick < 50 && mouse.y >= f.minY && mouse.y < f.minY + 130
            && mouse.x >= f.minX && mouse.x <= f.maxX {
            if abs(mouse.x - (x + size.width / 2)) > 12 { target = mouse.x }
        }

        view.sleeping = cpu < 0.08 && target == nil && !tired
        view.yarn = stats.downKBps > 500
        if view.jump > 0 { view.jump = max(0, view.jump - 3) }
        if view.hearts > 0 { view.hearts -= 1 }
        if view.food > 0 { view.food -= 1 }
        if speechTicks > 0 { speechTicks -= 1; if speechTicks == 0 { view.speech = nil } }

        if let t = target {
            view.facingRight = t > x + size.width / 2
            let dist = abs(t - (x + size.width / 2))
            x += (view.facingRight ? 1 : -1) * min(10, dist)
            view.frameIndex += 1
        } else if !view.sleeping && !hovered && !tired && view.food == 0 {
            // 걷기 1.5px → 달리기 최대 10px (0.1초마다). 배고프거나 털실 놀이 중엔 느릿느릿
            var speed = 1.5 + CGFloat(min(cpu, 1)) * 8.5
            if hunger > 0.7 { speed *= 0.5 }
            if view.yarn { speed = min(speed, 3) }
            x += view.facingRight ? speed : -speed
            if x <= span.minX { view.facingRight = true }
            if x >= span.maxX { view.facingRight = false }
            if tick % 120 == 0 && Int.random(in: 0..<3) == 0 { view.facingRight.toggle() }
            let every = cpu > 0.6 ? 1 : (cpu > 0.3 ? 2 : 3)
            if tick % every == 0 { view.frameIndex += 1 }
            if view.yarn { view.yarnPhase += (view.facingRight ? 1 : -1) * speed * 0.15 }
        } else if tick % 2 == 0 {
            view.frameIndex += 1
        }
        x = min(max(x, span.minX), span.maxX)

        // 충전 중엔 가끔 폴짝
        if charging && !view.sleeping && tick % 40 == 0 { view.jump = 10 }

        // 혼잣말
        let hour = Calendar.current.component(.hour, from: Date())
        let night = hour < 5
        if night && !wasNight { say("하아암… 벌써 12시야. 자러 가자 🌙", seconds: 5) }
        wasNight = night
        if night && tick % 6000 == 3000 { say("하아암… 자러 가자 🌙", seconds: 5) }
        if hunger > 0.7 && tick % 1800 == 300 { say("배고파옹… 클릭해서 밥 줘", seconds: 4) }
        if tired && tick % 1800 == 600 { say("지쳤어… 충전해줘 🔋", seconds: 4) }
        if stats.memory > 0.8 && tick % 3000 == 1200, let top = stats.topApp {
            say(String(format: "%@ %.1fGB 먹는 중!", String(top.name.prefix(14)), top.gb), seconds: 5)
        }

        place(y: span.y)
        view.needsDisplay = true
    }
}

// 확인용: SysPet --snapshot <out.png> → 여러 상태를 한 장으로 그림
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    final class FakeStats: SystemStats {
        var c = 0.0, m = 0.0
        override var cpu: Double { c }
        override var memory: Double { m }
        override var memUsedGB: Double { m * memTotalGB }
    }
    // (CPU, 메모리, 이름표, 상태 꾸미기)
    let cases: [(Double, Double, String, (PetView) -> Void)] = [
        (0.3, 0.4, "걷기 · 다운로드 중 털실 놀이", { $0.yarn = true; $0.yarnPhase = 0.6 }),
        (0.95, 0.6, "CPU 95% · 달리며 땀", { $0.frameIndex = 1 }),
        (0.02, 0.5, "CPU 한가 · 쿨쿨", { $0.sleeping = true; $0.frameIndex = 4 }),
        (0.5, 0.93, "마우스 올리기 · 수치", { $0.showStats = true; $0.stats.topApp = ("Google Chrome", 8.2)
            $0.stats.downKBps = 3200; $0.stats.upKBps = 240; $0.fullness = 0.8 }),
        (0.3, 0.4, "쓰다듬기", { $0.hearts = 15; $0.speech = "골골골… 💕" }),
        (0.3, 0.4, "밥 먹기 · 충전 중", { $0.food = 20; $0.charging = true; $0.speech = "냠냠! 고마워옹 🐟" }),
        (0.3, 0.4, "배고픔", { $0.frameIndex = 1; $0.speech = "배고파옹… 클릭해서 밥 줘" }),
        (0.3, 0.4, "배터리 20% 미만", { $0.tired = true; $0.speech = "지쳤어… 충전해줘 🔋" }),
    ]
    let w: CGFloat = 220, h: CGFloat = 140, cap: CGFloat = 28, gap: CGFloat = 14, cols = 4
    let rows = (cases.count + cols - 1) / cols
    let img = NSImage(size: NSSize(width: gap + CGFloat(cols) * (w + gap), height: gap + CGFloat(rows) * (h + cap + gap)))
    img.lockFocus()
    NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 1).set(); NSRect(origin: .zero, size: img.size).fill()
    let capAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                   .foregroundColor: NSColor(white: 0.35, alpha: 1)]
    for (k, cs) in cases.enumerated() {
        let col = k % cols, row = k / cols
        let card = NSRect(x: gap + CGFloat(col) * (w + gap), y: img.size.height - CGFloat(row + 1) * (h + cap + gap), width: w, height: h + cap)
        NSColor.white.set(); NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
        let s = FakeStats(); s.c = cs.0; s.m = cs.1
        let v = PetView(stats: s, frame: NSRect(x: 0, y: 0, width: w, height: h))
        cs.3(v)
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        rep.draw(in: NSRect(x: card.minX, y: card.minY + cap, width: w, height: h))
        let t = cs.2 as NSString, ts = t.size(withAttributes: capAttrs)
        t.draw(at: NSPoint(x: card.midX - ts.width / 2, y: card.minY + (cap - ts.height) / 2 + 2), withAttributes: capAttrs)
    }
    img.unlockFocus()
    let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// 확인용: SysPet --stats → 실제 수치 한 번 출력
if CommandLine.arguments.contains("--stats") {
    let s = SystemStats(); s.sample(); usleep(1_000_000); s.sample(); s.sampleTopApp()
    print(String(format: "cpu %.0f%% mem %.1f/%.0fGB down %.0fKB/s up %.0fKB/s", s.cpu * 100, s.memUsedGB, s.memTotalGB, s.downKBps, s.upKBps),
          "top:", s.topApp.map { "\($0.name) \(String(format: "%.1f", $0.gb))GB" } ?? "-", "battery:", s.battery.map { "\($0)" } ?? "-")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Dock 아이콘 없이
let controller = PetController()
app.run()
