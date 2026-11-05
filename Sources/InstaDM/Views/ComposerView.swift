import AppKit
import DMCore
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var store: AppStore
    var palette: ThemePalette?
    @State private var choosingFiles = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(store.attachments) { attachment in
                            HStack(alignment: .top, spacing: 6) {
                                AttachmentView(attachment: attachment, compact: true)
                                Button { store.removeAttachment(attachment) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).help("Remove attachment")
                            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                if !store.draft.isEmpty { Text("Text will be sent as a separate message after the attachments.").font(.caption2).foregroundStyle(.secondary) }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button { choosingFiles = true } label: { Image(systemName: "paperclip").font(.title3).frame(height: 34) }
                    .buttonStyle(.plain).help("Attach files or paste with ⌘V").disabled(store.isPreparingAttachments)
                MessageTextEditor(text: $store.draft, canSend: store.canSend, onSend: { Task { await store.send() } }, onPasteAttachments: { store.pasteAttachments() }, textColor: palette?.composerText.map(NSColor.init) ?? .labelColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
                    .overlay(alignment: .topLeading) {
                        if store.draft.isEmpty { Text("Write a message…").foregroundStyle(palette?.composerText?.opacity(0.5) ?? .secondary).padding(12).allowsHitTesting(false) }
                    }
                    .background(palette?.composerInput ?? Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: store.draft) { _, _ in store.saveDraft() }
                Button { Task { await store.send() } } label: { Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).frame(width: 24, height: 28) }
                    .buttonStyle(.borderedProminent).clipShape(RoundedRectangle(cornerRadius: 12))
                    .disabled(!store.canSend).help("Send message (Return)")
            }
            HStack {
                if store.isPreparingAttachments || store.isSendingAttachments { ProgressView().controlSize(.mini) }
                Text(store.isPreparingAttachments ? "Preparing attachments…" : store.isSendingAttachments ? "Sending attachments…" : store.state == "connected" ? "Return to send · Shift+Return for a new line · ⌘V to paste" : "You’re offline. Your draft is saved on this Mac.")
                Spacer()
                if store.draft.count > 900 { Text("\(store.draft.count)/1000").foregroundStyle(store.draft.count > 1000 ? .red : .secondary) }
            }.font(.caption2).foregroundStyle(palette?.composerText?.opacity(0.65) ?? .secondary)
        }.padding(18)
            .foregroundStyle(palette?.composerText ?? .primary)
            .background(palette?.composer ?? .clear)
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result { case .success(let urls): store.attachFiles(urls); case .failure(let error): store.errorMessage = error.localizedDescription }
            }
    }
}
