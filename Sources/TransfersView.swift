import SwiftUI

struct TransfersView: View {
    @EnvironmentObject var core: Core

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Header(title: "transfers", subtitle: "\(core.transfers.filter { $0.state == .live }.count) active") {
                    if core.transfers.contains(where: { $0.state != .live }) {
                        Button { withAnimation { core.clearFinished() } } label: { RoundIcon(name: "trash") }
                    }
                }
                .padding(.bottom, 4)

                if core.transfers.isEmpty {
                    Card {
                        Text("No transfers yet").font(mono(14, .bold)).foregroundColor(T.fg)
                        Text(core.running
                             ? "Open \(core.address) on your PC and drop files on the page."
                             : "Start the server on the Connect tab, then open its address on your PC.")
                            .font(mono(12)).foregroundColor(T.dim)
                    }
                }

                ForEach(core.transfers) { t in
                    TransferRow(t: t).transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 110)
            .animation(.easeInOut(duration: 0.2), value: core.transfers.count)
        }
    }
}

struct TransferRow: View {
    let t: Transfer

    private var fraction: Double { t.total > 0 ? Double(t.done) / Double(t.total) : (t.state == .done ? 1 : 0) }

    private var stateTag: (String, Color) {
        switch t.state {
        case .live: return ("LIVE", .yellow)
        case .done: return ("DONE", .green)
        case .failed: return ("FAILED", T.red)
        }
    }

    private var info: String {
        var s = "\(fmtBytes(t.done)) / \(fmtBytes(t.total))"
        if t.state == .live, t.speed > 1 {
            s += "   \(fmtBytes(Int64(t.speed)))/s"
            s += "   \(fmtDuration(Double(t.total - t.done) / t.speed)) left"
        }
        return s
    }

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Tag(text: t.dir == .up ? "TO IPAD" : "TO PC", color: t.dir == .up ? .blue : .orange)
                Tag(text: stateTag.0, color: stateTag.1)
                Spacer()
                Text("\(Int(fraction * 100))%").font(mono(13, .bold)).foregroundColor(T.fg)
            }
            Text(t.name)
                .font(mono(14, .bold))
                .foregroundColor(T.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressLine(value: fraction, color: t.state == .failed ? T.red : (t.state == .done ? .green : T.red))
            Text(info).font(mono(11)).foregroundColor(T.dim)
        }
    }
}
