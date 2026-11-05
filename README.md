<p align="center">
  <img src="Resources/Brand/Gramline.png" width="144" alt="Gramline app icon" />
</p>

<h1 align="center">Gramline</h1>

<p align="center"><strong>Your Instagram inbox. At home on your Mac.</strong></p>
<p align="center">A native macOS client for conversations, photos and shared Reels.<br />SwiftUI on the outside. A local Go connection engine underneath.</p>

<p align="center">
  <a href="#get-started">Get started</a> ·
  <a href="#using-gramline">Usage</a> ·
  <a href="#current-limits">Current limits</a> ·
  <a href="docs/architecture.md">Architecture</a>
</p>

---

Gramline keeps Instagram messaging in a focused desktop window: a searchable inbox, a keyboard-friendly composer, real profile pictures and your existing conversation themes. It connects directly through the bundled [instameow](https://github.com/mautrix/meta) client. No Matrix server, hosted backend or browser wrapper is required.

This is an independent development preview, not an official Instagram or Meta application. The source lives in **[MarlonJD/gramline](https://github.com/MarlonJD/gramline)**.

## What it does

| | |
| --- | --- |
| **Conversations** | Search your existing inbox, receive live messages, load older history and keep drafts between launches. |
| **Native composition** | Return sends; Shift+Return adds a line. The editor grows to three visible lines and supports native selection, undo and text input. |
| **Photos and files** | Paste images or copied Finder files with ⌘V, or use the attachment picker. Review attachments before sending. |
| **Posts and Reels** | Open shared posts, browse photo albums and play videos with native playback controls, sound and seeking. |
| **Incoming media** | Preview ordinary photos/videos and open view-once media in a separate disappearing viewer. Replayable media offers one explicit replay while that viewer remains open. |
| **Your chat themes** | Real Instagram wallpapers and bubble colors, with matching sidebar, search, selection, header and composer colors. Profile and group photos appear throughout. |
| **Quiet by default** | A Dock unread badge without recurring banners or sounds. Optional alerts are available in Settings. |
| **Local persistence** | Session state in macOS Keychain; per-account message history and drafts in SQLite. |

## Get started

You need **macOS 14 or newer**, **Xcode with Swift 6.2+**, and **Go 1.26+**. The first build downloads Go dependencies. Local development has been verified on Apple Silicon.

```sh
git clone https://github.com/MarlonJD/gramline.git
cd gramline
./script/build_and_run.sh
```

The script builds the SwiftUI application and Go helper, generates the macOS icon, packages everything into `dist/Gramline.app`, applies a local ad hoc signature and launches it. You can also drag that bundle into Applications.

To build without launching:

```sh
./script/build_and_run.sh --build-only
```

Sign in directly in the app. The native login form handles username/password and the verification steps supplied by Instagram. OTP login and restoring a saved session have been verified with a real account. Passwords and verification codes are never persisted. Additional security challenges depend on the upstream login flow.

Local builds are **not Developer ID signed or notarized releases**. There is no published installer in this repository.

## Using Gramline

| Action | Shortcut or control |
| --- | --- |
| Send a message | Return |
| Add a new line | Shift+Return |
| Paste a photo or copied file | ⌘V in the composer |
| Choose attachments | Paperclip button |
| Search conversations | Search field or ⌘F |
| Refresh the inbox | ⌘R |
| Open a post, Reel, photo or video | Click its card |
| Navigate an album | Previous / Next or arrow keys in the viewer |
| Close the media viewer | Escape |

You can attach up to **10 items** at a time: **8 MB per photo** and **25 MB per other file**. Text accompanying attachments is sent as a separate message. File-type support ultimately depends on Instagram.

The Dock badge is hidden at zero, displays **1, 2, 3, 4**, then **4+** above four. Previously unread messages are included. Opening a conversation clears its local unread count; read updates from your other Instagram devices also update the badge. Closing the window keeps the connection alive. Quitting stops it.

Consecutive messages are grouped. A time separator appears after a five-minute gap or a day change; hover over a bubble for its exact timestamp. Unconfirmed sends remain visibly unconfirmed and are never automatically sent again.

## Current limits

- Disappearing media respects Instagram's viewing count and expiry. Opening sends a visual receipt to Instagram. Replay is implemented inside the current viewer when Instagram permits it; closing discards the temporary content. An uncertain receipt is never automatically retried. Real-account photo opening is verified. The final in-viewer replay and disappearing-video playback have not yet been verified against a real account; see the [verification record](docs/verification.md).
- Incoming general files, voice messages, stories, reactions, calls, creating new conversations and sending read receipts to Instagram are not implemented. Outgoing files are supported; this does not imply every incoming attachment type has a viewer.
- Posts must be accessible to the signed-in account. Deleted or unavailable content may fail to load. This app does not provide a feed or Explore page.
- The connection uses unofficial Instagram APIs. Server changes can require client updates. Device-notification login approval and real-account recovery after an offline gap have not been fully verified.

## How it is built

```text
SwiftUI + AppKit
  ├─ Keychain session storage
  ├─ SQLite history and drafts
  ├─ Image cache + native AVKit playback
  └─ Versioned JSON over stdin/stdout
       └─ Bundled Go helper
            └─ instameow → Instagram
```

**Swift owns presentation and local storage.** The Go helper owns the Instagram connection, authentication and protocol normalization. Communication uses bounded, versioned JSON frames over local pipes. A saved session includes cookies, native login state and device identity; the connection cache alone is not treated as a session.

The dependency is pinned to `v0.2610.1-0.20261105141638-a3afe226a33a`. Its maintained source snapshot is included in `third_party/mautrix-meta`, with narrowly scoped fixes for login operations, approval timers, upload metadata, theme decoding and native-session headers. Gramline's own adapter handles disappearing-media lookup and visual receipts. Builds do not modify the Go module cache. See the [dependency notes](third_party/README.md).

## Data on your Mac

- **Session:** macOS Keychain service `dev.instadm.mac.session`.
- **Messages, drafts and sent attachments:** `~/Library/Application Support/InstaDM/Accounts/<account ID>/`. Each account has its own database and attachment directory. Files have private permissions but are not application-encrypted.
- **Shared media cache:** up to 512 MB, with 24-hour retention checked on access. Individual viewing limits are 20 MB per image and 128 MB per video.
- **Profile pictures and wallpaper:** a separate 64 MB appearance cache with the same retention policy. Existing themes are displayed locally; the app does not change the conversation theme for other participants.
- **Disappearing media:** private temporary files for the current viewer, deleted on close, sign-out and the next account startup after a crash. Viewing reservations in SQLite prevent an interrupted request from opening the same view again. These files never enter the shared-media cache.

The bundle identifier (`dev.instadm.mac`), Keychain service and data directory are stable application identities. The Gramline display name does not change them or require another sign-in.

Media downloads accept only supported HTTPS Instagram/Meta CDN addresses and do not receive account cookies or authorization headers. Signing out removes the Keychain session and clears disposable media caches. It retains local history and sent attachment copies for your next sign-in.

Login diagnostics contain allowlisted stage, reason and status fields. They do not retain passwords, cookies, request bodies or raw server responses.

## Development and verification

```sh
./script/build_and_run.sh --build-only
./script/test.sh
```

The test script runs Go tests with the race detector, Swift tests and a smoke test against the packaged helper. It covers session and pipe behavior, interrupted synchronization, uncertain sends, message deduplication, unread counts, attachment staging, post resolution, theme persistence, media restrictions and cache limits. Swift file-type tests require normal macOS Launch Services access.

Real-account checks include OTP login, session restoration, inbox loading and shared Reel playback. The user also confirmed outgoing photo/file delivery and photo/album opening. Newer behavior and remaining verification gaps are recorded separately; passing local tests is not a public-release qualification.

- [Architecture](docs/architecture.md)
- [Pipe protocol](docs/protocol.md)
- [Local verification record](docs/verification.md)
- [Logo source and generation prompt](Resources/Brand/README.md)
- [Third-party notices](Resources/ThirdParty/NOTICE.md)

## Dependencies and attribution

The bundled Go helper links [Mautrix Meta](https://github.com/mautrix/meta), distributed under **AGPL-3.0-or-later with the included exceptions**. Its source, license and exceptions are retained in this repository, and notices are included in the app bundle. Exact dependency versions are recorded in `core/go.mod` and `core/go.sum`.

Instagram and Meta are trademarks of their respective owners. Gramline is not affiliated with, endorsed by or sponsored by Meta.
