# InstaDM identity

`InstaDM.png` is the original generated, transparent raster master. The mark combines a folded ribbon, a speech bubble and a forward gesture on an indigo/violet tile. It is an independent identity, not an Instagram or Meta logo.

Created with the built-in image generation tool on 2026-11-06. No CLI/API-key workflow was used. `script/build_icon.sh` preserves transparency and exports standard 16–1024 pixel macOS icon representations into `.build/InstaDM.icns`; the app build packages that file and the master PNG. Login and the Dock use the same identity.

## Generation prompt

Use case: logo-brand. Create one finished macOS app icon for InstaDM, an independent, elegant Instagram direct-message client. The app currently uses midnight blue and violet chat themes. Design a distinctive, exceptionally simple folded ribbon/speech-bubble symbol with a subtle forward/send gesture: one bold recognizable white/lavender mark, not the Instagram camera or Telegram paper plane. Premium native macOS design, softened geometric edges, very subtle depth, restrained violet-to-indigo luminous squircle tile, strong silhouette readable at 32 pixels. Centered front-facing, no perspective, no mockup. Square 1024x1024 asset. The rounded-square tile occupies about 85% of the canvas with normal macOS icon padding. Transparent outside the tile, a small clean soft shadow, crisp edges. No text, no letters, no wordmark, no extra objects, no photographic textures. This is the actual shipped Dock icon, not a presentation.

The tool returned a 1254 × 1254 RGBA master. Icon packaging resamples it without changing the artwork.
