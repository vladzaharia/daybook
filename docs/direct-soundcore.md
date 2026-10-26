# Direct Soundcore Work integration

Daybook connects to the Soundcore Work (D3200) directly over Bluetooth LE. This is the primary,
recommended way to bring its recordings in; the Soundcore app's export folder is the fallback that
works with every firmware. Both are methods of one device in the device framework
([devices](devices.md)).

The integration is original Swift code using CoreBluetooth's standard GATT API. It is not an
Anker SDK, an MFi accessory protocol, or a claim of compatibility with every firmware. Protocol
facts come from [tacshi/Soundcore's published protocol notes](https://github.com/tacshi/Soundcore/blob/main/PROTOCOL.md)
and its observed audio framing; no code from that repository was copied or linked. Those notes
derive from an Android integration and are not an official contract.

**Physical-hardware validation is still pending.** Everything below is verified against a
simulated recorder built from the same protocol notes, not yet against a real D3200 on current
firmware. See [validation](validation.md).

## Layers

| Layer | Type | Responsibility |
| --- | --- | --- |
| Transport | `SoundcoreTransport` / `CoreBluetoothSoundcoreTransport` | Radio state, scan, `retrievePeripherals`, connect, service and characteristic discovery, notifications, chunked writes with flow control and command spacing |
| Protocol | `SoundcoreSession` | One exchange at a time, each with a timeout; status, the paged recording list, the key exchange, transfers, Listen Live, record control |
| Connection | `SoundcoreConnection: DeviceConnection` | The state machine: setup search, remembered recorder, reconnect with backoff, radio and permission changes, idle release, automatic import, Device Details |
| Parsing | `SoundcorePacket`, `SoundcorePacketBuffer`, `SoundcoreDeviceInfo`, `SoundcoreRecording`, `SoundcoreAudioSlice` | Bounds-checked; malformed input throws, never traps |
| Audio | `SoundcoreCrypto`, `SoundcoreFileKey`, `SoundcoreOpusDecoder` | Ephemeral P-256 key agreement, HKDF-SHA256, AES-CTR file keys and slices, native Opus to 16 kHz WAV |
| Simulation | `SimulatedSoundcore`, `SimulatedSoundcoreTransport` (debug builds) | A recorder that speaks the protocol from generated fixtures, with fault injection |

## The connection

```text
idle ──search()──▶ waitingForRadio(discover) ──radio on──▶ searching ──found──▶ (list)
idle ──connect()─▶ waitingForRadio(reconnect) ─▶ connecting(remembered) ──ready──▶ opening ──status──▶ connected
                                                 └─ not known or timed out ─▶ searching(target) ─▶ connecting
connected ──unexpected drop──▶ backingOff(1…5) ──▶ connecting … ──▶ connected (or idle / waiting in range)
idle ──automatic import──▶ waitingInRange (a pending connection with no deadline) ──in range──▶ connected
any ──radio off / denied / unsupported──▶ unavailable ──radio on──▶ the deferred intent, or automatic
connected ──idle──▶ released (idle) ──cooldown──▶ waitingInRange
```

- **No surprise permission prompts.** No Bluetooth manager is created at launch unless a
  recorder is already remembered and automatic import is on (so permission was granted). Setup's
  Continue… card is the pre-permission screen; its one button starts the search.
- **Remembered recorder.** After the first connection Daybook remembers the recorder's
  identifier and last status. Connect and Reconnect go through `retrievePeripherals`
  (10 seconds), then fall back to a 15-second scan for that recorder.
- **Connected means confirmed.** The link counts as connected only once the recorder answers a
  status request, so a device that doesn't speak the protocol is reported as "didn't accept the
  connection" rather than shown as connected.
- **Reconnect with backoff.** An unexpected disconnect retries after 2, 5, 15, 30, and 60
  seconds. With automatic import on, it then waits in range quietly.
- **Bluetooth changes.** Bluetooth turning off, being denied, or being unsupported each have a
  problem with one action. If the recorder was connected, it reconnects when Bluetooth returns.
- **Timeouts.** Commands 10 s, setup connect 20 s, remembered connect 10 s, scan 15 s, record
  confirmation 10 s, stalled transfer 45 s. All live in `SoundcoreTiming`.
- **Letting go.** A connection made for automatic import is released 30 seconds after its
  imports finish, and the next automatic attempt waits 15 minutes. A connection the person made
  is released after 5 idle minutes (or when they disconnect). The recorder talks to one host at
  a time, so holding it would block the phone app. On iPhone the wait is kept on the wall clock
  (`automaticDueAt`) and background app refresh resumes it, since a suspended app runs no timers.
- **After letting go.** A recording the recorder was making stays "Recording · as of 10:07 AM" for
  20 minutes (`lastKnownRecording`), then is unknown: `recordingState` ([devices](devices.md#what-the-recorder-is-recording)).

## Importing

- The session's queue runs one transfer at a time (Waiting, Stop current, Stop all). The Mac is
  kept from idle-sleeping while it transfers.
- Nothing transfers from the remembered list: imports wait until the recorder has been listed on
  this connection (`isInventoryCurrent`). The recording it names as active (after the list's
  entries) is in progress whether or not its status says it's recording, kept in the snapshot
  across disconnects, and never imported until it's finished. Whether firmware lists the growing
  file among the entries, and whether Pause keeps it open, is unverified; both are handled.
- A transfer is accepted only when: the file key unwraps to the expected prefix for that
  recording ID; every slice arrives in sequence (an exact repeat of the last slice is ignored;
  a gap or conflict fails); the byte count matches the size the recorder reported; and the
  audio decodes to a non-empty, finite WAV. Anything else removes the partial file and throws.
  The staged WAV is deleted once the library has copied it, and what a killed run left staged is
  removed at the next launch.
- **Disconnect mid-transfer:** nothing partial is saved; the recording goes back to the front of
  the queue, which waits and resumes after the reconnect.
- **Retry policy:** a stall or integrity failure gets one quiet retry, then shows "This
  recording couldn't be imported" with Try Again. A disconnect isn't counted as an attempt.
- Stopping or failing asks the recorder to stop sending (`1A 11`), then waits a moment so stray
  packets can't reach the next transfer.
- **Automatic import** is on by default and imports only recordings that started after the
  recorder was added, then lets the recorder go. See [devices](devices.md#automatic-import-the-default-and-why).

### Limits of the integrity checks

The protocol has no per-slice message authentication code, and macOS's Opus decoder conceals
malformed packets rather than reporting them. So audio corrupted inside an otherwise complete,
in-order transfer of the right size can't be detected; the checks above catch loss, reordering,
truncation, mismatched keys, and size mismatches.

The firmware handshake sends the raw ECDH shared secret in its reply. Anyone who can read that
characteristic traffic can derive the session key using the public HKDF parameters, unwrap the
file keys, and decrypt the audio. It also does not authenticate the recorder's identity. Privacy
therefore depends on independently verified BLE link encryption and pairing; the app has not
established those properties on physical hardware. This must not be described as secure or
authenticated end-to-end encryption. Replacing the handshake unilaterally would break firmware
compatibility. Keys stay in memory and are replaced on every connection.

There is also an unresolved packet-boundary problem: the current decoder strips trailing zero
bytes from each 160-byte slot. Valid Opus packets can end in zero, so this can silently alter audio.
Simply passing all 160 bytes to the codec also changes decoded audio when the sender appended
unframed zeros. The missing length cannot be inferred reliably from those bytes. Native-codec
probes confirmed both failures; properly signaled RFC 6716 padding preserves the samples, but
that does not establish what physical firmware sends. Direct audio remains experimental until
real captures establish packet framing. Keep recorder originals and use file export for important
recordings; neither simulator success nor successful decoding establishes audio fidelity.

## Listen Live and record control

- Listen Live reads the recording in progress, saves it to this Mac as it arrives, and captions it
  live on the shared DaybookCaptions engine, packet by packet (docs/devices.md, "Listen Live
  captions"). Stop Listening keeps what arrived as a conversation; a disconnect keeps it too.
  The portion is stored with the recording ID plus `~live`, and the full recording joins that
  conversation when it's imported later. It never stops the device's recording.
- Start and Pause are sent only when the person chooses them. The state changes only when the
  recorder reports it; after 10 seconds without confirmation the page says so.
- The recorder's own button reports the new state unasked (`18 82`, per the protocol notes); either
  way, Daybook lists it again, so a new recording appears in progress and a finished one with its
  final size.

## The recorder's clock

Recording IDs are Unix start times by the recorder's own clock, which nothing keeps right. When the
recorder confirms a Start Daybook sent, the new recording's ID against the send time is its offset
(`SoundcoreClock`; a resume of a recording kept open isn't a measurement). It's kept with the
remembered recorder, per serial, and in `SoundcoreClocks` for the importers. Offsets beyond the
measurement's two-second resolution are taken off every start date: the list, Recording now, the
status, and a new conversation's date and title (`DeviceRecordingStart`). Device Details'
technical rows say "In step", or "5 min ahead" past a minute. The offset isn't yet written into the
imported track's provenance.

## What it never does

No delete, reset, bind or unbind, firmware update, Wi-Fi SoftAP, Classic SPP, or vendor
account call. The simulator tests assert that only status, list, key exchange, transfer, stop
transport, and (when asked) record control commands are ever sent.

## Verification

`SoundcoreProtocolTests` cover command bytes, fragmented and corrupted frame recovery,
battery and storage decoding, both list layouts, slice bounds, malformed lists, a 2,000-round
fuzz of every parser, the NIST AES-256-CTR vector, P-256/HKDF/file-key agreement with tampering,
and the native Opus path.

`SoundcoreSimulatorTests` run the real connection, session, queue, and importer against the
simulated recorder: setup and remembered reconnection (direct and after a scan), paged listing
with the 8-byte fallback, imports with identity, one-at-a-time queues, integrity failures (gaps,
wrong sizes) with one retry, stalls, Try Again, Stop, disconnect mid-transfer with resume after
the reconnect, Bluetooth off mid-import, Bluetooth off and denied at setup, idle release,
automatic import since setup and its release, no automatic import before the library loads,
record control with and without confirmation, Listen Live portions, and the read-only command
set. The simulator also has firmware variants that list the active file and keep a paused one
open, a button press, and a skewed clock, for: no import from a remembered list on reconnect, a
paused-open recording neither imported nor queued, listing again on the button's start and stop,
the last-known recording as of its time and its expiry, the clock measured on Start and applied to
start dates, a recording arriving through sync during its transfer, and a background wake after
the cooldown. No microphone, real Bluetooth, or downloads are used.

**Not yet verified on hardware:** discovery and permissions on current firmware, actual battery
and storage values, the active recording's place in the list (among the entries or only after
them) and whether Pause keeps it open, whether the button reports `18 82`, how far real recorder
clocks drift, transfer throughput and packet loss, reconnect timing, live reception, and automatic
import alongside the phone app.
