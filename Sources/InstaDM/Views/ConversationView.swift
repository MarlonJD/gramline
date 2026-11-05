import DMCore
import SwiftUI

struct ConversationView: View {
    @Bindable var store: AppStore
    let conversation: Conversation
    @State private var viewedMessage: Message?
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ThemePalette? { conversation.theme?.palette(darkMode: colorScheme == .dark) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AvatarView(name: conversation.title, url: conversation.avatarURL, cache: store.appearanceCache, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title).font(.title3).fontWeight(.semibold)
                    Text("Instagram Direct").font(.caption).foregroundStyle(palette?.navigationText?.opacity(0.65) ?? .secondary)
                }
                Spacer()
                Link(destination: URL(string: "https://www.instagram.com/direct/inbox/")!) { Image(systemName: "arrow.up.right.square").font(.title3) }.help("Open Instagram")
            }.padding(.horizontal, 24).padding(.vertical, 16)
                .foregroundStyle(palette?.navigationText ?? .primary)
                .tint(palette?.navigationText ?? .accentColor)
                .background(palette?.navigation ?? .clear)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if store.hasOlderMessages {
                            Button(store.isLoadingHistory ? "Loading…" : "Load older messages") { Task { await store.loadOlder() } }
                                .buttonStyle(.link).font(.caption).disabled(store.isLoadingHistory || store.isSyncing || store.state != "connected")
                                .padding(.bottom, 14)
                        }
                        ForEach(MessageTimelineRow.make(from: store.messages)) { row in
                            VStack(spacing: 0) {
                                if row.showsTimestamp {
                                    Text(row.message.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(.regularMaterial, in: Capsule())
                                        .frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 12)
                                }
                                MessageBubble(message: row.message, showsSender: row.startsSenderGroup, showsSentStatus: row.showsSentStatus,
                                              palette: palette,
                                              sharedMedia: store.sharedMedia, openPost: { viewedMessage = row.message }, reuse: { store.reuse(row.message) })
                                    .padding(.top, row.showsTimestamp ? 0 : row.startsSenderGroup ? 12 : 3)
                            }.id(row.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(24)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.selectedID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: store.messages.last?.id) { _, _ in if !store.isLoadingHistory { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) } } }
            }
            .background { ChatBackground(palette: palette, cache: store.appearanceCache) }
            Divider()
            ComposerView(store: store, palette: palette)
        }
        .sheet(item: $viewedMessage) { message in
            if let post = message.sharedPost, let service = store.sharedMedia { SharedPostViewer(post: post, service: service) }
            else if message.directMedia != nil, let service = store.sharedMedia { DirectMediaViewer(message: message, service: service) }
        }
        .onChange(of: store.selectedID) { _, _ in viewedMessage = nil; store.sharedMedia?.stopPlayback() }
    }
}

struct MessageBubble: View {
    let message: Message
    let showsSender: Bool
    let showsSentStatus: Bool
    let palette: ThemePalette?
    let sharedMedia: SharedPostService?
    let openPost: () -> Void
    let reuse: () -> Void
    var body: some View {
        HStack(alignment: .bottom) {
            if message.isOwn { Spacer(minLength: 80) }
            VStack(alignment: message.isOwn ? .trailing : .leading, spacing: 5) {
                if showsSender && !message.isOwn && !message.senderName.isEmpty { Text(message.senderName).font(.caption2).foregroundStyle(palette?.incomingText?.opacity(0.7) ?? .secondary) }
                Group {
                    if let post = message.sharedPost, let sharedMedia { SharedPostCard(post: post, service: sharedMedia, open: openPost) }
                    else if let attachment = message.attachment { AttachmentView(attachment: attachment) }
                    else if let media = message.directMedia, let sharedMedia { DirectMediaCard(media: media, service: sharedMedia, open: openPost) }
                    else { Text(message.text).textSelection(.enabled) }
                }
                    .font(.body).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(message.isOwn ? palette?.outgoingText ?? .primary : palette?.incomingText ?? .primary)
                    .background(bubbleFill, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 490, alignment: message.isOwn ? .trailing : .leading)
                    .help(message.date.formatted(date: .abbreviated, time: .standard))
                if message.isOwn && (message.status != .sent || showsSentStatus) {
                    Label(statusText, systemImage: statusIcon)
                        .font(.caption2).foregroundStyle(message.status == .unknown || message.status == .failed ? .orange : palette?.incomingText?.opacity(0.7) ?? .secondary)
                }
                if message.status == .unknown {
                    Text("Delivery unconfirmed. Refresh before sending again.").font(.caption2).foregroundStyle(.secondary)
                }
                if message.status == .failed || message.status == .unknown {
                    Button(message.attachment == nil ? "Copy to composer" : "Attach again", action: reuse).buttonStyle(.link).font(.caption)
                }
            }
            if !message.isOwn { Spacer(minLength: 80) }
        }
    }
    private var bubbleFill: AnyShapeStyle {
        if message.isOwn, let colors = palette?.outgoing, !colors.isEmpty {
            return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(message.isOwn ? Color.accentColor.opacity(0.15) : palette?.incoming ?? Color.secondary.opacity(0.09))
    }
    private var statusIcon: String { switch message.status { case .sending: "clock"; case .sent: "checkmark"; case .failed: "exclamationmark.circle"; case .unknown: "questionmark.circle" } }
    private var statusText: String { switch message.status { case .sending: "Sending"; case .sent: "Sent"; case .failed: "Not sent"; case .unknown: "Unconfirmed" } }
}
