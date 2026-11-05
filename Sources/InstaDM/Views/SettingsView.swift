import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var confirmSignOut = false
    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Instagram", value: store.account.map { "@\($0.username)" } ?? "Not signed in")
                LabeledContent("Connection", value: store.statusMessage)
                Button("Reconnect") { Task { await store.reconnect() } }.disabled(store.isBusy || store.isSyncing)
                if store.account != nil { Button("Sign Out…", role: .destructive) { confirmSignOut = true } }
            }
            Section("Notifications") {
                Text("Unread messages appear on the Dock icon while InstaDM is running. A + means there may be more. Reading a conversation clears its count.").font(.callout)
                Toggle("Show banners and play a sound", isOn: Binding(get: { store.messageAlertsEnabled }, set: { enabled in Task { await store.setMessageAlerts(enabled) } }))
                Text("Banners are optional. Message contents stay hidden.").font(.caption).foregroundStyle(.secondary)
            }
            Section("On this Mac") {
                Text("Sessions are stored in Keychain. Conversation history and drafts are stored locally, separately for each account.").font(.callout)
                Text("InstaDM 0.1.0 · Messaging preview").font(.caption).foregroundStyle(.secondary)
                if !store.loginDiagnostic.isEmpty { Text(store.loginDiagnostic).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }.formStyle(.grouped).frame(width: 480, height: 440)
        .confirmationDialog("Sign out of Instagram?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await store.signOut() } }
        } message: { Text("Your saved session will be removed from Keychain. Local message history stays on this Mac for your next sign-in.") }
    }
}
