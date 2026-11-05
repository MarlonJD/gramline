import AppKit
import SwiftUI

/// SwiftUI owns the draft; AppKit owns native paste, selection, undo and IME behavior.
struct MessageTextEditor: NSViewRepresentable {
    @Binding var text: String
    let canSend: Bool
    let onSend: () -> Void
    let onPasteAttachments: () -> Bool
    var textColor: NSColor = .labelColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        let editor = ComposerTextView()
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor; editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 12, height: 0)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Write a message…")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = view.documentView as? ComposerTextView else { return }
        editor.textColor = textColor; editor.insertionPointColor = textColor
        editor.canSend = canSend; editor.onSend = onSend; editor.onPasteAttachments = onPasteAttachments
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let measuringText = text.isEmpty || text.hasSuffix("\n") ? text + " " : text
        let bounds = (measuringText as NSString).boundingRect(with: NSSize(width: max(1, width - 24), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return CGSize(width: width, height: ceil(min(max(lineHeight, bounds.height), lineHeight * 3)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageTextEditor
        init(_ parent: MessageTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            editor.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }
}

final class ComposerTextView: NSTextView {
    var canSend = false
    var onSend: (() -> Void)?
    var onPasteAttachments: (() -> Bool)?

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, .init("public.jpeg"), .init("com.compuserve.gif"), .init("org.webmproject.webp")] + super.readablePasteboardTypes
    }
    override func paste(_ sender: Any?) {
        if onPasteAttachments?() == true { return }
        super.paste(sender)
    }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), AttachmentPasteboard.canRead() { return true }
        return super.validateUserInterfaceItem(item)
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil) }
            else if canSend && !event.isARepeat { onSend?() }
        } else { super.keyDown(with: event) }
    }
}
