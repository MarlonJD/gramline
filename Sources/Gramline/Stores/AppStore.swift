import AppKit
import DMCore
import Foundation
import Network
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class AppStore {
    var account: Account?
    var conversations: [Conversation] = []
    var messages: [Message] = []
    var selectedID: String?
    var search = ""
    var draft = ""
    var attachments: [MessageAttachment] = []
    var isPreparingAttachments = false
    var isSendingAttachments = false
    var state = "starting"
    var statusMessage = "Starting…"
    var errorMessage: String?
    var loginStep: LoginStep?
    var isBusy = false
    var isSyncing = false
    var isLoadingHistory = false
    var hasOlderMessages = false
    var messageAlertsEnabled = UserDefaults.standard.bool(forKey: "messageAlertsEnabled")
    var showLogin = false
    var loginDiagnostic = ""
    var sharedMedia: SharedPostService?
    var ravenMedia: RavenMediaService?
    var appearanceCache: SharedMediaCache?

    @ObservationIgnored private let core = CoreProcess()
    @ObservationIgnored private let keychain = SessionKeychain()
    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private var database: MessageDatabase?
    @ObservationIgnored private var attachmentStore: AttachmentStore?
    @ObservationIgnored private var cursors: [String: String] = [:]
    @ObservationIgnored private var hasMore: [String: Bool] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var restartAttempts = 0
    @ObservationIgnored private var loginGeneration = 0
    @ObservationIgnored private let network = NWPathMonitor()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var selectedConversation: Conversation? { conversations.first { $0.id == selectedID } }
    var filteredConversations: [Conversation] { search.isEmpty ? conversations : conversations.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search) } }
    var canSend: Bool { state == "connected" && !isBusy && !isPreparingAttachments && !isSendingAttachments && selectedID != nil && (!attachments.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && draft.count <= 1000 }

    func start() async {
        guard !started else { return }; started = true
        core.onEvent = { [weak self] frame in try self?.receive(frame) }
        core.onExit = { [weak self] in self?.helperExited() }
        notifications.onSelect = { [weak self] thread in Task { await self?.select(thread) } }
        if !messageAlertsEnabled { notifications.clearAlerts() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.markSelectedViewed() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.markSelectedViewed() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconnect() }
        })
        network.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { @MainActor in guard let self, self.state == "offline" || self.state == "reconnecting" else { return }; self.scheduleReconnect() } }
        }
        network.start(queue: DispatchQueue(label: "dev.instadm.network"))
        await restore()
    }

    private func restore() async {
        do {
            let session = try keychain.load()
            if let value = session, value["account"] != .null { try setAccount(value["account"].decode(Account.self)) }
            try core.start()
            _ = try await core.request("hello")
            _ = try await core.request("restore", .object(["session": session ?? .null]))
            showLogin = account == nil
        } catch { present(error); if account == nil { state = "login_required"; showLogin = true } else { state = "offline" } }
    }

    func login(fields: [String: String]) async {
        guard !isBusy else { return }
        let generation = loginGeneration
        isBusy = true; errorMessage = nil
        defer { if generation == loginGeneration { isBusy = false } }
        do {
            try core.start()
            var pendingFields = fields
            while generation == loginGeneration {
                let response = try await core.request("login", .object(["fields": .object(pendingFields.mapValues(JSONValue.string))]), timeout: .seconds(660))
                guard generation == loginGeneration else { return }
                if response["step"] == .null {
                    loginStep = nil; showLogin = false
                    return
                }
                loginStep = try response["step"].decode(LoginStep.self)
                guard loginStep?.type == "display_and_wait" else { return }
                // The helper polls Instagram while the user approves on their phone.
                pendingFields = [:]
            }
        } catch { if generation == loginGeneration { present(error) } }
    }

    func cancelLogin() async {
        // Restarting the helper also cancels long-running verification requests.
        loginGeneration += 1
        core.stop(); isBusy = false; loginStep = nil; errorMessage = nil
        do {
            try core.start()
            let saved = try keychain.load()
            let deviceOnly: JSONValue = .object(["version": .integer(1), "device": saved?["device"] ?? .null])
            _ = try await core.request("restore", .object(["session": deviceOnly]))
        } catch { present(error) }
    }

    func reconnect() async {
        guard !isBusy else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        isBusy = true; errorMessage = nil; state = "connecting"
        defer { isBusy = false }
        core.stop(); isSyncing = false
        await restore()
    }

    func refresh() async {
        guard account != nil, !isSyncing, state == "connected" else { return }
        isSyncing = true
        do {
            let anchors = try database?.anchors() ?? [:]
            _ = try await core.request("sync", .object(["anchors": try .encode(anchors)]))
        } catch { isSyncing = false; present(error) }
    }

    func select(_ id: String?) async {
        saveDraft()
        selectedID = id; draft = ""; attachments = []; messages = []; hasOlderMessages = false
        guard let id else { return }
        do {
            draft = try database?.draft(for: id) ?? ""
            attachments = try database?.draftAttachments(for: id) ?? []
            if isViewingConversation { try database?.markViewed(id) }
            try reload()
            hasOlderMessages = hasMore[id] ?? true
            if state == "connected" { await loadHistory(id, older: false) }
        } catch { present(error) }
    }

    func loadOlder() async { if let selectedID { await loadHistory(selectedID, older: true) } }

    private func loadHistory(_ thread: String, older: Bool) async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true; defer { isLoadingHistory = false }
        do {
            let response = try await core.request("history", .object(["threadID": .string(thread), "cursor": .string(older ? cursors[thread] ?? "" : "")]))
            let page = try response.decode(MessagePage.self)
            try apply(page)
            cursors[thread] = page.cursor; hasMore[thread] = page.hasMore
            if selectedID == thread { hasOlderMessages = page.hasMore; if isViewingConversation { try database?.markViewed(thread) }; try reload() }
        } catch { present(error) }
    }

    func send() async {
        guard canSend, let thread = selectedID, let account, let database else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        var outgoing = attachments.map { attachment in
            let clientID = Message.newClientID()
            return Message(id: "local:\(clientID)", threadID: thread, clientID: clientID, senderID: account.messagingID, senderName: account.name, text: attachment.filename, timestamp: Int64(Date().timeIntervalSince1970 * 1000), isOwn: true, status: .sending, kind: attachment.isImage ? "image" : "file", attachment: attachment)
        }
        if !text.isEmpty {
            let clientID = Message.newClientID()
            outgoing.append(Message(id: "local:\(clientID)", threadID: thread, clientID: clientID, senderID: account.messagingID, senderName: account.name, text: text, timestamp: Int64(Date().timeIntervalSince1970 * 1000), isOwn: true, status: .sending))
        }
        isSendingAttachments = !attachments.isEmpty
        defer { isSendingAttachments = false }
        do {
            try database.upsert(outgoing) // Durable intent before crossing the pipe.
            try database.saveDraft("", thread: thread); try database.saveDraftAttachments([], thread: thread)
            draft = ""; attachments = []; try reload()
        } catch {
            for message in outgoing { try? database.markSend(clientID: message.clientID, status: .failed) }
            present(error); return
        }
        for (index, message) in outgoing.enumerated() {
            do {
                guard self.account?.id == account.id else { throw CoreError(code: "not_sent", message: "The account changed before this message was sent.") }
                let result: JSONValue
                if let attachment = message.attachment {
                    guard let path = attachment.localPath else { throw CoreError(code: "not_sent", message: "The local attachment is unavailable. Attach the file again.") }
                    result = try await core.request("send_media", .object(["threadID": .string(thread), "clientID": .string(message.clientID), "path": .string(path), "attachment": try .encode(attachment)]), timeout: .seconds(190))
                } else {
                    result = try await core.request("send", .object(["threadID": .string(thread), "clientID": .string(message.clientID), "text": .string(message.text)]))
                }
                try database.upsert([result.decode(Message.self)])
                if self.account?.id == account.id { try reload() }
            } catch {
                let knownNotSent = ["not_sent", "invalid_input", "login_required"].contains((error as? CoreError)?.code ?? "")
                try? database.markSend(clientID: message.clientID, status: knownNotSent ? .failed : .unknown)
                for remaining in outgoing.dropFirst(index + 1) { try? database.markSend(clientID: remaining.clientID, status: .failed) }
                if self.account?.id == account.id { try? reload(); present(error) }
                break
            }
        }
    }

    func reuse(_ message: Message) {
        if let attachment = message.attachment {
            guard attachments.count < 10 else { present(CoreError(code: "attachment", message: "Attach up to 10 files at a time.")); return }
            if !attachments.contains(where: { $0.id == attachment.id }) { attachments.append(attachment) }
        } else { draft = message.text }
        saveDraft()
    }
    func saveDraft() {
        guard let selectedID else { return }
        do { try database?.saveDraft(draft, thread: selectedID); try database?.saveDraftAttachments(attachments, thread: selectedID) } catch { present(error) }
    }

    func pasteAttachments() -> Bool {
        let contents = AttachmentPasteboard.read()
        guard !contents.isEmpty else { return false }
        addAttachments(contents); return true
    }
    func attachFiles(_ urls: [URL]) { addAttachments(urls.map(AttachmentPasteboard.Content.file)) }
    func removeAttachment(_ attachment: MessageAttachment) {
        guard let selectedID, let database else { return }
        do {
            let remaining = attachments.filter { $0.id != attachment.id }
            try database.saveDraftAttachments(remaining, thread: selectedID)
            attachments = remaining
            if try !database.referencesAttachment(attachment.id), let url = attachment.localURL,
               url.deletingLastPathComponent().standardizedFileURL == attachmentStore?.directory.standardizedFileURL,
               url.lastPathComponent == attachment.id { try? FileManager.default.removeItem(at: url) }
        } catch { present(error) }
    }
    private func addAttachments(_ contents: [AttachmentPasteboard.Content]) {
        guard !contents.isEmpty, !isPreparingAttachments, let thread = selectedID, let accountID = account?.id, let database, let storage = attachmentStore else { return }
        guard attachments.count + contents.count <= 10 else { present(CoreError(code: "attachment", message: "Attach up to 10 files at a time.")); return }
        isPreparingAttachments = true
        Task {
            defer { isPreparingAttachments = false }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    var prepared: [MessageAttachment] = []
                    do {
                        for content in contents {
                            switch content {
                            case .file(let url): prepared.append(try storage.prepare(file: url))
                            case .image(let data, let type): prepared.append(try storage.prepare(data: data, filename: "Pasted image.\(type.preferredFilenameExtension ?? "png")", type: type))
                            }
                        }
                        return prepared
                    } catch {
                        for attachment in prepared { if let url = attachment.localURL { try? FileManager.default.removeItem(at: url) } }
                        throw error
                    }
                }.value
                var saved = try database.draftAttachments(for: thread)
                saved.append(contentsOf: prepared)
                try database.saveDraftAttachments(saved, thread: thread)
                if account?.id == accountID && selectedID == thread { attachments = saved }
            } catch {
                if account?.id == accountID { present(error is CoreError ? error : CoreError(code: "attachment", message: "The attachment could not be prepared. Check that the file is readable.")) }
            }
        }
    }

    func signOut() async {
        reconnectTask?.cancel(); syncTask?.cancel()
        core.stop()
        sharedMedia?.close(); sharedMedia = nil
        ravenMedia?.close(); ravenMedia = nil
        if let cache = appearanceCache { Task { await cache.clear() } }; appearanceCache = nil
        do { try keychain.delete() } catch { present(error); return }
        database = nil; attachmentStore = nil; account = nil; conversations = []; messages = []; draft = ""; attachments = []; selectedID = nil
        cursors = [:]; hasMore = [:]; loginStep = nil; isSyncing = false; isBusy = false
        state = "login_required"; statusMessage = "Sign in to Instagram"; showLogin = true
        notifications.updateBadge(unreadCount: 0); notifications.clearAlerts()
        do { try core.start(); _ = try await core.request("restore", .object(["session": .null])) } catch { present(error) }
    }

    func setMessageAlerts(_ enabled: Bool) async {
        if enabled { messageAlertsEnabled = await notifications.requestPermission() }
        else { messageAlertsEnabled = false; notifications.clearAlerts() }
        UserDefaults.standard.set(messageAlertsEnabled, forKey: "messageAlertsEnabled")
    }

    func shutdown() {
        ravenMedia?.close()
        sharedMedia?.stopPlayback()
        saveDraft(); reconnectTask?.cancel(); syncTask?.cancel(); network.cancel(); core.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        notifications.updateBadge(unreadCount: 0)
    }

    private func setAccount(_ newAccount: Account) throws {
        if account?.id != newAccount.id || database == nil {
            guard !newAccount.id.isEmpty, newAccount.id.allSatisfy(\.isNumber) else { throw CoreError(code: "account", message: "Instagram returned an invalid account identifier.") }
            saveDraft(); selectedID = nil; draft = ""; attachments = []; messages = []; cursors = [:]; hasMore = [:]
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "InstaDM/Accounts/\(newAccount.id)")
            database = try MessageDatabase(url: directory.appending(path: "messages.sqlite"))
            ravenMedia?.close()
            if let database {
                let temporaryMedia = FileManager.default.temporaryDirectory.appending(path: "Gramline/DisappearingMedia/\(newAccount.id)")
                ravenMedia = RavenMediaService(directory: temporaryMedia, database: database, changed: { [weak self] in try? self?.reload() }) { [weak self] command, data in
                    guard let self, self.account?.id == newAccount.id else { throw CancellationError() }
                    let response = try await self.core.request(command, data)
                    guard self.account?.id == newAccount.id else { throw CancellationError() }
                    return response
                }
            }
            attachmentStore = AttachmentStore(directory: directory.appending(path: "Attachments"))
            if let cache = appearanceCache { Task { await cache.clear() } }
            appearanceCache = SharedMediaCache(directory: directory.appending(path: "Appearance"), byteLimit: 64_000_000)
            sharedMedia?.close()
            sharedMedia = SharedPostService(directory: directory.appending(path: "SharedMedia")) { [weak self] post in
                guard let self, self.account?.id == newAccount.id else { throw CoreError(code: "account", message: "Sign in to view this post.") }
                let response = try await self.core.request("shared_post", .encode(post))
                guard self.account?.id == newAccount.id else { throw CancellationError() }
                return try response.decode(SharedPostContent.self)
            } resolveMessage: { [weak self] message in
                guard let self, self.account?.id == newAccount.id else { throw CancellationError() }
                let newer = self.messages.first { $0.threadID == message.threadID && $0.timestamp > message.timestamp && $0.status == .sent }
                let response = try await self.core.request("message_media", .object([
                    "threadID": .string(message.threadID), "messageID": .string(message.id),
                    "newerMessageID": .string(newer?.id ?? "")
                ]))
                guard self.account?.id == newAccount.id else { throw CancellationError() }
                return try response.decode(DirectMedia.self)
            }
        }
        account = newAccount; showLogin = false; try reload()
    }

    private func receive(_ frame: WireFrame) throws {
        let data = frame.data ?? .null
        do {
            switch frame.type {
            case "login_diagnostic":
                loginDiagnostic = [data["stage"].string, data["reason"].string, data["errorType"].string, data["httpStatus"].string].compactMap { $0 }.joined(separator: " · ")
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "InstaDM")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(data).write(to: directory.appending(path: "login-diagnostic.json"), options: [.atomic, .completeFileProtection])
            case "session":
                guard let saveID = data["saveID"].string else { return }
                do { try keychain.save(data["state"]); core.acknowledge(saveID: saveID, success: true) }
                catch { core.acknowledge(saveID: saveID, success: false); present(error); state = "offline"; throw error }
            case "account": try setAccount(data.decode(Account.self))
            case "connection":
                state = data["state"].string ?? "offline"; statusMessage = data["message"].string ?? ""
                if state == "login_required" { showLogin = true }
            case "conversation": try database?.upsert(data.decode(Conversation.self)); try reload()
            case "messages": try apply(data.decode(MessagePage.self))
            case "message":
                let message = try data.decode(Message.self)
                let inserted = try database?.upsert([message]) ?? []
                if message.threadID == selectedID && isViewingConversation { try database?.markViewed(message.threadID) }
                try reload()
                if messageAlertsEnabled && inserted.contains(message.id) && !message.isOwn && !(isViewingConversation && selectedID == message.threadID) {
                    notifications.deliver(message, title: conversations.first { $0.id == message.threadID }?.title ?? "Instagram")
                }
                if conversations.first(where: { $0.id == message.threadID })?.title == "Instagram conversation" { scheduleSync() }
            case "thread_synced":
                struct Anchor: Decodable { var threadID: String; var timestamp: Int64 }
                let anchor = try data.decode(Anchor.self); try database?.markSynced(thread: anchor.threadID, timestamp: anchor.timestamp)
            case "read_receipt":
                struct Receipt: Decodable { var threadID: String; var timestamp: Int64 }
                let receipt = try data.decode(Receipt.self)
                try database?.markRead(receipt.threadID, through: receipt.timestamp); try reload()
            case "message_edit": try database?.editMessage(id: data["id"].string ?? "", text: data["text"].string ?? ""); try reload()
            case "message_delete": try database?.deleteMessage(id: data["id"].string ?? ""); try reload()
            case "conversation_delete":
                let id = data["id"].string ?? ""; try database?.deleteConversation(id: id)
                if id == selectedID { selectedID = nil; messages = []; draft = ""; attachments = [] }; try reload()
            case "sync_required": scheduleSync()
            case "sync_finished":
                isSyncing = false
                if data["error"] != .null { present(try data["error"].decode(CoreError.self)) }
                else {
                    restartAttempts = 0
                    try reload()
                    if let selectedID { Task { await self.loadHistory(selectedID, older: false) } }
                }
            case "reconnect_required": scheduleReconnect()
            default: break
            }
        } catch { present(error); state = "offline"; statusMessage = "Local storage or connection error"; throw error }
    }

    private func apply(_ page: MessagePage) throws {
        if let conversation = page.conversation { try database?.upsert(conversation) }
        try database?.upsert(page.messages)
        if isViewingConversation, let selectedID { try database?.markViewed(selectedID) }
        try reload()
    }
    private func reload() throws {
        conversations = try database?.conversations() ?? []
        if let selectedID { messages = try database?.messages(in: selectedID) ?? [] }
        notifications.updateBadge(unreadCount: try database?.unreadMessageCount() ?? 0)
    }
    private var isViewingConversation: Bool {
        NSApp.isActive && NSApp.mainWindow?.isVisible == true && NSApp.mainWindow?.isMiniaturized == false
    }
    private func markSelectedViewed() {
        guard isViewingConversation, let selectedID else { return }
        do { try database?.markViewed(selectedID); try reload() } catch { present(error) }
    }
    private func scheduleSync() {
        guard !isSyncing else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in do { try await Task.sleep(for: .milliseconds(350)) } catch { return }; await self?.refresh() }
    }
    private func scheduleReconnect() {
        guard account != nil, !isBusy else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(2)) } catch { return }; await self?.reconnect() }
    }
    private func helperExited() {
        state = "offline"; statusMessage = "Connection helper stopped"; isSyncing = false
        guard account != nil, restartAttempts < 3 else { return }
        restartAttempts += 1; scheduleReconnect()
    }
    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        if let error = error as? CoreError, error.code == "login_required" || error.code == "challenge" { state = "login_required"; showLogin = true }
    }
}
