// QCY Control — macOS menu bar app for QCY earbuds (tested on MeloBuds Pro).
// Protocol: github.com/hui1601/quicky (docs/protocol.md) + our own measurements (fw 2.0.4).
import SwiftUI
import CoreBluetooth
import IOBluetooth
import ServiceManagement
import Combine

// MARK: - UUIDs
enum U {
    /// "A001" protocol (MeloBuds Pro, HT07, …): framed commands on 1001, notifications on 1002.
    static let service = CBUUID(string: "A001")
    static let cmd = CBUUID(string: "1001")
    static let notify = CBUUID(string: "1002")
    static let battery = CBUUID(string: "0008")
    static let eq = CBUUID(string: "000B")
    static let keys = CBUUID(string: "000D")
    /// "A002" protocol (MeloBuds N65, JieLi chip): the same QCY commands wrapped in JieLi RCSP framing,
    /// written to 0001 and notified on 0002. See `sendJieLi` / `parseJieLi`.
    static let serviceA002 = CBUUID(string: "A002")
    static let jlWrite = CBUUID(string: "0001")
    static let jlNotify = CBUUID(string: "0002")
    static let gap = CBUUID(string: "1800")
    static let companyLE: [UInt8] = [0x1C, 0x52] // QCY CompanyID 0x521C
}

// MARK: - Model
enum ANCMode: Int { case off = 2, anc = 1, transparency = 3 }

struct ANCScene: Identifiable, Hashable {
    let id: UInt8; let name: String; let levels: Int
}
let ancScenes: [ANCScene] = [
    .init(id: 5, name: "Adaptive", levels: 1),
    .init(id: 1, name: "Indoor", levels: 3),
    .init(id: 2, name: "Commuting", levels: 3),
    .init(id: 3, name: "Noisy", levels: 3),
    .init(id: 4, name: "Anti-wind", levels: 1),
]

let a001KeyFunctions: [(UInt8, String)] = [
    (0, "None"), (1, "Play/Pause"), (2, "Previous"), (3, "Next"), (4, "Voice assistant"),
    (5, "Volume +"), (6, "Volume −"), (7, "Gaming mode"), (8, "ANC mode"),
]
let a001KeySlots: [(UInt8, String)] = [
    (1, "Left single"), (2, "Right single"), (3, "Left double"), (4, "Right double"), (5, "Left triple"), (6, "Right triple"),
]

let eqFreqs = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
let eqPresets: [(String, [Int])] = [
    ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ("Bass boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
    ("Pop", [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
    ("Rock", [4, 3, 1, -1, -2, -1, 1, 3, 4, 4]),
    ("Soft", [1, 1, 0, 0, 0, 0, -1, -2, -3, -3]),
    ("Classical", [3, 2, 1, 0, 0, 0, 0, 1, 2, 3]),
    ("Vocal", [-3, -2, 0, 2, 3, 3, 2, 1, 0, -1]),
]

struct Battery: Equatable { var level: Int; var charging: Bool }

enum Proto { case a001, jieli }

/// N65 ANC scenes, from QCY's official control panel (modelId 32891): cmd 0x17 = [1, scene, level].
let n65Scenes: [ANCScene] = [
    .init(id: 5, name: "Adaptive", levels: 1),
    .init(id: 1, name: "Noisy", levels: 3),
    .init(id: 2, name: "Commuting", levels: 3),
    .init(id: 3, name: "Indoor", levels: 3),
    .init(id: 4, name: "Anti-wind", levels: 1),
]

/// One parametric EQ band as the N65 stores it (cmd 0x22: freq Hz, gain ×100 dB, Q ×100, filter type; little-endian).
struct PEQBand { let freq: UInt16; let gain: Double; let q: Double; let type: UInt8 }
struct PEQPreset: Identifiable { let id: UInt8; let name: String; let bands: [PEQBand] }

private func peq(_ freq: [UInt16], _ gain: [Double], _ q: [Double], _ type: [UInt8]) -> [PEQBand] {
    (0..<freq.count).map { PEQBand(freq: freq[$0], gain: gain[$0], q: q[$0], type: type[$0]) }
}
/// Official N65 presets (QCY server "sys_eq"). Each includes the earbuds' base tuning; all use master gain −12 dB.
let n65MasterGain = -12.0
let n65Presets: [PEQPreset] = {
    let f8: [UInt16] = [20, 150, 750, 320, 2900, 2000, 10000, 6000]
    let t: [UInt8] = [2, 2, 2, 2, 2, 2, 5, 2, 2]
    let q9 = [0.8, 0.4, 1.5, 1, 0.8, 2, 1.5, 3, 0.7]
    return [
        .init(id: 1, name: "Default", bands: peq(f8, [-11, -12.5, -1, -2, 9.5, 1, 6, -3], Array(q9.prefix(8)), Array(t.prefix(8)))),
        .init(id: 2, name: "Pop", bands: peq(f8 + [50], [-14, -15, -1, -2, 9.5, 1, 6, -3, -2.5], q9, t)),
        .init(id: 3, name: "Heavy Bass", bands: peq([20, 150, 750, 320, 2900, 8000, 10000, 6000, 50], [-8, -11, -1, -2, 7, 4, 6, -3, 3], q9, t)),
        .init(id: 4, name: "Rock", bands: peq([20, 150, 750, 320, 2900, 8000, 10000, 6000, 50], [-8, -15, -2, -3, 9.5, 4, 6, -3, 3],
                                               [0.8, 0.6, 1.5, 1, 0.8, 2, 1.5, 3, 0.7], t)),
        .init(id: 5, name: "Soft", bands: peq(f8 + [50], [-13, -15, 0, -2, 6.5, 2, 6, -3, -1.5], q9, t)),
        .init(id: 6, name: "Classic", bands: peq(f8 + [50], [-8, -11, -1, -2, 9.5, 1, 6, -3, 3], q9, t)),
        .init(id: 13, name: "Game", bands: peq(f8 + [50], [-11, -14, -1, -2, 11, 2, 6, -1, -1.5],
                                               [0.8, 0.4, 1.5, 1, 0.8, 1, 1.5, 3, 1], t)),
    ]
}()
/// Our custom EQ = the Default base tuning (8 bands) + the user's 10 graphic bands (Q 0.7, peaking), sent as 18 bands.
let n65CustomID: UInt8 = 0
let n65CustomFreqs: [UInt16] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

enum EQKind { case graphic10, n65 }

/// What a model supports, so the UI only shows controls that work.
struct Caps {
    let scenes: [ANCScene]
    let eq: EQKind?
    let gameMode: Bool
    /// Parameter byte that turns LDAC off (Pro: 2, N65: 0); nil hides the switch.
    let ldacOff: UInt8?
    /// N65 extras: Dynamic EQ (0x27), Spatial Audio (0x5B), multi-device connection (0x24).
    let n65Extras: Bool
    let keySlots: [(UInt8, String)]
    let keyFunctions: [(UInt8, String)]

    /// MeloBuds Pro and other A001 models.
    static let a001 = Caps(scenes: ancScenes, eq: .graphic10, gameMode: true, ldacOff: 2, n65Extras: false,
                           keySlots: a001KeySlots, keyFunctions: a001KeyFunctions)
    /// MeloBuds N65 (fw 2.0.11). Game mode (0x4A) is left out: the official app warns it reboots the earbuds.
    static let jieli = Caps(
        scenes: n65Scenes, eq: .n65, gameMode: false, ldacOff: 0, n65Extras: true,
        keySlots: a001KeySlots + [(9, "Left hold"), (10, "Right hold")],
        keyFunctions: [(0, "None"), (1, "Play/Pause"), (2, "Previous"), (3, "Next"), (4, "Voice assistant"),
                       (5, "Volume +"), (6, "Volume −"), (0x0B, "Noise control")])
}

// MARK: - Bluetooth
final class QCYDevice: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Starting…" { didSet { if Self.debug { FileHandle.standardError.write("status: \(status)\n".data(using: .utf8)!) } } }
    @Published var connected = false
    @Published var deviceName = "QCY earbuds"
    @Published var left = Battery(level: -1, charging: false)
    @Published var right = Battery(level: -1, charging: false)
    @Published var box = Battery(level: -1, charging: false)
    @Published var ancMode: ANCMode = .off
    @Published var ancScene: UInt8 = 1
    @Published var ancLevel: Int = 2
    @Published var transLevel: Int = 4
    @Published var gameMode = false
    @Published var ldac = false
    @Published var balance: Double = 50
    @Published var eq: [Int] = Array(repeating: 0, count: 10)
    @Published var eqIndex: UInt8 = 1
    @Published var keyMap: [UInt8: UInt8] = [:]
    @Published var caps = Caps.a001
    @Published var dynamicEQ = false
    @Published var spatial: UInt8 = 1 // 1 off, 2 fixed, 3 head tracking
    @Published var multiDevice = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var keyRaw: [UInt8] = []
    private var proto: Proto = .a001
    private var jlSeq: UInt8 = 0
    private var batteryTimer: Timer?
    /// The N65 ignores a noise-mode change that arrives while it is still switching (~1.5 s), so ANC writes are spaced out.
    private var lastANCWrite = Date.distantPast
    private var pendingANC: DispatchWorkItem?

    /// Does the Mac have an audio (Classic Bluetooth) connection to the earbuds? The menu bar icon depends on this.
    @Published var audioConnected = false
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [IOBluetoothUserNotification] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(btConnected(_:device:)))
        for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where Self.isQCY(d) && d.isConnected() {
            watch(d)
        }
    }

    /// The audio device only — not the separate BLE control link some models add (e.g. "QCY MeloBuds N65-APP"),
    /// which drops and comes back on its own (e.g. when Spatial Audio changes) and must not hide the menu icon.
    static func isQCY(_ d: IOBluetoothDevice) -> Bool {
        let n = (d.name ?? "").uppercased()
        return n.contains("QCY") && !n.hasSuffix("-APP")
    }

    @objc private func btConnected(_ n: IOBluetoothUserNotification, device d: IOBluetoothDevice) {
        guard Self.isQCY(d) else { return }
        watch(d)
    }

    private func watch(_ d: IOBluetoothDevice) {
        if let n = d.register(forDisconnectNotification: self, selector: #selector(btDisconnected(_:device:))) {
            disconnectNotes.append(n)
        }
        if let name = d.name, !name.isEmpty { deviceName = name }
        audioConnected = true
        start()
    }

    @objc private func btDisconnected(_ n: IOBluetoothUserNotification, device d: IOBluetoothDevice) {
        n.unregister()
        disconnectNotes.removeAll { $0 === n }
        audioConnected = false
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        connected = false; peripheral = nil; chars = [:]
        batteryTimer?.invalidate(); batteryTimer = nil
        status = "Earbuds not connected"
    }

    // Scanning
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: start()
        case .unauthorized: status = "No Bluetooth permission (System Settings › Privacy & Security › Bluetooth)"
        case .poweredOff: status = "Bluetooth is off"
        default: status = "Bluetooth not ready"
        }
    }

    func start() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        guard audioConnected else { status = "Earbuds not connected"; return }
        if let p = central.retrieveConnectedPeripherals(withServices: [U.service]).first {
            attach(p); return
        }
        // Earbuds already linked over BLE but without the A001 service (e.g. N65, which uses A002).
        if let p = central.retrieveConnectedPeripherals(withServices: [U.gap])
            .first(where: { ($0.name ?? "").uppercased().contains("QCY") }) {
            attach(p); return
        }
        status = "Searching for earbuds… (open the case)"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let md = ad[CBAdvertisementDataManufacturerDataKey] as? Data
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        if let md, md.count >= 10, Array(md.prefix(2)) == U.companyLE {
            let b = Array(md.dropFirst(2))
            left = Self.bat(b[5]); right = Self.bat(b[6]); box = Self.bat(b[7])
        } else if !(name.uppercased().contains("QCY") && name.uppercased().hasSuffix("-APP")) {
            return
        }
        c.stopScan()
        attach(p)
    }

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        status = "Connecting…"
        central.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Reading services…"
        p.discoverServices([U.service, U.serviceA002])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { reset("Couldn't connect") }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { reset("Connection lost") }

    private func reset(_ msg: String) {
        connected = false; peripheral = nil; chars = [:]; status = msg; outbox.removeAll()
        batteryTimer?.invalidate(); batteryTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
    }

    func reconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) } else { start() }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        if let s = services.first(where: { $0.uuid == U.service }) {
            proto = .a001; caps = .a001
            p.discoverCharacteristics([U.cmd, U.notify, U.battery, U.eq, U.keys], for: s)
        } else if let s = services.first(where: { $0.uuid == U.serviceA002 }) {
            proto = .jieli; caps = .jieli; ancScene = 5
            p.discoverCharacteristics([U.jlWrite, U.jlNotify], for: s)
        } else {
            status = "QCY control service not found"
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] { chars[ch.uuid] = ch }
        switch proto {
        case .a001:
            guard chars[U.cmd] != nil, let n = chars[U.notify] else { status = "Control channel not found"; return }
            p.setNotifyValue(true, for: n)
            if let b = chars[U.battery] { p.setNotifyValue(true, for: b); p.readValue(for: b) }
            if let e = chars[U.eq] { p.readValue(for: e) }
            if let k = chars[U.keys] { p.readValue(for: k) }
            connected = true
            status = "Connected"
            refresh()
            startPolling()
        case .jieli:
            guard chars[U.jlWrite] != nil, let n = chars[U.jlNotify] else { status = "Control channel not found"; return }
            p.setNotifyValue(true, for: n) // continues in didUpdateNotificationStateFor
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard proto == .jieli, ch.uuid == U.jlNotify, ch.isNotifying else { return }
        connected = true
        status = "Connected"
        // The first command right after subscribing is sometimes dropped, so lead with a harmless version query.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.send(0xFE, [0x30])
            self?.refresh()
        }
        // …and ask once more a little later, after the earbuds have settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.refresh() }
        startPolling()
    }

    /// Battery changes (buds into the case, case on the charger, …) are not always pushed, so poll them.
    private func startPolling() {
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.pollBattery() }
    }

    func pollBattery() {
        switch proto {
        case .a001: if let b = chars[U.battery] { peripheral?.readValue(for: b) }
        case .jieli: send(0xFE, [0x2F])
        }
    }

    func refresh() {
        switch proto {
        case .a001:
            for id: UInt8 in [0x17, 0x09, 0x16, 0x23, 0x2F] { send(0xFE, [id]) }
            if let b = chars[U.battery] { peripheral?.readValue(for: b) }
        case .jieli:
            for id: UInt8 in [0x17, 0x16, 0x2F, 0x2B, 0x22, 0x27, 0x5B, 0x23, 0x24] { send(0xFE, [id]) }
        }
    }

    // Incoming data
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value.map(Array.init) else { return }
        switch ch.uuid {
        case U.battery where d.count >= 3:
            left = Self.bat(d[0]); right = Self.bat(d[1]); box = Self.bat(d[2])
        case U.eq where d.count >= 11:
            eqIndex = d[0]; eq = d[1...10].map { Int(Int8(bitPattern: $0)) }
        case U.keys:
            keyRaw = d
            var m: [UInt8: UInt8] = [:]
            var i = 0
            while i + 1 < d.count { if d[i] != 0 { m[d[i]] = d[i + 1] }; i += 2 }
            keyMap = m
        case U.notify:
            parseFrame(d)
        case U.jlNotify:
            parseJieLi(d)
        default: break
        }
    }

    /// A001 frame: FF <len> <cmd><plen><params>…
    private func parseFrame(_ d: [UInt8]) {
        guard d.count >= 2, d[0] == 0xFF else { return }
        parseTLVs(Array(d[2...]))
    }

    /// JieLi RCSP frame: FE DC BA <flag> FF <lenH><lenL> [status] <seq> <cmd><plen><params>… EF
    /// flag bit 7 set = pushed by the earbuds (no status byte); clear = reply to our command (status 0 = OK).
    private func parseJieLi(_ d: [UInt8]) {
        guard d.count >= 9, d[0] == 0xFE, d[1] == 0xDC, d[2] == 0xBA, d[4] == 0xFF, d.last == 0xEF else { return }
        let isPush = d[3] & 0x80 != 0
        let start = isPush ? 8 : 9
        if !isPush && d[7] != 0 { return }
        guard start < d.count - 1 else { return }
        parseTLVs(Array(d[start..<(d.count - 1)]))
    }

    private func parseTLVs(_ d: [UInt8]) {
        var i = 0
        while i + 1 < d.count {
            let cmd = d[i], len = Int(d[i + 1])
            guard i + 2 + len <= d.count else { break }
            let p = Array(d[(i + 2)..<(i + 2 + len)])
            handle(cmd, p)
            i += 2 + len
        }
    }

    private func handle(_ cmd: UInt8, _ p: [UInt8]) {
        if Self.debug { FileHandle.standardError.write((String(format: "rx %02X: ", cmd) + p.map { String(format: "%02x", $0) }.joined(separator: " ") + "\n").data(using: .utf8)!) }
        switch (cmd, p.count) {
        case (0x17, 3...):
            switch p[0] {
            case 1: ancMode = .anc; ancScene = p[1]; ancLevel = Int(p[2]) + 1
            case 3: ancMode = .transparency; transLevel = Int(p[2]) + 1
            default: ancMode = .off
            }
        case (0x0C, 1...): if p[0] == 0 { ancMode = .off }
        case (0x09, 1...): gameMode = p[0] == 1
        case (0x23, 1...): ldac = p[0] == 1
        case (0x16, 1...): balance = Double(p[0])
        case (0x2F, 3...): left = Self.bat(p[0]); right = Self.bat(p[1]); box = Self.bat(p[2])
        case (0x22, 3...) where proto == .jieli: // parametric EQ: [index, master(2), n × 7-byte bands]
            eqIndex = p[0]
            let n = (p.count - 3) / 7
            if p[0] == n65CustomID && n == 18 {
                eq = (8..<18).map { i in
                    let o = 3 + i * 7 + 2
                    return Int((Double(Int16(bitPattern: UInt16(p[o]) | UInt16(p[o + 1]) << 8)) / 100).rounded())
                }
            }
        case (0x27, 1...): dynamicEQ = p[0] == 1
        case (0x5B, 1...): spatial = p[0]
        case (0x24, 1...): multiDevice = p[0] == 1
        case (0x2B, 2...): // key map as [keyId, funcId] pairs (N65); ids ≥ 0x41 are not touch gestures
            var m: [UInt8: UInt8] = [:]
            var i = 0
            while i + 1 < p.count { if p[i] != 0 && p[i] < 0x41 { m[p[i]] = p[i + 1] }; i += 2 }
            keyMap = m
        default: break
        }
    }

    /// Set QCY_DEBUG=1 to log every decoded command (useful for supporting new models).
    static let debug = ProcessInfo.processInfo.environment["QCY_DEBUG"] == "1"

    static func bat(_ x: UInt8) -> Battery { Battery(level: Int(x & 0x7F), charging: x & 0x80 != 0) }

    // Sending
    /// Outgoing frames are queued and sent one at a time: a burst of back-to-back writes (e.g. the status queries
    /// right after connecting) gets partly dropped, which left the panel stale until "Refresh" was pressed.
    private var outbox: [(Data, CBUUID)] = []
    private var pumping = false
    private let sendGap: TimeInterval = 0.15

    private func send(_ cmd: UInt8, _ params: [UInt8]) {
        let body = [cmd, UInt8(params.count)] + params
        switch proto {
        case .a001:
            enqueue(Data([0xFF, UInt8(body.count)] + body), U.cmd)
        case .jieli:
            jlSeq &+= 1
            let payload = [jlSeq] + body
            // flag C0 = command that wants a reply; opcode FF = vendor (QCY) data
            let frame = [0xFE, 0xDC, 0xBA, 0xC0, 0xFF, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload + [0xEF]
            enqueue(Data(frame), U.jlWrite)
        }
    }

    private func enqueue(_ d: Data, _ ch: CBUUID) {
        guard peripheral != nil else { return }
        outbox.append((d, ch))
        if !pumping { pump() }
    }

    private func pump() {
        guard !outbox.isEmpty, let p = peripheral else { pumping = false; outbox.removeAll(); return }
        pumping = true
        let (d, uuid) = outbox.removeFirst()
        if let c = chars[uuid] { p.writeValue(d, for: c, type: .withoutResponse) }
        DispatchQueue.main.asyncAfter(deadline: .now() + sendGap) { [weak self] in self?.pump() }
    }

    /// Sends an ANC (0x17) setting, at least 2 s after the previous one; only the latest pending change is kept.
    private func sendANC(_ params: [UInt8]) {
        pendingANC?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastANCWrite = Date()
            self.send(0x17, params)
            // Re-read the real state in case the earbuds ignored it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.send(0xFE, [0x17]) }
        }
        pendingANC = work
        let wait = max(0, 2.0 - Date().timeIntervalSince(lastANCWrite))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    func setANC(_ mode: ANCMode) {
        ancMode = mode
        switch mode {
        case .off: sendANC([0x02, 0x00, 0x00])
        case .anc: applyScene()
        case .transparency: applyTransparency()
        }
    }

    func applyScene() {
        let sc = caps.scenes.first { $0.id == ancScene } ?? caps.scenes[0]
        let lvl = UInt8(max(0, min(sc.levels - 1, ancLevel - 1)))
        sendANC([0x01, sc.id, lvl])
    }

    func applyTransparency() {
        let v = UInt8(max(0, min(6, transLevel - 1)))
        // Firmware quirk (MeloBuds Pro and N65): send (3,2,0) instead of (3,1,0).
        sendANC(v == 0 ? [0x03, 0x02, 0x00] : [0x03, 0x01, v])
    }

    func setGame(_ on: Bool) { gameMode = on; send(0x09, [on ? 0x01 : 0x02]) }
    func setLDAC(_ on: Bool) { ldac = on; send(0x23, [on ? 0x01 : (caps.ldacOff ?? 0x02)]) }
    func setBalance(_ v: Double) { send(0x16, [UInt8(max(0, min(100, v.rounded())))]) }

    // N65 extras
    func setDynamicEQ(_ on: Bool) { dynamicEQ = on; send(0x27, [on ? 0x01 : 0x00]) }
    /// Changing it restarts the N65's BLE control link for a few seconds (we reconnect automatically),
    /// and the earbuds leave Adaptive ANC while spatial audio is on.
    func setSpatial(_ v: UInt8) { spatial = v; send(0x5B, [v]) }
    /// Restarts the earbuds.
    func setMultiDevice(_ on: Bool) { multiDevice = on; send(0x24, [on ? 0x01 : 0x00]) }

    func setN65Preset(_ id: UInt8) {
        eqIndex = id
        if id == n65CustomID { writeEQ(); return }
        guard let pr = n65Presets.first(where: { $0.id == id }) else { return }
        sendPEQ(index: id, bands: pr.bands)
    }

    private func sendPEQ(index: UInt8, bands: [PEQBand]) {
        func le(_ v: Int) -> [UInt8] { let u = UInt16(bitPattern: Int16(clamping: v)); return [UInt8(u & 0xFF), UInt8(u >> 8)] }
        var params: [UInt8] = [index] + le(Int(n65MasterGain * 100))
        for b in bands {
            params += le(Int(b.freq)) + le(Int((b.gain * 100).rounded())) + le(Int((b.q * 100).rounded())) + [b.type]
        }
        send(0x22, params)
        dynamicEQ = false // the N65 switches Dynamic EQ off whenever an EQ is written
    }

    func writeEQ() {
        if proto == .jieli {
            let base = n65Presets[0].bands
            let user = zip(n65CustomFreqs, eq).map { PEQBand(freq: $0, gain: Double(max(-8, min(8, $1))), q: 0.7, type: 2) }
            eqIndex = n65CustomID
            sendPEQ(index: n65CustomID, bands: base + user)
            return
        }
        guard let p = peripheral, let c = chars[U.eq] else { return }
        let bands = eq.map { UInt8(bitPattern: Int8(max(-8, min(8, $0)))) }
        p.writeValue(Data([eqIndex] + bands), for: c, type: .withoutResponse)
    }

    func setKey(_ slot: UInt8, _ fn: UInt8) {
        keyMap[slot] = fn
        if proto == .jieli { send(0x2B, [slot, fn]); return }
        guard let p = peripheral, let c = chars[U.keys] else { return }
        var d = keyRaw.isEmpty ? a001KeySlots.flatMap { [$0.0, keyMap[$0.0] ?? 0] } : keyRaw
        var i = 0, found = false
        while i + 1 < d.count { if d[i] == slot { d[i + 1] = fn; found = true }; i += 2 }
        if !found { d += [slot, fn] }
        keyRaw = d
        p.writeValue(Data(d), for: c, type: .withoutResponse)
    }
}

// MARK: - UI
struct BatteryView: View {
    let title: String; let b: Battery
    /// A reading the earbuds are only repeating (the case, while no bud is inside it).
    var stale = false
    /// 0 % without charging means "no report" (e.g. a bud that is off or out of range), not an empty battery.
    private var level: Int { b.level == 0 && !b.charging ? -1 : b.level }
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: b.charging ? "battery.100.bolt" : icon)
                .foregroundStyle(stale || level < 0 ? Color.secondary : (level < 20 ? Color.red : Color.primary))
            Text(level < 0 ? "–" : "\(level)%").font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(stale ? Color.secondary : Color.primary)
            Text(stale && level >= 0 ? "\(title) · last known" : title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help(stale ? "The case reports only while an earbud is inside it. This is the last value it sent." : "")
    }
    var icon: String {
        switch level { case ..<0: "battery.0"; case ..<25: "battery.25"; case ..<50: "battery.50"; case ..<75: "battery.75"; default: "battery.100" }
    }
}

struct ContentView: View {
    @ObservedObject var dev: QCYDevice
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "earbuds").font(.title2)
                VStack(alignment: .leading) {
                    Text(dev.deviceName).font(.headline)
                    Text(dev.status).font(.caption).foregroundStyle(dev.connected ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { dev.connected ? dev.refresh() : dev.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            HStack {
                BatteryView(title: "Left", b: dev.left)
                BatteryView(title: "Right", b: dev.right)
                BatteryView(title: "Case", b: dev.box, stale: !(dev.left.charging || dev.right.charging || dev.box.charging))
            }
            Divider()
            Picker("", selection: $tab) {
                Text("Sound").tag(0)
                if dev.caps.eq != nil { Text("Equalizer").tag(1) }
                Text("Touch").tag(2)
            }
                .pickerStyle(.segmented).labelsHidden()
            Group {
                switch tab {
                case 1 where dev.caps.eq != nil: eqTab
                case 2: keysTab
                default: soundTab
                }
            }.disabled(!dev.connected)
            Divider()
            HStack {
                Toggle("Launch at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                )).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    var soundTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: Binding(get: { dev.ancMode }, set: { dev.setANC($0) })) {
                Text("Off").tag(ANCMode.off)
                Text("ANC").tag(ANCMode.anc)
                Text("Transparency").tag(ANCMode.transparency)
            }.pickerStyle(.segmented)

            if dev.ancMode == .anc && dev.caps.scenes.count > 1 {
                Picker("Scene", selection: Binding(get: { dev.ancScene }, set: { dev.ancScene = $0; dev.applyScene() })) {
                    ForEach(dev.caps.scenes) { Text($0.name).tag($0.id) }
                }
                if let sc = dev.caps.scenes.first(where: { $0.id == dev.ancScene }), sc.levels > 1 {
                    Picker("Level", selection: Binding(get: { dev.ancLevel }, set: { dev.ancLevel = $0; dev.applyScene() })) {
                        ForEach(1...sc.levels, id: \.self) { Text("\($0)").tag($0) }
                    }.pickerStyle(.segmented)
                }
            }
            if dev.ancMode == .transparency {
                HStack {
                    Text("Level")
                    Slider(value: Binding(get: { Double(dev.transLevel) }, set: { dev.transLevel = Int($0) }),
                           in: 1...7, step: 1) { e in if !e { dev.applyTransparency() } }
                    Text("\(dev.transLevel)").monospacedDigit().frame(width: 16)
                }
            }
            if dev.caps.n65Extras {
                Picker("Spatial audio", selection: Binding(get: { dev.spatial }, set: { dev.setSpatial($0) })) {
                    Text("Off").tag(UInt8(1)); Text("Fixed").tag(UInt8(2)); Text("Head tracking").tag(UInt8(3))
                }
            }
            if dev.caps.gameMode {
                Toggle("Gaming mode (low latency)", isOn: Binding(get: { dev.gameMode }, set: { dev.setGame($0) }))
            }
            if dev.caps.ldacOff != nil {
                Toggle("LDAC (no effect on Mac; for Android)", isOn: Binding(get: { dev.ldac }, set: { dev.setLDAC($0) }))
                    .help(dev.caps.n65Extras ? "Restarts the earbuds. LDAC disables multi-device connection and spatial audio." : "")
            }
            if dev.caps.n65Extras {
                Toggle("Multi-device connection", isOn: Binding(get: { dev.multiDevice }, set: { dev.setMultiDevice($0) }))
                    .help("Restarts the earbuds. Not available while LDAC is on.")
                if dev.ldac || dev.multiDevice {
                    Text("Changing LDAC or multi-device restarts the earbuds.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Balance")
                Text("L").font(.caption)
                Slider(value: $dev.balance, in: 0...100, step: 1) { e in if !e { dev.setBalance(dev.balance) } }
                Text("R").font(.caption)
                Button("Center") { dev.balance = 50; dev.setBalance(50) }.buttonStyle(.borderless).font(.caption)
            }
        }
    }

    var eqTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dev.caps.eq == .n65 {
                Picker("Preset", selection: Binding(get: { dev.eqIndex }, set: { dev.setN65Preset($0) })) {
                    ForEach(n65Presets) { Text($0.name).tag($0.id) }
                    Text("Custom").tag(n65CustomID)
                    if dev.eqIndex != n65CustomID && !n65Presets.contains(where: { $0.id == dev.eqIndex }) {
                        Text("Other").tag(dev.eqIndex)
                    }
                }
                Toggle("Dynamic EQ", isOn: Binding(get: { dev.dynamicEQ }, set: { dev.setDynamicEQ($0) }))
                if dev.eqIndex == n65CustomID {
                    Text("Custom adds these bands on top of the Default tuning.").font(.caption2).foregroundStyle(.secondary)
                    eqSliders
                }
            } else {
                graphicEQ
            }
        }
    }

    var graphicEQ: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu("Presets") {
                    ForEach(eqPresets, id: \.0) { p in
                        Button(p.0) { dev.eq = p.1; dev.writeEQ() }
                    }
                }.fixedSize()
                Spacer()
                Text("±8 dB").font(.caption).foregroundStyle(.secondary)
            }
            eqSliders
        }
    }

    var eqSliders: some View {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 4) {
                        Text("\(dev.eq[i] > 0 ? "+" : "")\(dev.eq[i])").font(.caption2).monospacedDigit()
                        Slider(value: Binding(get: { Double(dev.eq[i]) }, set: { dev.eq[i] = Int($0) }),
                               in: -8...8, step: 1) { e in if !e { dev.writeEQ() } }
                            .rotationEffect(.degrees(-90))
                            .frame(width: 110, height: 24)
                            .frame(width: 26, height: 110)
                        Text(eqFreqs[i]).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
    }

    var keysTab: some View {
        Grid(alignment: .leading, verticalSpacing: 6) {
            ForEach(dev.caps.keySlots, id: \.0) { slot in
                GridRow {
                    Text(slot.1)
                    let current = dev.keyMap[slot.0] ?? 0
                    Picker("", selection: Binding(get: { current }, set: { dev.setKey(slot.0, $0) })) {
                        ForEach(dev.caps.keyFunctions, id: \.0) { Text($0.1).tag($0.0) }
                        // Keep a function this app doesn't know about visible instead of showing a blank picker.
                        if !dev.caps.keyFunctions.contains(where: { $0.0 == current }) {
                            Text(String(format: "Other (0x%02X)", current)).tag(current)
                        }
                    }.labelsHidden()
                }
            }
        }
    }
}

@main
struct QCYControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() } // everything lives in the menu bar item (see AppDelegate)
    }
}

/// Owns the menu bar item. It is created once and, while the earbuds are disconnected, collapsed to zero width
/// instead of removed. Removing it — SwiftUI's `MenuBarExtra(isInserted:)`, and even `isVisible = false` — makes
/// macOS delete the position the user dragged it to, so tools like Hidden Bar put it back into the hidden section
/// on every reconnect. A zero-width item keeps its slot and its saved position.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let dev = QCYDevice()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var watch: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        // On first run, register to launch at login (can be turned off in System Settings › General › Login Items).
        let key = "loginItemRegistered"
        if !UserDefaults.standard.bool(forKey: key) {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "QCYControl" // stable name → macOS remembers the item's position
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "earbuds", accessibilityDescription: "QCY Control")
            b.image?.isTemplate = true
            b.target = self
            b.action = #selector(togglePopover)
        }

        let host = NSHostingController(rootView: ContentView(dev: dev))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient

        // The icon is shown only while the earbuds are connected to the Mac.
        item.isVisible = true // undo a hidden state an older build may have saved
        watch = dev.$audioConnected.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] on in
            guard let self else { return }
            if !on { self.popover.performClose(nil) }
            self.item.length = on ? NSStatusItem.squareLength : 0
            self.item.button?.isHidden = !on
        }
    }

    @objc private func togglePopover() {
        guard let b = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if dev.connected { dev.refresh() }
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
