# Maintained upstream source

`mautrix-meta` is a source snapshot of `go.mau.fi/mautrix-meta` at commit `a3afe226a33ad086f5b6b1a559c9ece7e69b213b`, module version `v0.2610.1-0.20261105141638-a3afe226a33a`. Its original license and exceptions are retained. The root Go module uses a local replacement so normal Go builds, tests, and packaging all compile the same source without modifying the Go module cache.

## Downstream changes

- `pkg/instameow/native_api.go`: expose native API headers and response-header rotation using the existing Android login profile and device. Gramline's own native-media adapter owns the disappearing-media protocol; the dependency extension does not add another login flow or change the HTTP retry policy.

- `pkg/instameow/slidetypes/thread.go` and `theme.go`: decode `theme_data` from the existing thread-detail query when its chat-theme provider is enabled. The typed fields were checked against an authenticated response: normal/dark palettes, ARGB bubble/navigation/composer colors, and 480/1024-pixel background assets. No alternate network endpoint or theme mutation is introduced.
- `pkg/messagix/httpclient/mercury.go`: reject an empty upload metadata array with an error instead of indexing it and crashing the helper. The upload regression test runs in `script/test.sh`.
- `pkg/messagix/bloks/interp.go`: implement `bk.action.array.Slice`, which Instagram returned during real-account MFA selection. The operation takes an array, offset, and length. A null length selects the remainder; a positive length is clamped to the remaining items. Invalid offsets and negative lengths return null. This is offset-and-length behavior, not JavaScript's start-and-end behavior.
- `pkg/messagix/bloks/interp.go`: implement `bk.action.array.Concat`, reached after fixing slicing. It concatenates two arrays into independent storage. This contract was checked against the [Android Bloks dispatcher](https://github.com/Meghdut-Mandal/com.whatsapp_2.24.6.77/blob/HEAD/sources/X/C142316og.java).
- `pkg/messagix/bloks/diagnostic.go`: report a bounded inventory of function identifiers when an operation is unsupported. The inventory traverses parsed code nodes only, excluding literal values, variable names, argument contents, and raw response bodies.
- `pkg/messagix/bloks/timer.go`, `interp.go`, `selenium.go`, `selenium_platform.go`, and the developer CLI adapter: replace fixed timer-name handling with a serial queue for named one-shot and repeating login timers. Preserve the repeat flag and callback arguments, support replacement and idempotent cancellation, and bind approval visibility callbacks to their component. Callback arguments, repeat scheduling and cancellation were checked against the Android dispatcher and [timer runnable](https://github.com/Meghdut-Mandal/com.whatsapp_2.24.6.77/blob/HEAD/sources/X/C1497572q.java). No interpreter callback runs concurrently with another login step.

The contract was checked against two independently recovered versions of Instagram's Android implementation: [AbstractC553450LoO.java](https://github.com/akitaonrails/instagram-analysis/blob/HEAD/decompiled/java/X/AbstractC553450LoO.java) and [C48278Ebx.java](https://github.com/carter-0/instagram-decompiled/blob/HEAD/sources/X/C48278Ebx.java). No decompiled implementation is copied into this repository.

Regression cases live in `core/internal/instagram/bloks_test.go` and run against this actual dependency through `script/test.sh`. When updating upstream, retain or reconcile these changes and run the regression suite before replacing the snapshot.
