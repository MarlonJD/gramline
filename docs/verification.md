# Local verification

Date: 2026-11-06. Status: local development build; real-account OTP login, inbox loading, saved-session restoration and shared Reel playback verified. Photo/album opening is user-confirmed. Real conversation traffic is visible; offline-gap recovery remains unverified against the account.

## Verified locally

- Built the SwiftPM executable and bundled Go helper on Apple Silicon with Swift 6.4.2 and Go 1.27.1.
- Ad hoc signed and verified `dist/Gramline.app`, then launched it on macOS.
- Inspected the native sign-in window and settings. No browser profile is used for authentication.
- Passed 47 application Go test functions with the race detector, including direct photo/video normalization, unavailable album positions, restricted-media URL suppression, identity-based media refresh, avatar selection, normal/dark theme decoding, live viewer-only read receipts and mark-read events, shared-post parsing, mixed-carousel ordering, selected-child resolution, unavailable/authenticated media handling, attachment upload/commit separation, multipart filename validation, file-size guards, recovery pagination, interrupted synchronization, sending during background synchronization, viewer read-receipt normalization, uncertain sends, persistence acknowledgements, pipe EOF, diagnostic redaction, approval timers and array operations. The directly used Bloks and HTTP client package tests also passed.
- Passed 29 Swift tests covering theme persistence/default reset, direct-media persistence and restricted viewing modes, badge labels at zero/one/four/five, empty threads, old unread messages, receipt/deletion clearing, message grouping across sender changes/time gaps/midnight, shared-post persistence and history enrichment, media URL restrictions, cache deduplication, budget/age eviction and oversize rejection, attachment staging after original-file removal, persisted attachment drafts, attachment reconciliation after server echoes, database isolation, interrupted sends, synchronization/read watermarks, unread-message deduplication, framing, integer precision and message identifiers.
- Passed the packaged-helper smoke test: handshake, empty-session restore, authentication guards, protocol version rejection, shutdown and parent EOF.
- Verified a credential-free Instagram preflight after updating the upstream pin. It reached `fi.mau.meta.instagram.caa.email_password`.
- Exercised the production composer in an isolated local preview with no network client. Return submitted once, Shift+Return inserted newlines, the field grew to three lines, a fourth line scrolled within the same height, and submission cleared the draft back to one line.
- Relaunched the packaged application, observed `Connected`, and verified that Settings showed banner/sound alerts off. The temporary composer preview process was closed.
- Exercised the production attachment composer and pasteboard reader in a separate local preview without a network client: pasted a TIFF bitmap and observed a PNG thumbnail, pasted a copied PDF file and observed its file card, pasted plain text, submitted the two attachments through the local send callback, and checked that four text lines scroll within a three-line viewport. The preview preserved and restored the previous clipboard when quitting.
- Rebuilt and launched the packaged attachment-enabled app; observed its paperclip, native text editor and connected synchronization state. The user pasted and sent a photo, then explicitly confirmed that it appeared in Instagram on their phone. The user separately tested a general file and confirmed that it was sent and visible in Instagram. The exact type of that successful file was not specified, so this does not establish support for every file format.
- Opened an existing conversation and observed structured post/Reel cards with creator, caption and direct links. Resolved and downloaded a real shared Reel using the saved account. The final native player displayed play/pause, volume, timeline and duration controls, with playback advancing to approximately three seconds of a fifteen-second video. The user separately confirmed that a photo/album opens. The user response did not distinguish single-photo from multi-item album testing; carousel selection and ordering are additionally covered by the local fixtures.


- Observed compact message grouping in the running app: consecutive messages no longer repeat a timestamp beneath every bubble. The Dock label mapping is covered by tests; the rendered Dock badge itself was not independently inspected.
- Observed actual profile photos in the sidebar, conversation header and account footer. Opened a conversation with a real Instagram wallpaper and verified its image, bubble colors and header/composer colors. A second theme was then verified with matching toolbar, sidebar, account footer, search surface and selected-row colors across the window. These are local rendering changes; no Instagram theme mutation was sent.
- Verified the native media adapter with the signed-in account: Slide GraphQL returned null Raven attachments, while the native thread endpoint returned both media URLs with zero views. The user opened both a view-once photo and a replayable photo in the app and confirmed both displayed. A fresh native response reported one view for each. After the user reported that opening the replayable card a second time failed, replay moved into the same viewer: the first successful receipt can grant a second explicit token, and the temporary file remains only until that viewer closes. The second receipt and video playback still require real-account verification. Fixtures cover viewing counts, exact message identity, replay eligibility without another URL, expiry, no automatic receipt retries, durable uncertain-view reservations and state preservation across history refresh.
- Renamed the Swift executable, app bundle, menus, UI and documentation to Gramline. Generated the new transparent G/speech-bubble icon and packaged all standard macOS icon sizes. The About panel displayed the correct Gramline name and new icon. The same account and history restored using the stable application identity. No browser profile or extra test GUI process was used.
- Removed the persistent shortcut explanation beneath the composer. Verified the running Gramline conversation contained the editor, attachment and send controls without that footer. Attachment progress, offline status and the near-limit character count remain contextual.

The first SwiftUI `VideoPlayer` implementation crashed during `_AVKit_SwiftUI` superclass metadata initialization on the local macOS runtime. It was replaced by a narrow `AVPlayerView` representable. A second crash report came from the older executable UUID that had reopened before the replacement build. The rebuilt native-view version subsequently played the real Reel. No old player path remains. The pause-control automation timed out; this is not recorded as an independently verified interaction.

The first isolated Swift attachment test run could not query the macOS type registry under the process sandbox. Running the same suite with normal Launch Services access passed. This does not require changing the application's permissions or sandbox settings.

## Real-account observations

The initial upstream release returned HTTP 404 during device setup. The pinned upstream revision replaces the obsolete setup endpoint and progressed to MFA method selection. The user reported that selecting device approval sent a notification to their phone, while Gramline reported `verification/unsupported_response`. WhatsApp and other offered methods also produced that generic error.

The application now preserves the login context between verification steps, automatically polls approval steps, and classifies more upstream response failures without retaining raw errors. A subsequent real-account attempt identified the precise unsupported operation: `bk.action.array.Slice`. That failure was reproduced offline before adding the operation to the maintained dependency source. Tests cover offset-and-length semantics, null length, clamping and invalid bounds.

The next attempt progressed to another unsupported operation, `bk.action.array.Concat`. The user also reported that the phone notification opened an unavailable request; this does not establish why Instagram invalidated it. Concatenation is now implemented and tested together with slicing. Additional diagnostics collect only parsed function identifiers to identify further interpreter gaps without retaining response values.

The next attempt reached `verification/unsupported_timer`. The dependency's fixed timer-name allowlist has been replaced by a serial scheduler that preserves native repeat flags and callback arguments. A synthetic approval page now exercises slicing, concatenation, page visibility, timer registration, display-and-wait, and the final approval transition together. This local fixture alone is not evidence of a successful Instagram account session.

After the timer update, the user successfully completed login with an OTP code. The application displayed the authenticated account, real conversations, and a connected/synchronizing state. The user explicitly confirmed that this was OTP login. Device-notification approval has not been verified successfully and must not be inferred from the OTP result.

The first real mailbox exposed excessive initial fetching: the application requested history for every old conversation and held sending until that work finished. Initial synchronization now uses mailbox snapshots, defers full history until opening a conversation, and skips unchanged watermarks on subsequent synchronization. Recovery of newer messages still paginates to the saved baseline.

A normal quit and reopen restored the account and inbox without requesting a password or OTP. The app reached `Connected` after synchronization. The next send attempt exposed a remaining UI block during inbox synchronization; sync now runs independently of command dispatch, and a blocked-mailbox test confirms that sending still completes.

The user's subsequent screenshot showed outgoing messages marked `Sent` and incoming replies in the same conversation. The later running application also showed real incoming and outgoing traffic. This is application-side evidence; delivery on the recipient's phone was not separately observed by the agent.

The original unread badge appended `+` to every positive count. Investigation of the reported persistent badge found four much older conversations with incoming messages after their read watermarks. The user explicitly requested keeping historical unread messages in the count. The revised badge is hidden at zero, displays `1`–`4`, and shows `4+` only above four. It no longer invents one unread message for an empty thread. Read/reopen/stale-snapshot, receipt/deletion and label-boundary scenarios passed automated tests. Viewer read receipts and mark-read events now update the count immediately. The macOS Dock accessibility surface previously timed out during visual inspection, so the rendered Dock badge itself has not been visually verified. The live application's quiet alert setting was verified through its Settings UI.

## Not yet verified

- Every shared-media variant, expired-link recovery against a real expired CDN URL, and full-screen playback. Link refresh and unavailable-content behavior are implemented; account-specific restrictions can still prevent access.
- Acceptance of every file type or account-specific upload restriction. Photo and general-file delivery are user-confirmed on Instagram.
- Independent recipient-device confirmation of delivery.
- Visual inspection of the rendered Dock badge.
- Recovery of messages missed during a real network interruption.
- Physical notification interaction and wake recovery with an authenticated account.
- Successful login using approval on another device.
- Developer ID signing, notarization or release distribution.

A broad upstream developer-CLI test sweep from the application module stopped on missing checksum entries for unrelated Messenger dependencies. The application modules and directly used Bloks package were subsequently tested successfully. The upstream developer CLI is not packaged in Gramline.

Passing local tests does not establish that every Instagram account challenge is supported. Real-account failures are tracked separately from the local test result.
