import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

enum T {
    static let red = Color(red: 0.90, green: 0.19, blue: 0.17)
    static let bg = Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    static let fg = Color(UIColor { $0.userInterfaceStyle == .dark ? .white : .black })
    static let dim = fg.opacity(0.5)
    static let line = fg.opacity(0.14)
    static let card = fg.opacity(0.05)
}

func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

// MARK: formatting

func fmtBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func fmtDuration(_ s: Double) -> String {
    if !s.isFinite || s < 0 { return "--" }
    let t = Int(s.rounded())
    if t < 60 { return "\(t)s" }
    if t < 3600 { return "\(t / 60)m \(t % 60)s" }
    return "\(t / 3600)h \((t % 3600) / 60)m"
}

func tagColor(forExt ext: String) -> Color {
    switch ext.lowercased() {
    case "jpg", "jpeg", "png", "heic", "gif", "webp": return .purple
    case "mp4", "mov", "mkv", "avi", "webm": return .pink
    case "mp3", "m4a", "wav", "flac": return .teal
    case "pdf", "doc", "docx", "txt", "pptx", "xlsx": return .orange
    case "zip", "rar", "7z", "ipa", "dmg": return .yellow
    default: return .gray
    }
}

func qrImage(_ s: String) -> UIImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(s.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
          let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
}

// MARK: shared components

struct GridBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 28
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step
            }
            ctx.stroke(path, with: .color(T.fg.opacity(0.06)), lineWidth: 0.5)
        }
        .background(T.bg)
        .ignoresSafeArea()
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(mono(10, .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .clipShape(Capsule())
    }
}

struct RoundIcon: View {
    let name: String
    var filled = false
    var size: CGFloat = 42
    var body: some View {
        Image(systemName: name)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundColor(filled ? .white : T.fg)
            .frame(width: size, height: size)
            .background(Circle().fill(filled ? T.red : T.bg))
            .overlay(Circle().stroke(filled ? Color.clear : T.line, lineWidth: 1))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(T.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(T.line, lineWidth: 1))
    }
}

struct Header<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(mono(34, .bold)).foregroundColor(T.fg)
                Text(subtitle).font(mono(12)).foregroundColor(T.dim)
            }
            Spacer()
            HStack(spacing: 8, content: trailing)
        }
    }
}

struct ProgressLine: View {
    let value: Double
    var color: Color = T.red
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(T.fg.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(6, geo.size.width * CGFloat(min(max(value, 0), 1))))
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: 6)
    }
}
