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
    static func wifiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first

        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            guard let address = current.pointee.ifa_addr else { continue }
            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let interfaceName = String(cString: current.pointee.ifa_name)
            guard interfaceName == "en0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                return String(cString: hostname)
            }
        }

        return nil
    }

    static func probe(ip: String) async -> RokuDevice? {
        guard let url = URL(string: "http://\(ip):8060/query/device-info") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }

            let values = RokuInfoParser.parse(data)

            let name =
                values["user-device-name"] ??
                values["friendly-device-name"] ??
                values["default-device-name"] ??
                values["model-name"] ??
                "Roku TV"

            let model = values["model-name"] ?? values["model-number"] ?? "Roku"

            return RokuDevice(ip: ip, name: name, model: model)
        } catch {
            return nil
        }
    }

    static func discover() async -> [RokuDevice] {
        guard let localIP = wifiIPv4() else { return [] }

        let parts = localIP.split(separator: ".")
        guard parts.count == 4 else { return [] }

        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
        var found: [RokuDevice] = []

        // Scan in small batches so iOS does not open hundreds of sockets at once.
        for batchStart in stride(from: 1, through: 254, by: 32) {
            let batchEnd = min(batchStart + 31, 254)

            let batchResults = await withTaskGroup(of: RokuDevice?.self, returning: [RokuDevice].self) { group in
                for host in batchStart...batchEnd {
                    let candidate = "\(prefix).\(host)"
                    if candidate == localIP { continue }

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

            found.append(contentsOf: batchResults)
        }

        return Array(Set(found)).sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                return $0.ip.localizedStandardCompare($1.ip) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
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
        status = "Searching for Roku TVs…"

        Task {
            let devices = await RokuDiscovery.discover()
            self.discoveredDevices = devices
            self.isScanning = false

            if devices.isEmpty {
                self.status = "No Roku TVs found"
            } else if devices.count == 1 {
                self.status = "Found 1 TV"
            } else {
                self.status = "Found \(devices.count) TVs"
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
