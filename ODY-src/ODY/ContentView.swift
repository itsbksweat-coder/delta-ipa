import SwiftUI

struct ContentView: View {
    @State private var screen: Screen = .ody

    enum Screen {
        case ody
        case discord
    }

    var body: some View {
        ZStack {
            switch screen {
            case .ody:
                odyScreen
            case .discord:
                discordScreen
            }
        }
        .background(Color.black)
        .ignoresSafeArea(edges: .bottom)
    }

    private var odyScreen: some View {
        ZStack(alignment: .bottom) {
            LocalWebView()

            HStack(spacing: 12) {
                Button {
                    screen = .discord
                } label: {
                    Label("Discord", systemImage: "person.crop.circle")
                        .font(.system(size: 15, weight: .semibold))
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

    private var discordScreen: some View {
        ZStack(alignment: .top) {
            EmbeddedDiscordWebView()
                .padding(.top, 50)

            HStack(spacing: 12) {
                Button {
                    screen = .ody
                } label: {
                    Label("Back to ODY", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                }

                Spacer()

                Text("Discord")
                    .font(.system(size: 16, weight: .bold))

                Spacer()

                Button {
                    NotificationCenter.default.post(name: .reloadDiscordPage, object: nil)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(.ultraThinMaterial)
        }
    }
}

extension Notification.Name {
    static let reloadODYPage = Notification.Name("reloadODYPage")
    static let reloadDiscordPage = Notification.Name("reloadDiscordPage")
    static let odyStatusTextUpdated = Notification.Name("odyStatusTextUpdated")
}
