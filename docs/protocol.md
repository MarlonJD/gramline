# Private pipe protocol, version 1

UTF-8 JSON, one object per line. Stdout contains protocol frames only. Stderr never contains request bodies or upstream responses. Both readers reject frames larger than 16 MiB. Strings carry all account, conversation and message identifiers.

```json
{"v":1,"id":"request-uuid","type":"history","data":{"threadID":"thread-id","cursor":""}}
{"v":1,"id":"request-uuid","type":"response","data":{"messages":[],"cursor":"","hasMore":false}}
{"v":1,"type":"connection","data":{"state":"connected","message":"Connected"}}
```

Responses echo request IDs and use `type: response`. Failures contain `error: {code, message}` with a safe user-facing message. Events have no request ID. The helper processes commands serially and accepts session acknowledgements independently, including while a command is waiting for persistence. Inbox synchronization is a background job and does not hold the command dispatcher.

| Command | Data | Result |
| --- | --- | --- |
| `hello` | Empty object | Protocol and upstream version |
| `restore` | `session`: saved object or null | Authentication state; may connect |
| `login` | `fields`: string dictionary | Library login step or authenticated account |
| `cancel_login` | Empty object | Resets incomplete login, retaining device identity |
| `reconnect` | Empty object | Recreates connection using saved credentials |
| `sync` | `anchors`: thread ID to last complete timestamp | `started`: whether a new job was accepted; false if one is already running |
| `history` | `threadID`, `cursor` | Conversation, messages, next cursor and hasMore |
| `shared_post` | A `SharedPost` object | Author, caption, ordered media items and selected carousel index |
| `send` | `threadID`, `clientID`, `text` | Confirmed server message, or safe delivery error |
| `message_media` | `threadID`, `messageID`, optional `newerMessageID` | Refresh ordinary photo/video metadata by exact message identity; restricted modes contain no URLs |
| `send_media` | `threadID`, `clientID`, absolute staged `path`, `attachment` metadata | Confirmed server message with attachment metadata, or safe delivery error; three-minute deadline |
| `logout` | Empty object | Stops the connection; Swift removes Keychain state |
| `shutdown` | Empty object | Acknowledges and exits |

Events include `account`, `connection`, `conversation`, `messages`, `message`, `message_edit`, `message_delete`, `conversation_delete`, `read_receipt`, `thread_synced`, `sync_required`, `sync_finished`, `reconnect_required`, `session` and `login_diagnostic`.

`read_receipt` contains `threadID` and an integer-millisecond `timestamp`. It represents the viewer reading through that timestamp on another device. Swift merges it monotonically with the local watermark and immediately updates the badge. Receipts from other participants do not produce this event.

`sync_finished` contains either `result` with synchronization counts or `error` with a safe code and message. Cancelling the connection cancels and joins its sync job before the client is replaced. Conversation payloads include an optional `readAt` timestamp when Instagram supplies the current viewer's read receipt.

Account and conversation payloads may include `avatarURL`. Conversations may also include `theme` with `normal` and `dark` palettes: background URL/color, outgoing gradient colors/text, incoming bubble/text, navigation, and composer colors. Colors are eight-digit ARGB strings. `themeLoaded: true` means the detail query supplied an authoritative appearance snapshot; a missing theme then restores the default. A mailbox payload without `themeLoaded` does not overwrite stored appearance.

For a `session` event, data includes `saveID` and the sensitive `state` object. Swift writes Keychain, then sends `{"v":1,"type":"session_ack","data":{"saveID":"…","ok":true}}`. A negative or missing acknowledgement fails the dependent operation. Checkpoints and wire frames must never be copied into application logs.

`send_unknown` means a request crossed the network boundary and delivery is uncertain. `not_sent` means the helper rejected it before transmission. Neither condition triggers an automatic send retry.

For `send_media`, uploading bytes does not commit a message. Upload failures return `not_sent`; failures after entering `SendMedia` return `send_unknown`. Attachment metadata includes `id`, `filename`, `mimeType` and `byteCount`. Swift retains the private `localPath` in its database and reconciles it with server responses; the helper does not return local paths. Photos are limited to 8 MB, other files to 25 MB. Binary data never enters the JSON pipe.

Messages can contain `sharedPost`: `mediaID`, `shortcode`, canonical Instagram `url`, `kind` (`post` or `reel`), `author`, `title`, `caption`, `previewURL`, and `selectedItemID`. IDs remain strings. Only Instagram post/Reel XMA shares become cards; story and unrelated links retain ordinary message handling. Reopening a conversation fetches fresh history and enriches messages previously stored as descriptive attachments.

`shared_post` requires an authenticated client and resolves the post through `instameow.FetchMedia`. Its result contains `author`, `caption`, `items` and `selectedIndex`. Each item has string `id`, `kind` (`image` or `video`), `url`, `previewURL`, `width` and `height`. Album order is preserved, including unavailable children with an empty media URL. `media_unavailable` is a safe failure without upstream bodies. Swift downloads allowed HTTPS CDN URLs directly into a disposable cache, outside command dispatch; media bytes never travel through the pipe.

Messages can also contain `directMedia`: a media `kind`, optional Raven `viewMode`, and ordered `items` using the shared-media item shape. View modes 0 (once), 1 (replay) and unknown restricted modes carry an empty item array; only mode 2 (keep in chat) or ordinary media expose validated download locations. A refresh rechecks the current mode and never uses another message as a substitute.
