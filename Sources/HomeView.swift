import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var core: Core
    @AppStorage("theme") private var theme = "dark"
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Header(title: "hop", subtitle: "iPad and PC file transfer") {
                    Button { theme = theme == "dark" ? "light" : "dark" } label: {
                        RoundIcon(name: theme == "dark" ? "sun.max" : "moon")
                    }
                }

                Card {
                    HStack {
                        Tag(text: core.running ? "ONLINE" : "OFFLINE", color: core.running ? .green : .gray)
                        Spacer()
                        if core.running {
                            Button {
                                UIPasteboard.general.string = core.address
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                            } label: { RoundIcon(name: copied ? "checkmark" : "doc.on.doc", size: 34) }
                        }
                    }
                    Text(core.address)
                        .font(mono(20, .bold))
                        .foregroundColor(core.running ? T.fg : T.dim)
                        .textSelection(.enabled)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    if core.running, core.address.hasPrefix("http"), let img = qrImage(core.address) {
                        Image(uiImage: img)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 170, height: 170)
                            .padding(10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: .infinity)
                    }
                    if let e = core.error {
                        Text(e).font(mono(11)).foregroundColor(T.red)
                    }
                }

                Button {
                    core.running ? core.stop() : core.start()
                } label: {
                    Text(core.running ? "Stop server" : "Start server")
                        .font(mono(15, .bold))
                        .foregroundColor(core.running ? T.fg : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(core.running ? T.bg : T.red))
                        .overlay(Capsule().stroke(core.running ? T.line : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Card {
                    Toggle(isOn: $core.pinEnabled) {
                        Text("Require PIN").font(mono(14, .bold)).foregroundColor(T.fg)
                    }
                    .tint(T.red)
                    if core.pinEnabled {
                        HStack {
                            Text(core.pin).font(mono(28, .bold)).foregroundColor(T.fg)
                            Spacer()
                            Button { core.newPin() } label: { RoundIcon(name: "arrow.triangle.2.circlepath", size: 34) }
                        }
                        Text("The PC page asks for this PIN once per browser session.")
                            .font(mono(11)).foregroundColor(T.dim)
                    }
                }

                Text("On your PC, open the address in any browser on the same Wi-Fi. Keep Hop open while files move, because iOS pauses apps in the background.")
                    .font(mono(11))
                    .foregroundColor(T.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 110)
        }
    }
}
