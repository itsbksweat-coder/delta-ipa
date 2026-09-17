import SwiftUI
import UIKit
import Foundation

@MainActor
final class RokuRemoteModel: ObservableObject {
    @Published var ipAddress = UserDefaults.standard.string(forKey: "rokuIP") ?? ""
    @Published var status = "Enter your TV IP"
    @Published var connected = false

    private var root: URL? {
        let raw = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        guard !raw.isEmpty else { return nil }
        return URL(string: "http://\(raw):8060")
    }

    func save() {
        UserDefaults.standard.set(ipAddress.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "rokuIP")
    }

    func test() {
        save()
        guard let root else {
            status = "Enter your TV IP"
            connected = false
            return
        }
        var req = URLRequest(url: root.appendingPathComponent("query/device-info"))
        req.httpMethod = "GET"
        req.timeoutInterval = 4
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                connected = (200...299).contains(code)
                status = connected ? "Connected" : "TV replied HTTP \(code)"
            } catch {
                connected = false
                status = "Couldn't reach TV"
            }
        }
    }

    func key(_ name: String) {
        save()
        guard let root else {
            status = "Enter your TV IP"
            return
        }
        let url = root.appendingPathComponent("keypress").appendingPathComponent(name)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data()
        req.timeoutInterval = 3
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(code) {
                    connected = true
                    status = "Connected"
                } else if code == 401 || code == 403 {
                    connected = false
                    status = "Enable Control by mobile apps on TV"
                } else {
                    status = "TV replied HTTP \(code)"
                }
            } catch {
                connected = false
                status = "Couldn't reach TV"
            }
        }
    }

    func sendText(_ text: String) {
        guard let root else { return }
        Task {
            for scalar in text.unicodeScalars {
                let lit = "Lit_" + String(scalar)
                guard let encoded = lit.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
                let url = root.appendingPathComponent("keypress").appendingPathComponent(encoded)
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.httpBody = Data()
                req.timeoutInterval = 2
                _ = try? await URLSession.shared.data(for: req)
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
                Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                Text(title).font(.caption2).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.09)))
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
            LinearGradient(colors: [.black, Color(red: 0.01, green: 0.06, blue: 0.15)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 17) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TCL Roku Remote").font(.title2.bold())
                            HStack(spacing: 6) {
                                Circle().fill(model.connected ? .green : .orange).frame(width: 8, height: 8)
                                Text(model.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { setup = true } label: {
                            Image(systemName: "gearshape.fill")
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
                            Button { model.key("Select") } label: {
                                Text("OK").font(.headline.bold())
                                    .frame(width: 80, height: 80)
                                    .background(Circle().fill(blue))
                                    .foregroundStyle(.white)
                            }.buttonStyle(.plain)
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
                            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.09)))
                        Button("Send") {
                            guard !text.isEmpty else { return }
                            model.sendText(text)
                            text = ""
                        }
                        .fontWeight(.semibold)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 14).fill(blue))
                    }

                    HStack(spacing: 10) {
                        Button("HDMI 1") { model.key("InputHDMI1") }
                        Button("HDMI 2") { model.key("InputHDMI2") }
                        Button("HDMI 3") { model.key("InputHDMI3") }
                    }
                    .buttonStyle(.bordered)
                    .tint(blue)

                    Text("iPhone and TV must be on the same Wi-Fi.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(18)
            }
        }
        .sheet(isPresented: $setup) {
            NavigationStack {
                Form {
                    Section("TV IP address") {
                        TextField("192.168.1.50", text: $model.ipAddress)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save & Test") { model.test() }
                    }
                    Section("TCL Roku TV setup") {
                        Text("Settings → System → Advanced system settings → Control by mobile apps → Enabled")
                        Text("Find IP: Settings → Network → About → IP address")
                    }
                }
                .navigationTitle("Setup")
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
            if model.ipAddress.isEmpty { setup = true } else { model.test() }
        }
    }
}

@main
struct TCLRokuRemoteApp: App {
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark) }
    }
}
