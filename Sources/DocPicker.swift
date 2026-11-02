import UIKit
import UniformTypeIdentifiers

final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    let onPick: ([URL]) -> Void
    init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
        DocPicker.delegate = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        DocPicker.delegate = nil
    }
}

/// Plain UIKit file picker. More reliable than SwiftUI's fileImporter, which can get stuck on Open.
enum DocPicker {
    static var delegate: PickerDelegate?

    static func present(_ onPick: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        let d = PickerDelegate(onPick: onPick)
        delegate = d
        picker.delegate = d
        guard var top = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        top.present(picker, animated: true)
    }
}
