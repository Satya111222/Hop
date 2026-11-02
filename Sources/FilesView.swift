import SwiftUI

struct FilesView: View {
    @EnvironmentObject var core: Core

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Header(title: "files", subtitle: "\(core.files.count) on this iPad") {
                    Button { DocPicker.present { urls in core.importFiles(urls) } } label: {
                        RoundIcon(name: "plus", filled: true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 4)

                if core.files.isEmpty {
                    Card {
                        Text("Nothing here yet").font(mono(14, .bold)).foregroundColor(T.fg)
                        Text("Files sent from your PC land here. Tap + to add files from this iPad, then download them from the PC page with the red arrow.")
                            .font(mono(12)).foregroundColor(T.dim)
                    }
                }

                ForEach(core.files) { f in
                    FileRow(f: f)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 110)
            .animation(.easeInOut(duration: 0.2), value: core.files.map(\.id))
        }
        .onAppear { core.refreshFiles() }
    }
}

struct FileRow: View {
    @EnvironmentObject var core: Core
    let f: FileItem

    private var ext: String { (f.name as NSString).pathExtension }

    var body: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(f.name)
                        .font(mono(14, .bold))
                        .foregroundColor(T.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        if !ext.isEmpty { Tag(text: ext.uppercased(), color: tagColor(forExt: ext)) }
                        Text("\(fmtBytes(f.size))   \(f.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(mono(11)).foregroundColor(T.dim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                ShareLink(item: f.url) { RoundIcon(name: "square.and.arrow.up", size: 36) }
                Button { withAnimation { core.delete(f) } } label: { RoundIcon(name: "trash", size: 36) }
                    .buttonStyle(.plain)
            }
        }
    }
}
