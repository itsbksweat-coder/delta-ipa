import SwiftUI
import UIKit
import Foundation
import Darwin

struct RokuDevice: Identifiable, Hashable {
    let ip: String
    let name: String
    let model: String

    var id: String { ip }
}

final class RokuInfoParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""
    private var values: [String: String] = [:]

    static func parse(_ data: Data) -> [String: String] {
        let delegate = RokuInfoParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.values
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            values[elementName] = value
        }
        currentElement = ""
        currentText = ""
    }
}

enum RokuDiscovery {
    struct InterfaceInfo: Hashable {
        let name: String
        let ip: String
        let netmask: String
    }

    struct ScanPlan {
        let interfaces: [InterfaceInfo]
        let candidates: [String]
        let summary: String
    }

    private static func ipv4String(_ address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: host)
    }

    static func privateIPv4Interfaces() -> [InterfaceInfo] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [InterfaceInfo] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first

        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            guard
                let address = current.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET),
                let ip = ipv4String(address),
                let maskAddress = current.pointee.ifa_netmask,
                let mask = ipv4String(maskAddress)
            else { continue }

            let interface = String(cString: current.pointee.ifa_name)

            guard interface != "lo0", isPrivateIPv4(ip) else { continue }

            results.append(InterfaceInfo(name: interface, ip: ip, netmask: mask))
        }

        // Prefer Wi-Fi first, then dedupe by IP.
        results.sort {
            if $0.name == "en0" && $1.name != "en0" { return true }
            if $1.name == "en0" && $0.name != "en0" { return false }
            return $0.name < $1.name
        }

        var seen = Set<String>()
        return results.filter { seen.insert($0.ip).inserted }
    }

    static func isPrivateIPv4(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }

        if p[0] == 10 { return true }
        if p[0] == 172 && (16...31).contains(p[1]) { return true }
        if p[0] == 192 && p[1] == 168 { return true }
        return false
    }

    private static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let p = ip.split(separator: ".").compactMap { UInt32($0) }
        guard p.count == 4, p.allSatisfy({ $0 <= 255 }) else { return nil }
        return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]
    }

    private static func uint32ToIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }

    static func makeScanPlan() -> ScanPlan {
        let interfaces = privateIPv4Interfaces()
        var candidates = Set<String>()
        var descriptions: [String] = []

        for info in interfaces {
            guard
                let ipValue = ipv4ToUInt32(info.ip),
                let maskValue = ipv4ToUInt32(info.netmask)
            else { continue }

            let network = ipValue & maskValue
            let broadcast = network | ~maskValue
            let hostCount = broadcast > network ? Int(broadcast - network - 1) : 0

            // Scan the real subnet when reasonably sized.
            // For unusually large networks, scan a 2048-address window centered around the phone.
            if hostCount > 0 && hostCount <= 2048 {
                let first = network + 1
                let last = broadcast - 1
                if first <= last {
                    for value in first...last {
                        if value != ipValue {
                            candidates.insert(uint32ToIPv4(value))
                        }
                    }
                    descriptions.append("\(info.ip) / \(info.netmask) • \(hostCount) hosts")
                }
            } else {
                let lower = max(network + 1, ipValue > 1024 ? ipValue - 1024 : network + 1)
                let upper = min(broadcast - 1, ipValue + 1024)

                if lower <= upper {
                    for value in lower...upper {
                        if value != ipValue {
                            candidates.insert(uint32ToIPv4(value))
                        }
                    }
                    descriptions.append("\(info.ip) / \(info.netmask) • nearby 2048 hosts")
                }
            }

            // Also scan the phone's /24 as a fallback for odd netmask reporting.
            let octets = info.ip.split(separator: ".")
            if octets.count == 4 {
                let prefix = "\(octets[0]).\(octets[1]).\(octets[2])"
                for host in 1...254 {
                    let candidate = "\(prefix).\(host)"
                    if candidate != info.ip {
                        candidates.insert(candidate)
                    }
                }
            }
        }

        let summary: String
        if interfaces.isEmpty {
            summary = "No private Wi-Fi IPv4 address detected. Check iOS Local Network permission and Wi-Fi."
        } else {
            summary = descriptions.joined(separator: "\n")
        }

        return ScanPlan(
            interfaces: interfaces,
            candidates: candidates.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            summary: summary
        )
    }

    static func probe(ip: String) async -> RokuDevice? {
        guard let url = URL(string: "http://\(ip):8060/query/device-info") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.9
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }

            let values = RokuInfoParser.parse(data)

            // Roku ECP device-info contains one or more of these fields.
            guard !values.isEmpty else { return nil }

            let name =
                values["user-device-name"] ??
                values["friendly-device-name"] ??
                values["default-device-name"] ??
                values["model-name"] ??
                "Roku TV"

            let model =
                values["model-name"] ??
                values["model-number"] ??
                values["vendor-name"] ??
                "Roku"

            return RokuDevice(ip: ip, name: name, model: model)
        } catch {
            return nil
        }
    }

    static func discover(progress: @escaping @Sendable (Int, Int) async -> Void) async -> (devices: [RokuDevice], plan: ScanPlan) {
        let plan = makeScanPlan()
        guard !plan.candidates.isEmpty else {
            return ([], plan)
        }

        var found = Set<RokuDevice>()
        let total = plan.candidates.count
        var completed = 0

        // Limit concurrency to avoid iOS throttling hundreds of simultaneous local HTTP requests.
        for batchStart in stride(from: 0, to: total, by: 48) {
            let batchEnd = min(batchStart + 48, total)
            let batch = Array(plan.candidates[batchStart..<batchEnd])

            let results = await withTaskGroup(of: RokuDevice?.self, returning: [RokuDevice].self) { group in
                for candidate in batch {
                    group.addTask {
                        await probe(ip: candidate)
                    }
                }

                var devices: [RokuDevice] = []
                for await result in group {
                    if let result {
                        devices.append(result)
                    }
                }
                return devices
            }

            for device in results {
                found.insert(device)
            }

            completed = batchEnd
            await progress(completed, total)
        }

        let sorted = found.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                return $0.ip.localizedStandardCompare($1.ip) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return (sorted, plan)
    }
}
@MainActor
final class RokuRemoteModel: ObservableObject {
    @Published var ipAddress = UserDefaults.standard.string(forKey: "rokuIP") ?? ""
    @Published var selectedName = UserDefaults.standard.string(forKey: "rokuName") ?? ""
    @Published var status = "Choose a TV"
    @Published var connected = false
    @Published var discoveredDevices: [RokuDevice] = []
    @Published var isScanning = false
    @Published var scanDetails = "Not scanned yet"
    @Published var scanProgress = ""

    private var root: URL? {
        let raw = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""

        guard !raw.isEmpty else { return nil }
        return URL(string: "http://\(raw):8060")
    }

    func save() {
        let cleanIP = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(cleanIP, forKey: "rokuIP")
        UserDefaults.standard.set(selectedName, forKey: "rokuName")
    }

    func scanForTVs() {
        guard !isScanning else { return }

        isScanning = true
        discoveredDevices = []
        scanProgress = ""
        status = "Searching for Roku TVs…"

        let plan = RokuDiscovery.makeScanPlan()
        scanDetails = plan.summary

        Task {
            let result = await RokuDiscovery.discover { completed, total in
                await MainActor.run {
                    self.scanProgress = "Checked \(completed) of \(total) addresses"
                }
            }

            self.discoveredDevices = result.devices
            self.scanDetails = result.plan.summary
            self.isScanning = false

            if result.devices.isEmpty {
                self.status = "No Roku TVs found"
                self.scanProgress = "Nothing answered on Roku port 8060"
            } else if result.devices.count == 1 {
                self.status = "Found 1 TV"
                self.scanProgress = "Scan complete"
            } else {
                self.status = "Found \(result.devices.count) TVs"
                self.scanProgress = "Scan complete"
            }
        }
    }

    func select(_ device: RokuDevice) {
        ipAddress = device.ip
        selectedName = device.name
        save()
        test()
    }

    func test() {
        save()

        guard let root else {
            status = "Choose a TV"
            connected = false
            return
        }

        var request = URLRequest(url: root.appendingPathComponent("query/device-info"))
        request.httpMethod = "GET"
        request.timeoutInterval = 4

        status = "Connecting…"

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0

                if (200...299).contains(code) {
                    let values = RokuInfoParser.parse(data)
                    let detectedName =
                        values["user-device-name"] ??
                        values["friendly-device-name"] ??
                        values["default-device-name"] ??
                        values["model-name"]

                    if let detectedName, !detectedName.isEmpty {
                        self.selectedName = detectedName
                    }

                    self.connected = true
                    self.status = self.selectedName.isEmpty ? "Connected" : "Connected to \(self.selectedName)"
                    self.save()
                } else {
                    self.connected = false
                    self.status = "TV replied HTTP \(code)"
                }
            } catch {
                self.connected = false
                self.status = "Couldn't reach TV"
            }
        }
    }

    func key(_ name: String) {
        save()

        guard let root else {
            status = "Choose a TV"
            return
        }

        let url = root
            .appendingPathComponent("keypress")
            .appendingPathComponent(name)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.timeoutInterval = 3

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0

                if (200...299).contains(code) {
                    self.connected = true
                    self.status = self.selectedName.isEmpty ? "Connected" : "Connected to \(self.selectedName)"
                } else if code == 401 || code == 403 {
                    self.connected = false
                    self.status = "Enable Control by mobile apps on TV"
                } else {
                    self.status = "TV replied HTTP \(code)"
                }
            } catch {
                self.connected = false
                self.status = "Couldn't reach TV"
            }
        }
    }

    func sendText(_ text: String) {
        guard let root else { return }

        Task {
            for scalar in text.unicodeScalars {
                let literal = "Lit_" + String(scalar)

                guard let encoded = literal.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                    continue
                }

                let url = root
                    .appendingPathComponent("keypress")
                    .appendingPathComponent(encoded)

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = Data()
                request.timeoutInterval = 2

                _ = try? await URLSession.shared.data(for: request)
                try? await Task.sleep(nanoseconds: 35_000_000)
            }
        }
    }
}

struct RButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                Text(title)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

struct RoundButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .bold))
                .frame(width: 70, height: 70)
                .background(Circle().fill(.white.opacity(0.11)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

struct ContentView: View {
    @StateObject private var model = RokuRemoteModel()
    @State private var setup = false
    @State private var text = ""

    let blue = Color(red: 0.10, green: 0.45, blue: 1.0)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.01, green: 0.06, blue: 0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 17) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.selectedName.isEmpty ? "TCL Roku Remote" : model.selectedName)
                                .font(.title2.bold())

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(model.connected ? .green : .orange)
                                    .frame(width: 8, height: 8)

                                Text(model.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button {
                            setup = true
                        } label: {
                            Image(systemName: "tv.and.mediabox.fill")
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(.white.opacity(0.09)))
                        }
                    }

                    HStack(spacing: 10) {
                        RButton(icon: "house.fill", title: "Home") { model.key("Home") }
                        RButton(icon: "arrow.uturn.backward", title: "Back") { model.key("Back") }
                        RButton(icon: "asterisk", title: "Options") { model.key("Info") }
                    }

                    VStack(spacing: 10) {
                        RoundButton(icon: "chevron.up") { model.key("Up") }

                        HStack(spacing: 26) {
                            RoundButton(icon: "chevron.left") { model.key("Left") }

                            Button {
                                model.key("Select")
                            } label: {
                                Text("OK")
                                    .font(.headline.bold())
                                    .frame(width: 80, height: 80)
                                    .background(Circle().fill(blue))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)

                            RoundButton(icon: "chevron.right") { model.key("Right") }
                        }

                        RoundButton(icon: "chevron.down") { model.key("Down") }
                    }

                    HStack(spacing: 10) {
                        RButton(icon: "backward.fill", title: "Rewind") { model.key("Rev") }
                        RButton(icon: "playpause.fill", title: "Play/Pause") { model.key("Play") }
                        RButton(icon: "forward.fill", title: "Forward") { model.key("Fwd") }
                    }

                    HStack(spacing: 10) {
                        RButton(icon: "speaker.minus.fill", title: "Vol −") { model.key("VolumeDown") }
                        RButton(icon: "speaker.slash.fill", title: "Mute") { model.key("VolumeMute") }
                        RButton(icon: "speaker.plus.fill", title: "Vol +") { model.key("VolumeUp") }
                    }

                    HStack(spacing: 10) {
                        RButton(icon: "power", title: "Power On") { model.key("PowerOn") }
                        RButton(icon: "power.circle.fill", title: "Power Off") { model.key("PowerOff") }
                        RButton(icon: "arrow.counterclockwise", title: "Replay") { model.key("InstantReplay") }
                    }

                    HStack {
                        TextField("Type on TV…", text: $text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(.white.opacity(0.09))
                            )

                        Button("Send") {
                            guard !text.isEmpty else { return }
                            model.sendText(text)
                            text = ""
                        }
                        .fontWeight(.semibold)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(blue)
                        )
                    }

                    HStack(spacing: 10) {
                        Button("HDMI 1") { model.key("InputHDMI1") }
                        Button("HDMI 2") { model.key("InputHDMI2") }
                        Button("HDMI 3") { model.key("InputHDMI3") }
                    }
                    .buttonStyle(.bordered)
                    .tint(blue)

                    Text("iPhone and TV must be on the same Wi-Fi.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
        }
        .sheet(isPresented: $setup) {
            NavigationStack {
                Form {
                    Section {
                        Button {
                            model.scanForTVs()
                        } label: {
                            HStack {
                                Label(
                                    model.isScanning ? "Searching…" : "Scan for Roku TVs",
                                    systemImage: model.isScanning ? "wifi" : "dot.radiowaves.left.and.right"
                                )

                                Spacer()

                                if model.isScanning {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(model.isScanning)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.scanDetails)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            if !model.scanProgress.isEmpty {
                                Text(model.scanProgress)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !model.discoveredDevices.isEmpty {
                            ForEach(model.discoveredDevices) { device in
                                Button {
                                    model.select(device)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "tv.fill")
                                            .foregroundStyle(blue)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(device.name)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.primary)

                                            Text("\(device.model) • \(device.ip)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        if model.ipAddress == device.ip {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                            }
                        } else if !model.isScanning {
                            Text("Tap Scan to show every Roku TV found on this Wi-Fi.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Discovered TVs")
                    }

                    Section("Manual connection") {
                        TextField("192.168.1.50", text: $model.ipAddress)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button("Save & Test") {
                            model.selectedName = ""
                            model.test()
                        }
                    }

                    Section("If scan finds nothing") {
                        Text("On iPhone: Settings → Privacy & Security → Local Network → turn this app ON.")
                        Text("Make sure the iPhone and TV are on the same Wi-Fi, not a guest network.")
                        Text("On Roku: Settings → System → Advanced system settings → Control by mobile apps → Enabled.")
                    }

                    Section("TCL Roku TV setup") {
                        Text("Settings → System → Advanced system settings → Control by mobile apps → Enabled")
                        Text("Find IP: Settings → Network → About → IP address")
                    }
                }
                .navigationTitle("Choose TV")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            model.save()
                            setup = false
                        }
                    }
                }
            }
        }
        .onAppear {
            if model.ipAddress.isEmpty {
                setup = true
                model.scanForTVs()
            } else {
                model.test()
            }
        }
    }
}

@main
struct TCLRokuRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
