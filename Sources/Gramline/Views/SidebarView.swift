import DMCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: AppStore
    let palette: ThemePalette?
    @FocusState private var searchFocused: Bool
    private var foreground: Color { palette?.chromeText ?? .primary }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(foreground.opacity(0.55))
                TextField("Search conversations", text: $store.search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search conversations")
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .padding(9)
            .background(foreground.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(foreground.opacity(0.08)))
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        Text("Messages").font(.caption).fontWeight(.semibold)
                            .foregroundStyle(foreground.opacity(0.55)).padding(.horizontal, 10).padding(.vertical, 8)
                        ForEach(store.filteredConversations) { conversation in
                            Button { Task { await store.select(conversation.id) } } label: {
                                row(conversation)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(store.selectedID == conversation.id ? .isSelected : [])
                            .id(conversation.id)
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
                .onMoveCommand { direction in
                    guard !searchFocused, direction == .up || direction == .down else { return }
                    let rows = store.filteredConversations
                    guard !rows.isEmpty else { return }
                    let current = rows.firstIndex { $0.id == store.selectedID } ?? (direction == .down ? -1 : rows.count)
                    let next = rows[min(max(current + (direction == .down ? 1 : -1), 0), rows.count - 1)].id
                    Task { await store.select(next) }
                    proxy.scrollTo(next)
                }
            }
            Rectangle().fill(foreground.opacity(0.12)).frame(height: 1)
            HStack(spacing: 10) {
                AvatarView(name: store.account?.username ?? "?", url: store.account?.avatarURL, cache: store.appearanceCache, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.account.map { "@\($0.username)" } ?? "Welcome to Gramline").font(.callout).fontWeight(.medium).lineLimit(1)
                    Text(store.account == nil ? "Your inbox, on your Mac" : "Personal account").font(.caption).foregroundStyle(foreground.opacity(0.65))
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings")
            }.padding(16)
        }
        .foregroundStyle(foreground)
        .background(palette?.chromeBackground ?? Color(nsColor: .windowBackgroundColor))
        .background {
            Button("Find Conversation") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        let selected = store.selectedID == conversation.id
        return HStack(spacing: 10) {
            AvatarView(name: conversation.title, url: conversation.avatarURL, cache: store.appearanceCache)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(conversation.title).fontWeight(conversation.unread ? .semibold : .regular).lineLimit(1)
                    if conversation.unread { Circle().fill(palette?.chromeSelection ?? .accentColor).frame(width: 6, height: 6).accessibilityLabel("Unread") }
                }
                Text(conversation.preview.isEmpty ? "Start a conversation" : conversation.preview)
                    .font(.caption).foregroundStyle(foreground.opacity(0.65)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(selected ? (palette?.chromeSelection ?? .accentColor).opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? foreground.opacity(0.12) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
