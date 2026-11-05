import AppKit
import DMCore
import SwiftUI

struct LoginView: View {
    @Bindable var store: AppStore
    @State private var username = ""
    @State private var password = ""
    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    BrandIcon().frame(width: 86, height: 86)
                    Text(store.loginStep == nil ? "A little closer.\nA lot less scrolling." : "One more step.")
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                    Text(store.loginStep == nil ? "Your Instagram messages, in a quiet corner of your Mac." : "Complete Instagram’s verification to open your inbox.")
                        .font(.body).foregroundStyle(.secondary)
                }

                if let step = store.loginStep {
                    Text(step.instructions).textSelection(.enabled).font(.callout)
                    if let fields = step.user_input?.fields {
                        ForEach(fields) { field in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(field.name).font(.callout).fontWeight(.medium)
                                if field.type == "select", let options = field.options {
                                    Picker(field.name, selection: binding(field)) {
                                        Text("Choose…").tag("")
                                        ForEach(options, id: \.self) { Text($0).tag($0) }
                                    }.labelsHidden()
                                } else if field.type == "password" || field.type == "token" {
                                    SecureField(field.name, text: binding(field)).textFieldStyle(.roundedBorder).focused($focused, equals: field.id)
                                } else {
                                    TextField(field.name, text: binding(field)).textFieldStyle(.roundedBorder).focused($focused, equals: field.id)
                                }
                                if !field.description.isEmpty { Text(field.description).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        ForEach(Array((step.user_input?.attachments ?? []).enumerated()), id: \.offset) { _, attachment in
                            if let base64 = attachment.content, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 160).accessibilityLabel("Instagram verification image")
                            }
                        }
                        Button("Continue") { submit() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.isBusy)
                    } else if step.type == "display_and_wait" {
                        if let data = step.display_and_wait?.data { Text(data).font(.title3.monospaced()).textSelection(.enabled) }
                        if store.isBusy {
                            HStack { ProgressView().controlSize(.small); Text("Waiting for approval on your other device…").font(.callout) }
                        } else {
                            Button("Check approval") { Task { await store.login(fields: [:]) } }
                        }
                    } else {
                        Text("Complete this security step in Instagram, then start sign-in again.").font(.callout)
                        Link("Open Instagram", destination: URL(string: "https://www.instagram.com/")!)
                    }
                    Button("Start over") { password = ""; values = [:]; Task { await store.cancelLogin() } }.buttonStyle(.link)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Username").font(.callout).fontWeight(.medium)
                            TextField("Instagram username", text: $username).textFieldStyle(.roundedBorder).focused($focused, equals: "username")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password").font(.callout).fontWeight(.medium)
                            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).focused($focused, equals: "password").onSubmit { submit() }
                        }
                        Button(action: submit) {
                            HStack { Spacer(); if store.isBusy { ProgressView().controlSize(.small) }; Text(store.isBusy ? "Signing in…" : "Sign in to Instagram"); Spacer() }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(store.isBusy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    }
                }
                Label("Your session stays in macOS Keychain. Your password is never saved.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("An independent Instagram client. Not affiliated with Meta.").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 360).padding(.horizontal, 48).padding(.vertical, 44).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: store.loginStep?.step_id) { _, _ in
            values = [:]
            for field in store.loginStep?.user_input?.fields ?? [] { values[field.id] = field.default_value ?? "" }
            focused = store.loginStep?.user_input?.fields.first?.id
        }
        .onDisappear { password = ""; values = [:] }
    }

    private func binding(_ field: LoginStep.Field) -> Binding<String> { Binding(get: { values[field.id] ?? field.default_value ?? "" }, set: { values[field.id] = $0 }) }
    private func submit() {
        guard !store.isBusy else { return }
        let fields = store.loginStep == nil ? ["username": username.trimmingCharacters(in: .whitespacesAndNewlines), "password": password] : Dictionary(uniqueKeysWithValues: (store.loginStep?.user_input?.fields ?? []).map { ($0.id, values[$0.id] ?? $0.default_value ?? "") })
        password = ""; values = [:]
        Task { await store.login(fields: fields) }
    }
}
