# Direct Soundcore Work integration

Daybook includes an experimental, original native Swift integration for the Soundcore Work / D3200. It uses CoreBluetooth's standard BLE GATT API. It is not an Anker SDK integration, an MFi certification, or a claim of universal firmware compatibility.

The protocol facts were researched from [tacshi/Soundcore's published protocol notes](https://github.com/tacshi/Soundcore/blob/main/PROTOCOL.md) and its documented observed audio framing. No application code from that repository was copied or linked. Its notes derive from a Feishu/Anker Android integration and are not an official protocol contract. Details may differ on the user's hardware.

## Available behavior

- Scan for the documented D3200 BLE advertisement, select a device, connect, and disconnect. The Bluetooth manager is created only after Scan; constructing Daybook or opening preferences does not scan or request permission.
- Read microphone/case battery buckets, charging state, firmware, storage, and recording status. Battery values 0–9 map to 10–100%; higher valid percentages remain literal.
- Explicit buttons request device start or pause. Device recording never starts because the app launches, connects, or tests run.
- List paginated offline recordings, then request an individual audio import. The app establishes an ephemeral P-256 session, validates the reported shared secret, derives a session key using HKDF-SHA256, and unwraps the file key with AES-CTR. Per-slice AES-CTR uses the documented sequence-derived counter.
- Reassemble fragmented notifications and validate frame length and checksum before parsing. Reject malformed payloads, sequence gaps, conflicting duplicates, failed key verification, unsupported layouts, and incomplete byte counts. Exact repeated last slices are ignored.
- Decode the documented padded 160-byte Opus packets through macOS's native `AVAudioConverter`, writing a 16 kHz mono WAV in `~/Library/Application Support/Daybook/SoundcoreImports`. Only a completed, validated WAV is passed to `onRecordingReady` for normal library import and local processing. Rejected/aborted partial files are removed; original device recordings are retained.
- Explicit live reception requests the current recording ID from device inventory and sends the documented realtime transport flag. It receives and decrypts contiguous audio, saves a local WAV, and can send bounded 15-second PCM windows to an application-provided local ASR callback. A separate inference runtime keeps provisional previews from interrupting final processing. A slow preview may skip windows while the full recording continues to be saved. Stop Reception saves the captured portion; it does not stop recording on the device. Received live portions cannot be verified against a final whole-file byte count, so they are distinct from complete offline exports.

Daybook does not automatically bind/unbind the device, reset it, delete device files, update firmware, join a SoftAP, use Classic SPP, or call Anker/Feishu authentication endpoints. Firmware requiring an unavailable binding/license step fails with an error. The existing official-export import path remains usable. Highlights are not synthesized from undocumented packet bits.

## Protocol boundary and security

The command service is `020cf5da-0000-1000-8000-00805f9b34fb`, with write characteristic `7777` and notification characteristic `8888` in the standard Bluetooth base UUID. Writes respect the negotiated maximum size, response/flow-control capabilities, and command spacing. Incoming frames use the documented 16-bit length and additive checksum. Parsing buffers are bounded.

The key-agreement check confirms consistency with the received peer key; it does **not** authenticate a manufacturer identity. The reverse-engineered exchange includes a raw shared-secret check value, so it should not be described as audited, end-to-end authenticated transport encryption. Keys remain in memory, are never logged, and are replaced on disconnect. A verified file-key prefix is required; the app never falls back to importing undeciphered bytes as audio.

Audio framing is based on observed 20 ms Opus packets with trailing zero padding. Native codec tests verify this path using generated packets. They do not prove that all firmware variants use identical framing or that trailing zero removal is unambiguous on every possible device packet. Decode errors fail the transfer; do not weaken those checks to make a differing firmware appear supported.

## Integration API

```swift
let soundcore = SoundcoreController() // lazy Bluetooth; no scan
soundcore.onRecordingReady = { localWAV in
    // Import the validated file through normal meeting/source persistence.
}
soundcore.transcribeLiveAudio = { temporaryWAV in
    // Call the separate local preview runtime with an already-installed model.
    // Return text; do not keep this temporary file (removed after callback).
}
SoundcoreView(controller: soundcore)
```

The signed app needs `NSBluetoothAlwaysUsageDescription`. Permission and radio errors are surfaced in the view. Disconnection cancels queued writes and pending transfers. The app does not silently reconnect or restart capture.

## Verification and remaining work

Six tests passed on October 23, 2026: exact known command bytes plus corrupted/fragmented recovery; battery/storage decoding; inventory/slice bounds; the NIST AES-256-CTR vector; real P-256/HKDF/file-key agreement and mismatch rejection; and a generated native Opus encoder → fixed packet padding → native decoder → WAV round trip with duration/energy checks. No microphone, Bluetooth discovery, or physical device recording was used in tests. The live path uses the same tested parser, cryptography, and decoder and compiled successfully with the application.

Physical discovery, current firmware permissions, actual battery values, encrypted file sizes, packet loss behavior, realtime reception, and live transcript quality have **not** been validated against the user's Soundcore device. An end-to-end device session is still required before calling this integration production verified. MFi/iAP2, firmware-specific pairing, Wi-Fi bulk export, hardware highlight semantics, and firmware maintenance remain unsupported. These limits are intentional and visible; they are not simulated successful features.
