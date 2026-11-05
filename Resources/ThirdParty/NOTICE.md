# Third-party notices

The bundled `insta-core` executable links `go.mau.fi/mautrix-meta` and its dependencies. The pinned upstream revision is `a3afe226a33ad086f5b6b1a559c9ece7e69b213b`. Mautrix Meta is distributed under AGPL-3.0-or-later with the exceptions included alongside its license. The upstream source is available at https://github.com/mautrix/meta.

Dependency versions and checksums are recorded in `core/go.mod` and `core/go.sum`. This app uses Apple's SwiftUI, AppKit, Security and UserNotifications frameworks, and the system SQLite library.

The application source includes the maintained Mautrix Meta snapshot under `third_party/mautrix-meta`. It adds Bloks array operations and named approval timers needed by Instagram verification responses, diagnostics restricted to code identifiers, an empty-upload-metadata guard, and typed decoding of Instagram thread appearance data. These modifications are documented in `third_party/README.md`.
