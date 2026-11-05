# Architecture

## Ownership

`InstaDM` is a SwiftPM macOS executable. `AppStore` owns account and connection state. Feature views own only presentation and input state. `CoreProcess` starts the packaged helper and manages request IDs, deadlines, private pipes and termination. `SessionKeychain` owns credential persistence. `MessageDatabase` is isolated to the main actor and is the only history writer.

`insta-core` is a Go child process with no listening socket. It adapts the pinned `instameow` client into the app's command/event types. The dependency includes Matrix bridge types for login steps, but no Matrix server, Matrix account or bridge process is instantiated.

## Login and session lifetime

The helper requests a Keychain checkpoint before accepting a newly generated Android installation identity. Swift acknowledges only after Keychain persistence succeeds. The same checkpoint mechanism persists cookies, native authorization and account identity. Credentials entered into the UI cross only the child's stdin pipe and the upstream HTTPS login transport. They never enter SQLite, command-line arguments or environment variables.

The native login adapter renders the library's input field IDs and selection options directly, preserving verification state between submissions. Structured errors distinguish unsupported MFA, account recovery, CAPTCHA requirements, expired approval, rate limits, transport failure and protocol setup errors. Diagnostic output uses an allowlist and never includes raw error strings.

A sign-in attempt has one context with a ten-minute deadline. It remains alive between input steps because upstream Bloks approval timers capture their creation context. Cancellation, helper EOF and completion end that lifetime. A `display_and_wait` step starts the next helper request automatically while Swift displays the approval instructions. Restarting sign-in invalidates outstanding UI results.

The maintained dependency executes named approval timers serially, honoring one-shot/repeating behavior, callback arguments, replacement and cancellation. It does not rely on a fixed list of timer names or run concurrent callbacks against the stateful interpreter.

On reopening, saved cookies and native session initialize a new client. `LoadIndex` loads current connection configuration. A fresh client cannot report `IsAuthenticated` until its viewer data has loaded, so the restore gate checks saved cookies first. Authentication lifetime does not depend on the library's 24-hour connection configuration cache.

## Catch-up and history

The socket emits live deltas and handles transient reconnects. Each connection schedules an inbox refresh. Inbox pagination includes pinned threads and deduplicates conversations. For previously synchronized conversations, history is paginated until it reaches the saved watermark. A watermark advances only after every required page has been successfully delivered to Swift. Live messages and partially downloaded history do not advance it. Repeated pagination cursors fail explicitly rather than silently claiming completion.

The first mailbox snapshot establishes each new conversation's baseline and stores any preview messages already included in that response. Opening a conversation fetches its message page; older history is loaded on demand. Unchanged conversations do not fetch history again. Synchronization runs as one background job so sends and selected-conversation history requests remain available. The job captures its client and account, uses a ten-minute deadline, and is cancelled and joined before replacing the client. Swift remains the only database writer. A `sync_finished` event reports completion or a safe error.

## Composer and unread messages

Return submits the draft. A narrow `NSTextView` representable handles native paste, selection, undo and IME composition while SwiftUI owns the bound text. Shift+Return inserts a newline; the scroll viewport grows from one to three visible lines, then scrolls internally. Plain text retains native paste behavior. Explicit paste actions recognize copied file URLs before bitmap data, avoiding accidental attachment of Finder icons.

The message timeline groups adjacent messages from the same sender with compact spacing and one sender label. A date/time separator starts the visible history, a new local calendar day, or a gap of at least five minutes. Exact timestamps remain available as bubble tooltips. Routine `Sent` labels appear only on the final outgoing message; pending, failed and uncertain delivery states remain individually visible.

## Attachments

`AttachmentStore` stages private account-local copies off the main actor before offering them for sending. Draft attachment metadata is persisted in SQLite. Native image formats such as pasted TIFF or HEIC are normalized to PNG; supported JPEG/PNG/GIF/WebP files keep their bytes. Photo and file size limits are 8 MB and 25 MB. The composer accepts up to ten attachments, previews them, and sends any text as a separate final message.

The pipe carries a staged file path and metadata instead of embedding base64 into bounded JSON frames. The helper validates the regular file, length, MIME type and safe multipart filename, fetches the messaging thread key for upload, calls the dependency's Mercury upload, then commits the attachment with `SendMedia` and the original client ID. The operation has a three-minute deadline. Failed upload/preparation is definitely not sent; failed final commit is uncertain. A batch stops on failure and marks later unsent intents failed. No attachment or uncertain commit is automatically retried by the app.

The database preserves local attachment metadata through optimistic-send reconciliation, including echo-before-response ordering and later history updates. File previews are generated as bounded thumbnails. Uploaded history files are retained locally; removing an unreferenced draft attachment removes its staged copy.

The Dock badge is enabled without requesting alert permission. It is hidden at zero, displays `1`, `2`, `3` or `4`, and uses `4+` above four. Actual incoming messages after the effective read watermark are counted once, including older unread history. An empty/unloaded conversation does not contribute an invented message; additional history can increase the count when fetched. Local read watermarks are persisted and merged with Instagram's viewer read receipts so stale snapshots cannot undo reading on this Mac. Live viewer receipts and mark-read events update the count directly, without waiting for a full inbox synchronization. Other participants' receipts cannot clear the viewer's unread count. The badge clears as conversations are read and on sign-out. Reading here does not transmit an outbound read receipt to Instagram.

Banner and sound alerts are opt-in under Settings. They are disabled by default and independent of the Dock badge.

## Conversation appearance

The normalizer uses Instagram's thread image for group identity and the other participant's profile picture for a direct conversation without a thread image. It never substitutes the signed-in user's photo for the other participant or a single participant's photo for an unnamed group. The authenticated viewer supplies the account photo.

History requests enable `IGDEnableOffMsysChatThemesQE` on the existing `IGDThreadDetailQuery`. A small typed dependency extension decodes the observed `theme_data` schema. The app normalizes normal/dark ARGB palettes and allowed background CDN assets. SwiftUI selects the matching macOS color scheme and renders the actual wallpaper behind the scrolling message list, using matching message, header and composer colors. Native text-editor text and caret colors follow the composer palette.

Appearance metadata lives in the conversation's SQLite payload. A mailbox snapshot that did not request themes preserves the known theme; an explicit theme-loaded detail with no theme resets to the default. Images use a separate bounded 64 MB account cache and clear on sign-out. Missing images retain initials or the server's background color. No synthetic theme is substituted and no remote appearance mutation is sent.

## Shared posts and Reels

The Go adapter preserves XMA post/Reel identity, canonical Instagram links, captions and cover addresses instead of flattening the share into attachment text. The `shared_post` command resolves full photo/video versions and carousel children through the authenticated `instameow.FetchMedia` API. A shared carousel child determines the initial viewer position. Missing children remain explicit unavailable positions rather than silently changing album order.

Swift stores the stable share metadata in the message payload. `SharedPostService` deduplicates metadata lookups and caches results for five minutes. `SharedMediaCache` downloads only allowed HTTPS Instagram CDN URLs using an ephemeral URL session without cookies or credential storage. Redirects are checked against the same domain restrictions. Size limits are enforced during transfer and again before committing a private file. Four download slots bound concurrency; media transfers do not block the helper's command dispatcher. Retained files are capped at 512 MB with 24-hour age eviction on access, and sign-out cancels work and clears the account's disposable media cache.

Cards load only cover images. Clicking opens a single sheet with a large image or an `AVPlayerView` wrapped in a small `NSViewRepresentable`. SwiftUI owns presentation, album selection and the player lifetime; AVKit owns native playback controls. The account service pauses the previously active player before starting another, and selection changes or dismissal stop playback. A stale CDN response triggers one metadata refresh using the stable post ID. Unavailable content retains a direct Instagram link and explicit retry action.

The native view avoids a crash observed in the operating system's `_AVKit_SwiftUI` metadata initialization when using SwiftUI `VideoPlayer`. No alternate player path is retained.

## Outgoing delivery

Before sending, Swift saves an optimistic message with a 64-bit offline threading ID. Exactly one helper send request is issued for that intent. Server responses and live echoes reconcile using the client ID, then persist the server message ID. Duplicate responses/history upsert the same message.

Errors before entering the network are `failed`. Any failure after entering the request is `unknown`, since loss of the response does not establish that Instagram rejected the message. Pending sends at application restart become `unknown`. There is no automatic retry queue. A user can refresh and explicitly copy text back to the composer.

## Process lifetime

The app keeps running after the last window closes. Quit closes stdin and terminates the helper. EOF cancels in-flight helper work. Unexpected helper exit fails pending requests and triggers bounded restart attempts. Wake and network recovery schedule a reconnect. No account credentials are required by the local test suite.

## Source boundaries

- `Sources/DMCore`: Codable wire models, framing, SQLite persistence.
- `Sources/InstaDM/App`: SwiftUI scenes and application lifecycle.
- `Sources/InstaDM/Views`: login, inbox, conversation, composer and settings.
- `Sources/InstaDM/Stores`: application state and synchronization coordination.
- `Sources/InstaDM/Services`: helper process, Keychain and notifications.
- `core/internal/wire`: JSON-lines framing, dispatch and persistence acknowledgements.
- `core/internal/instagram`: login, model normalization, history, sends and events.
- `script`: reproducible build/run, tests and packaged-helper smoke test.

## Upstream references

- [Authentication documentation](https://docs.mau.fi/bridges/go/meta/authentication.html)
- [Pinned upstream source](https://github.com/mautrix/meta/tree/a3afe226a33ad086f5b6b1a559c9ece7e69b213b)
- [Client parameters and connection cache](https://github.com/mautrix/meta/blob/a3afe226a33ad086f5b6b1a559c9ece7e69b213b/pkg/instameow/client.go)
- [Android setup and persistent session](https://github.com/mautrix/meta/blob/a3afe226a33ad086f5b6b1a559c9ece7e69b213b/pkg/instameow/login_mobile.go)


## Direct photo and video messages

The Go normalizer preserves ordinary photo/video attachments, mixed albums and Raven viewing modes. Missing media remains an explicit unavailable position. CDN addresses pass the same allowlist as post media. The client does not implement Instagram's consume/replay lifecycle: view-once, replayable and unknown restricted Raven modes expose no URLs, previews or downloadable items. They render a mode-specific phone-opening notice. Keep-in-chat Raven media uses the ordinary viewer.

Ordinary media shares the bounded account-local media cache and native player with post/Reel viewing. A stale CDN response triggers one `message_media` refresh by exact message ID, using the next known message as a pagination anchor when available. Refreshed metadata is normalized again, so a restricted or removed item cannot fall back to a stale playable URL. Dismissal or conversation changes stop playback.

## Window identity and appearance

The selected Instagram palette colors the full conversation window, including the native SwiftUI window toolbar, sidebar, account footer, search field, unread dots and selected conversation. The selection uses a subdued version of the actual outgoing color. Native window controls and dragging remain intact; no window subclass or titlebar overlay is used. Sidebar row buttons expose selected accessibility state and retain keyboard move commands. The bundled icon is generated from the checked-in transparent raster master with macOS `sips` and `iconutil` during packaging.
