// QCY Kontrol — QCY MeloBuds Pro için macOS menü çubuğu uygulaması.
// Protokol: github.com/hui1601/quicky (docs/protocol.md) + kendi ölçümlerimiz (fw 2.0.4).
import SwiftUI
import CoreBluetooth

// MARK: - UUID'ler
enum U {
    static let service = CBUUID(string: "A001")
    static let cmd = CBUUID(string: "1001")
    static let notify = CBUUID(string: "1002")
    static let battery = CBUUID(string: "0008")
    static let eq = CBUUID(string: "000B")
    static let keys = CBUUID(string: "000D")
    static let companyLE: [UInt8] = [0x1C, 0x52] // QCY CompanyID 0x521C
}

// MARK: - Model
enum ANCMode: Int { case off = 2, anc = 1, transparency = 3 }

struct ANCScene: Identifiable, Hashable {
    let id: UInt8; let name: String; let levels: Int
}
let ancScenes: [ANCScene] = [
    .init(id: 5, name: "Uyarlanabilir", levels: 1),
    .init(id: 1, name: "İç mekân", levels: 3),
    .init(id: 2, name: "Yolculuk", levels: 3),
    .init(id: 3, name: "Gürültülü", levels: 3),
    .init(id: 4, name: "Rüzgâr", levels: 1),
]

let keyFunctions: [(UInt8, String)] = [
    (0, "Yok"), (1, "Oynat/Durdur"), (2, "Önceki"), (3, "Sonraki"), (4, "Sesli asistan"),
    (5, "Ses +"), (6, "Ses −"), (7, "Oyun modu"), (8, "ANC modu"),
]
let keySlots: [(UInt8, String)] = [
    (1, "Sol tek"), (2, "Sağ tek"), (3, "Sol çift"), (4, "Sağ çift"), (5, "Sol üçlü"), (6, "Sağ üçlü"),
]

let eqFreqs = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
let eqPresets: [(String, [Int])] = [
    ("Düz", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ("Bas güçlü", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
    ("Pop", [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
    ("Rock", [4, 3, 1, -1, -2, -1, 1, 3, 4, 4]),
    ("Yumuşak", [1, 1, 0, 0, 0, 0, -1, -2, -3, -3]),
    ("Klasik", [3, 2, 1, 0, 0, 0, 0, 1, 2, 3]),
    ("Konuşma", [-3, -2, 0, 2, 3, 3, 2, 1, 0, -1]),
]

struct Battery: Equatable { var level: Int; var charging: Bool }

// MARK: - Bluetooth
final class QCYDevice: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Başlatılıyor…"
    @Published var connected = false
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

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var keyRaw: [UInt8] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // Tarama
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: start()
        case .unauthorized: status = "Bluetooth izni yok (Sistem Ayarları › Gizlilik › Bluetooth)"
        case .poweredOff: status = "Bluetooth kapalı"
        default: status = "Bluetooth hazır değil"
        }
    }

    func start() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        if let p = central.retrieveConnectedPeripherals(withServices: [U.service]).first {
            attach(p); return
        }
        status = "Kulaklık aranıyor… (kutuyu aç)"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        guard let md = ad[CBAdvertisementDataManufacturerDataKey] as? Data, md.count >= 10,
              Array(md.prefix(2)) == U.companyLE else { return }
        let b = Array(md.dropFirst(2))
        left = Self.bat(b[5]); right = Self.bat(b[6]); box = Self.bat(b[7])
        c.stopScan()
        attach(p)
    }

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        status = "Bağlanıyor…"
        central.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Servisler okunuyor…"
        p.discoverServices([U.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { reset("Bağlanamadı") }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { reset("Bağlantı koptu") }

    private func reset(_ msg: String) {
        connected = false; peripheral = nil; chars = [:]; status = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
    }

    func reconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) } else { start() }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == U.service }) else { status = "QCY servisi yok"; return }
        p.discoverCharacteristics([U.cmd, U.notify, U.battery, U.eq, U.keys], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] { chars[ch.uuid] = ch }
        guard chars[U.cmd] != nil, let n = chars[U.notify] else { status = "Kumanda kanalı yok"; return }
        p.setNotifyValue(true, for: n)
        if let b = chars[U.battery] { p.setNotifyValue(true, for: b); p.readValue(for: b) }
        if let e = chars[U.eq] { p.readValue(for: e) }
        if let k = chars[U.keys] { p.readValue(for: k) }
        connected = true
        status = "Bağlı"
        refresh()
    }

    func refresh() {
        for id: UInt8 in [0x17, 0x09, 0x16, 0x23, 0x2F] { send(0xFE, [id]) }
        if let b = chars[U.battery] { peripheral?.readValue(for: b) }
    }

    // Gelen veri
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
        default: break
        }
    }

    private func parseFrame(_ d: [UInt8]) {
        guard d.count >= 2, d[0] == 0xFF else { return }
        var i = 2
        while i + 1 < d.count {
            let cmd = d[i], len = Int(d[i + 1])
            guard i + 2 + len <= d.count else { break }
            let p = Array(d[(i + 2)..<(i + 2 + len)])
            handle(cmd, p)
            i += 2 + len
        }
    }

    private func handle(_ cmd: UInt8, _ p: [UInt8]) {
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
        default: break
        }
    }

    static func bat(_ x: UInt8) -> Battery { Battery(level: Int(x & 0x7F), charging: x & 0x80 != 0) }

    // Gönderme
    private func send(_ cmd: UInt8, _ params: [UInt8]) {
        guard let p = peripheral, let c = chars[U.cmd] else { return }
        let body = [cmd, UInt8(params.count)] + params
        p.writeValue(Data([0xFF, UInt8(body.count)] + body), for: c, type: .withoutResponse)
    }

    func setANC(_ mode: ANCMode) {
        ancMode = mode
        switch mode {
        case .off: send(0x17, [0x02, 0x00, 0x00])
        case .anc: applyScene()
        case .transparency: applyTransparency()
        }
    }

    func applyScene() {
        let sc = ancScenes.first { $0.id == ancScene } ?? ancScenes[1]
        let lvl = UInt8(max(0, min(sc.levels - 1, ancLevel - 1)))
        send(0x17, [0x01, sc.id, lvl])
    }

    func applyTransparency() {
        let v = UInt8(max(0, min(6, transLevel - 1)))
        // Firmware kuralı: (3,1,0) yerine (3,2,0) gönderilir.
        send(0x17, v == 0 ? [0x03, 0x02, 0x00] : [0x03, 0x01, v])
    }

    func setGame(_ on: Bool) { gameMode = on; send(0x09, [on ? 0x01 : 0x02]) }
    func setLDAC(_ on: Bool) { ldac = on; send(0x23, [on ? 0x01 : 0x02]) }
    func setBalance(_ v: Double) { send(0x16, [UInt8(max(0, min(100, v.rounded())))]) }

    func writeEQ() {
        guard let p = peripheral, let c = chars[U.eq] else { return }
        let bands = eq.map { UInt8(bitPattern: Int8(max(-8, min(8, $0)))) }
        p.writeValue(Data([eqIndex] + bands), for: c, type: .withoutResponse)
    }

    func setKey(_ slot: UInt8, _ fn: UInt8) {
        keyMap[slot] = fn
        guard let p = peripheral, let c = chars[U.keys] else { return }
        var d = keyRaw.isEmpty ? keySlots.flatMap { [$0.0, keyMap[$0.0] ?? 0] } : keyRaw
        var i = 0, found = false
        while i + 1 < d.count { if d[i] == slot { d[i + 1] = fn; found = true }; i += 2 }
        if !found { d += [slot, fn] }
        keyRaw = d
        p.writeValue(Data(d), for: c, type: .withoutResponse)
    }
}

// MARK: - Arayüz
struct BatteryView: View {
    let title: String; let b: Battery
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: b.charging ? "battery.100.bolt" : icon).foregroundStyle((0..<20).contains(b.level) ? Color.red : Color.primary)
            Text(b.level < 0 ? "–" : "\(b.level)%").font(.system(.body, design: .rounded).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
    var icon: String {
        switch b.level { case ..<0: "battery.0"; case ..<25: "battery.25"; case ..<50: "battery.50"; case ..<75: "battery.75"; default: "battery.100" }
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
                    Text("QCY MeloBuds Pro").font(.headline)
                    Text(dev.status).font(.caption).foregroundStyle(dev.connected ? .green : .secondary)
                }
                Spacer()
                Button { dev.connected ? dev.refresh() : dev.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Yenile")
            }
            HStack {
                BatteryView(title: "Sol", b: dev.left)
                BatteryView(title: "Sağ", b: dev.right)
                BatteryView(title: "Kutu", b: dev.box)
            }
            Divider()
            Picker("", selection: $tab) { Text("Ses").tag(0); Text("Ekolayzır").tag(1); Text("Dokunma").tag(2) }
                .pickerStyle(.segmented).labelsHidden()
            Group {
                switch tab {
                case 0: soundTab
                case 1: eqTab
                default: keysTab
                }
            }.disabled(!dev.connected)
            Divider()
            HStack {
                Text("Protokol: hui1601/quicky").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Çıkış") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    var soundTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mod", selection: Binding(get: { dev.ancMode }, set: { dev.setANC($0) })) {
                Text("Kapalı").tag(ANCMode.off)
                Text("Gürültü eng.").tag(ANCMode.anc)
                Text("Şeffaflık").tag(ANCMode.transparency)
            }.pickerStyle(.segmented)

            if dev.ancMode == .anc {
                Picker("Ortam", selection: Binding(get: { dev.ancScene }, set: { dev.ancScene = $0; dev.applyScene() })) {
                    ForEach(ancScenes) { Text($0.name).tag($0.id) }
                }
                if let sc = ancScenes.first(where: { $0.id == dev.ancScene }), sc.levels > 1 {
                    Picker("Seviye", selection: Binding(get: { dev.ancLevel }, set: { dev.ancLevel = $0; dev.applyScene() })) {
                        ForEach(1...sc.levels, id: \.self) { Text("\($0)").tag($0) }
                    }.pickerStyle(.segmented)
                }
            }
            if dev.ancMode == .transparency {
                HStack {
                    Text("Seviye")
                    Slider(value: Binding(get: { Double(dev.transLevel) }, set: { dev.transLevel = Int($0) }),
                           in: 1...7, step: 1) { e in if !e { dev.applyTransparency() } }
                    Text("\(dev.transLevel)").monospacedDigit().frame(width: 16)
                }
            }
            Toggle("Oyun modu (düşük gecikme)", isOn: Binding(get: { dev.gameMode }, set: { dev.setGame($0) }))
            Toggle("LDAC (Mac'te etkisiz, Android için)", isOn: Binding(get: { dev.ldac }, set: { dev.setLDAC($0) }))
            HStack {
                Text("Denge")
                Text("S").font(.caption)
                Slider(value: $dev.balance, in: 0...100, step: 1) { e in if !e { dev.setBalance(dev.balance) } }
                Text("Sğ").font(.caption)
                Button("Orta") { dev.balance = 50; dev.setBalance(50) }.buttonStyle(.borderless).font(.caption)
            }
        }
    }

    var eqTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu("Hazır ayar") {
                    ForEach(eqPresets, id: \.0) { p in
                        Button(p.0) { dev.eq = p.1; dev.writeEQ() }
                    }
                }.fixedSize()
                Spacer()
                Text("±8 dB").font(.caption).foregroundStyle(.secondary)
            }
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
    }

    var keysTab: some View {
        Grid(alignment: .leading, verticalSpacing: 6) {
            ForEach(keySlots, id: \.0) { slot in
                GridRow {
                    Text(slot.1)
                    Picker("", selection: Binding(get: { dev.keyMap[slot.0] ?? 0 }, set: { dev.setKey(slot.0, $0) })) {
                        ForEach(keyFunctions, id: \.0) { Text($0.1).tag($0.0) }
                    }.labelsHidden()
                }
            }
        }
    }
}

@main
struct QCYKontrolApp: App {
    @StateObject private var dev = QCYDevice()
    var body: some Scene {
        MenuBarExtra {
            ContentView(dev: dev)
        } label: {
            Image(systemName: dev.ancMode == .anc ? "earbuds.case.fill" : "earbuds")
        }
        .menuBarExtraStyle(.window)
    }
}
