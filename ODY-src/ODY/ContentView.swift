import SwiftUI
import UIKit

private let eternalAuthBase = URL(string: "https://eternal-auth.xyzcheatz.workers.dev")!

private struct DeviceStartResponse: Decodable {
    let ok: Bool
    let device_code: String
    let user_code: String
    let verification_uri: String
    let verification_uri_complete: String
    let expires_in: Int
    let interval: Int
}

private struct DeviceStatusResponse: Decodable {
    let ok: Bool
    let status: String
    let app_token: String?
    let user: DeviceUser?
}

private struct DeviceUser: Decodable {
    let id: String
    let username: String
}

private struct OdyStatusResponse: Decodable {
    let ok: Bool
    let status_text: String?
    let found: Bool?
    let error: String?
}

struct ContentView: View {
    @State private var screen: Screen = .ody
    @State private var deviceCode = ""
    @State private var userCode = ""
    @State private var verificationURL = ""
    @State private var pairMessage = ""
    @State private var isStartingPair = false

    @AppStorage("ODYAppSessionToken") private var appToken = ""
    @AppStorage("ODYDiscordUsername") private var discordUsername = ""

    enum Screen: Hashable {
        case ody
        case discordPair
    }

    var body: some View {
        ZStack {
            switch screen {
            case .ody:
                odyScreen
            case .discordPair:
                pairingScreen
            }
        }
        .background(Color.black)
        .ignoresSafeArea(edges: .bottom)
        .task(id: screen) {
            guard screen == .discordPair else { return }
            if appToken.isEmpty {
                if deviceCode.isEmpty {
                    await beginPairing()
                }
                await pollPairing()
            }
        }
        .task(id: appToken) {
            guard !appToken.isEmpty else { return }
            await runStatusSync()
        }
    }

    private var odyScreen: some View {
        ZStack(alignment: .bottom) {
            LocalWebView()

            HStack(spacing: 12) {
                Button {
                    screen = .discordPair
                } label: {
                    Label(appToken.isEmpty ? "Connect Discord" : "Discord Connected", systemImage: appToken.isEmpty ? "link" : "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    NotificationCenter.default.post(name: .reloadODYPage, object: nil)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var pairingScreen: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Button {
                        screen = .ody
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    Spacer()
                    Text("Discord Pairing")
                        .font(.headline)
                    Spacer()
                    Color.clear.frame(width: 55, height: 1)
                }

                if !appToken.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(.green)

                    Text("Connected")
                        .font(.title2.bold())

                    if !discordUsername.isEmpty {
                        Text("Authorized as \(discordUsername)")
                            .foregroundStyle(.secondary)
                    }

                    Text("ODY now uses its own Eternal Auth session. Your Discord password, cookie, and normal user token are not copied into the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Pair Again") {
                        appToken = ""
                        discordUsername = ""
                        deviceCode = ""
                        userCode = ""
                        verificationURL = ""
                        pairMessage = ""
                        Task { await beginPairing() }
                    }
                    .buttonStyle(.bordered)
                } else if isStartingPair {
                    ProgressView("Creating one-time login code…")
                        .padding(.top, 32)
                } else if !userCode.isEmpty {
                    Text("On your other device")
                        .font(.title3.bold())

                    Text("Open this address:")
                        .foregroundStyle(.secondary)

                    Text("eternal-auth.xyzcheatz.workers.dev/discord/connect")
                        .font(.system(.footnote, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)

                    Text("Then enter this one-time code")
                        .foregroundStyle(.secondary)

                    Text(userCode)
                        .font(.system(size: 34, weight: .black, design: .monospaced))
                        .tracking(3)
                        .padding(.vertical, 8)

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = userCode
                        } label: {
                            Label("Copy Code", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            UIPasteboard.general.string = verificationURL
                        } label: {
                            Label("Copy Link", systemImage: "link")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let url = URL(string: verificationURL) {
                        Link(destination: url) {
                            Label("Open on This Device Instead", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    ProgressView()
                        .padding(.top, 4)
                    Text(pairMessage.isEmpty ? "Waiting for approval…" : pairMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("The code expires after about 10 minutes.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(pairMessage.isEmpty ? "Unable to create a pairing code." : pairMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Try Again") {
                        Task { await beginPairing() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
        }
        .background(Color.black)
    }

    @MainActor
    private func beginPairing() async {
        guard !isStartingPair else { return }
        isStartingPair = true
        pairMessage = ""
        deviceCode = ""
        userCode = ""
        verificationURL = ""

        defer { isStartingPair = false }

        do {
            var request = URLRequest(url: eternalAuthBase.appending(path: "discord/device/start"))
            request.httpMethod = "POST"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let result = try JSONDecoder().decode(DeviceStartResponse.self, from: data)
            guard result.ok else { throw URLError(.cannotParseResponse) }

            deviceCode = result.device_code
            userCode = result.user_code
            verificationURL = result.verification_uri_complete
            pairMessage = "Waiting for approval…"
        } catch {
            pairMessage = "Could not start pairing: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func pollPairing() async {
        while screen == .discordPair && appToken.isEmpty && !deviceCode.isEmpty && !Task.isCancelled {
            do {
                var components = URLComponents(url: eternalAuthBase.appending(path: "discord/device/status"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "device_code", value: deviceCode)]

                let (data, response) = try await URLSession.shared.data(from: components.url!)
                if let http = response as? HTTPURLResponse, http.statusCode == 410 {
                    pairMessage = "That code expired. Creating a new one…"
                    deviceCode = ""
                    userCode = ""
                    verificationURL = ""
                    await beginPairing()
                    continue
                }

                if let result = try? JSONDecoder().decode(DeviceStatusResponse.self, from: data),
                   result.ok,
                   result.status == "authorized",
                   let token = result.app_token,
                   !token.isEmpty {
                    appToken = token
                    discordUsername = result.user?.username ?? ""
                    pairMessage = "Connected."
                    screen = .ody
                    return
                }
            } catch {
                pairMessage = "Still waiting…"
            }

            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    @MainActor
    private func runStatusSync() async {
        while !appToken.isEmpty && !Task.isCancelled {
            await fetchStatusOnce()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    @MainActor
    private func fetchStatusOnce() async {
        do {
            var request = URLRequest(url: eternalAuthBase.appending(path: "api/ody/status"))
            request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                appToken = ""
                discordUsername = ""
                return
            }

            let result = try JSONDecoder().decode(OdyStatusResponse.self, from: data)
            guard result.ok, let text = result.status_text, !text.isEmpty else { return }

            UserDefaults.standard.set(text, forKey: "ODYLatestStatusText")
            NotificationCenter.default.post(
                name: .odyStatusTextUpdated,
                object: nil,
                userInfo: ["text": text]
            )
        } catch {
            // Keep the previous status and retry on the next sync interval.
        }
    }
}

extension Notification.Name {
    static let reloadODYPage = Notification.Name("reloadODYPage")
    static let reloadDiscordPage = Notification.Name("reloadDiscordPage")
    static let odyStatusTextUpdated = Notification.Name("odyStatusTextUpdated")
}
