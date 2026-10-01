import SwiftUI
import UniformTypeIdentifiers

/// 系统文件选择器（选 .gguf / Skill.zip / 任意文件用）
struct DocPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let c = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        c.allowsMultipleSelection = false
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(_ f: @escaping (URL) -> Void) { onPick = f }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
        func documentPickerDidClose(_ controller: UIDocumentPickerViewController) {}
    }
}
