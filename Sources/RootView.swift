import SwiftUI

enum Screen: CaseIterable {
    case home, transfers, files
    var title: String {
        switch self {
        case .home: return "Connect"
        case .transfers: return "Transfers"
        case .files: return "Files"
        }
    }
    var icon: String {
        switch self {
        case .home: return "dot.radiowaves.left.and.right"
        case .transfers: return "arrow.up.arrow.down"
        case .files: return "folder"
        }
    }
}

struct RootView: View {
    @State private var tab: Screen = .home
    @Namespace private var ns

    var body: some View {
        ZStack(alignment: .bottom) {
            GridBackground()
            Group {
                switch tab {
                case .home: HomeView()
                case .transfers: TransfersView()
                case .files: FilesView()
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
            FloatingNav(tab: $tab, ns: ns).padding(.bottom, 10)
        }
        .animation(.easeInOut(duration: 0.2), value: tab)
    }
}

struct FloatingNav: View {
    @EnvironmentObject var core: Core
    @Binding var tab: Screen
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Screen.allCases, id: \.self) { t in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tab = t }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.system(size: 16, weight: .semibold))
                        if tab == t { Text(t.title).font(mono(12, .bold)) }
                    }
                    .foregroundColor(tab == t ? .white : T.dim)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background {
                        if tab == t { Capsule().fill(T.red).matchedGeometryEffect(id: "pill", in: ns) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if t == .transfers, tab != t, core.transfers.contains(where: { $0.state == .live }) {
                            Circle().fill(T.red).frame(width: 8, height: 8).offset(x: -6, y: 6)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(T.line, lineWidth: 1))
    }
}
