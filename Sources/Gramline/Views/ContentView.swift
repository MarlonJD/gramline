import DMCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ThemePalette? { store.selectedConversation?.theme?.palette(darkMode: colorScheme == .dark) }
    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, palette: palette)
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Dismiss error")
                    }
                    .padding(12).background(.orange.opacity(0.09))
                }
                if store.account == nil {
                    LoginView(store: store)
                } else if let conversation = store.selectedConversation {
                    ConversationView(store: store, conversation: conversation)
                } else {
                    ContentUnavailableView {
                        Label("Your conversations, here.", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(store.conversations.isEmpty ? (store.isSyncing ? "Loading your Instagram inbox…" : "Refresh to load your Instagram conversations.") : "Choose a conversation to pick up where you left off.")
                    } actions: {
                        if store.state == "connected" {
                            Button("Refresh Inbox") { Task { await store.refresh() } }.disabled(store.isSyncing)
                        } else {
                            Button("Reconnect") { Task { await store.reconnect() } }.disabled(store.isBusy)
                        }
                    }
                }
            }
        }
        .navigationTitle(store.selectedConversation?.title ?? "Gramline")
        .toolbarBackground(palette?.chromeBackground ?? Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(palette == nil ? .automatic : .visible, for: .windowToolbar)
        .toolbarColorScheme(palette?.chromeColorScheme, for: .windowToolbar)
        .tint(palette?.chromeText ?? .accentColor)
        .toolbar {
            ToolbarItem(placement: .status) { ConnectionBadge(store: store, textColor: palette?.chromeText) }
            ToolbarItem {
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh messages (⌘R)").disabled(store.state != "connected" || store.isSyncing)
            }
        }
        .sheet(isPresented: Binding(get: { store.showLogin && store.account != nil }, set: { store.showLogin = $0 })) {
            LoginView(store: store).frame(width: 530, height: 600)
        }
    }
}

struct ConnectionBadge: View {
    let store: AppStore
    var textColor: Color? = nil
    private var color: Color { store.state == "connected" ? .green : store.state == "login_required" || store.state == "offline" ? .orange : .secondary }
    var body: some View {
        HStack(spacing: 6) {
            if store.isSyncing || store.state == "connecting" || store.state == "starting" { ProgressView().controlSize(.mini) }
            else { Circle().fill(color).frame(width: 6, height: 6) }
            Text(store.isSyncing ? "Syncing messages…" : store.statusMessage).font(.caption).foregroundStyle(textColor?.opacity(0.7) ?? .secondary).lineLimit(1)
        }.help(store.statusMessage)
    }
}
