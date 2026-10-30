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
| Wi‑Fi Fast Transfer | `SoundcoreFastTransfer`, `SoundcoreWebSocket`, `SoundcoreWiFi`, `SoundcoreHotspot` (`SystemSoundcoreHotspot` on iPhone) | The recorder's access point, its WebSocket over TLS, the keep-alive, and falling back to Bluetooth |
| Simulation | `SimulatedSoundcore`, `SimulatedSoundcoreTransport`, `SimulatedSoundcoreAccessPoint`, `SimulatedSoundcoreHotspot` (debug builds) | A recorder that speaks the protocol from generated fixtures, with fault injection, and its access point on loopback |

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
- **Holding the link** (iPhone, for its button; docs/devices.md, "Holding the recorder's link"):
  `staysConnected` never lets the recorder go when idle, reconnects with a pending connection at once
  after a drop, never scans (only the system's record of it, tried again after 30 s), and stands
  aside for the person's Disconnect. A peripheral iOS restored with its link still up is adopted from
  service discovery.
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
  file among the entries, and whether Pause keeps it open, is unverified; both are handled. The
  protocol notes call that field `currTransportFileTimestamp`, so it may instead name a file being
  transferred (to the Soundcore app, say); Device Details shows what it names ("Named in progress").
- **A list that doesn't come.** When the recorder doesn't answer the list request (10 s) or refuses
  both layouts, the device says so ("Soundcore didn't list its recordings", with Refresh Status),
  `DeviceSession.listingState` is `.notListed` rather than current, so nothing reads as "nothing
  new", and it's tried again quietly after 15 and 60 s (`SoundcoreTiming.relist`) while the link is
  up. A refusal of both layouts doesn't switch the connection to the 8-byte layout. Status and the
  list are read separately, so a status that doesn't arrive doesn't stop the list.
- **Another app on the same iPhone.** iOS shares one link to the recorder between apps, so while the
  Soundcore app lists or transfers, its replies and audio reach Daybook too, and a reply to its list
  request can satisfy Daybook's. Daybook ignores audio it didn't ask for and counts it, and replies
  that matched nothing, in Device Details ("Audio packets not requested here", "Replies not
  requested here"); a large count means the Soundcore app was transferring.
- **Two apps on one link.** While audio Daybook didn't ask for is arriving, Daybook holds its own
  transfers, Listen Live, and Start and Pause until that audio has stopped for three seconds
  (`SoundcoreTiming.otherAppQuiet`), because a request sent over another app's transfer could end it.
  Listing and status don't wait. Meanwhile the device page's line and the status line say "Waiting for
  the Soundcore app to finish" (`DeviceSession.otherAppWait`; Device Details: "Another app"). Daybook
  never asks the recorder to stop sending (`1A 11`) while the other app's audio is arriving. When the
  other app's request cuts off a transfer of Daybook's (its file head arrives, or its audio arrives
  before Daybook's head), Daybook's keeps nothing and starts again from the beginning once the other
  transfer is done; that isn't a failure or a retry attempt. Daybook's own stragglers, within the
  settle time after it stopped a transfer, aren't taken for another app's. The recorder keeps one audio
  key, so another app's key exchange (an unrequested `2E 01` reply) makes Daybook exchange keys again
  before its next transfer.
- **Details.** Device Details' technical rows include the last list (how many, pages, when, or why
  it failed) and what the recorder names as in progress. On iPhone, the device page's Details lists
  every recording on the recorder with why it is or isn't new (`DeviceSession.standings`: New, In
  Daybook, Recording now, Importing, Arriving from another device), and Copy puts it all, with the
  app's version, on the clipboard (`DeviceSession.diagnostics`). Listing outcomes are also logged
  (`local.daybook.devices`, category `Soundcore`).
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
  final size. A pushed state that changes what Daybook knew while no command of its own is waiting is
  the button (`onButton`); live audio being received then is kept after a moment if the stream doesn't
  end on its own (`SoundcoreTiming.liveTail`, 2 s).
- Live audio that goes quiet for the stall timeout (45 s) keeps what arrived, as a disconnect does,
  rather than being discarded.

### Live audio for a shared recording

The device managing the recorder saves its audio into a shared recording as it records, from Listen
Live's stream (docs/multipoint.md, "A recorder's audio while it records"). Measured against
`SimulatedSoundcore` recording in real time (`recordsInRealTime`: a recording grows by three 20 ms Opus
frames every 60 ms, live audio streams it from its first frame and ends with it;
`SoundcoreSharedRecordingTests.testWhatLiveAudioCostsTheLinkAndHowSoonItsThere`):

| | Measured |
| --- | --- |
| On the link | about 8,000 bytes a second (64 kbit/s): 166-byte slices (160 of Opus) and 10 bytes of framing a notification of three, 16.7 notifications a second, before Bluetooth's own overhead |
| Keeping up | the stream ran with the recording throughout (the shown seconds trail by up to a second, as progress is published once a second) |
| In the library after the recording stops | about 80 ms (the decoder finishing and the copy), the whole recording |
| The same recording's file afterwards | byte for byte the live audio when the stream ran to the recording's end, so one track |

An hour of audio is 28.8 MB of Opus; transferred afterwards at a sustained 20 to 40 KB/s over
Bluetooth LE (what the iPhone and the recorder actually sustain is unmeasured), that's 12 to 24 minutes
before multipoint processing could start, against moments with live audio. Live audio needs about
64 kbit/s sustained for the whole recording, well inside what a Bluetooth LE link carries, but the
recorder's real packet size, how it paces live audio, what the radio sustains next to the phone's
other Bluetooth traffic, and what it costs the recorder's battery need a real recorder.

While live audio streams, the protocol session runs one exchange at a time, so the recorder's list
can't be read nor Pause sent: a device stopping the recorder ends the live audio first (its tail,
until the Pause, is then only in the recorder's file, which replaces the live portion). Whether
firmware accepts commands during a live stream is unverified; Daybook doesn't try.

## Wi‑Fi Fast Transfer (iPhone)

A long recording comes over the recorder's own Wi‑Fi rather than Bluetooth LE: in the official app's
words, Fast Transfer. Only on iPhone, only with Daybook in the foreground, for recordings at least ten
minutes long (`SoundcoreTiming.fastTransferMinimum`) while the recorder page's "Fast Transfer for Long
Recordings" is on (the default, `ConfiguredDevice.fastTransferForLongRecordings`), or for any recording
the person picks "Import over Wi‑Fi" for (a new recording's menu). Never during Listen Live or another
app's transfer. The Mac has no hotspot (`SoundcoreWiFiHooks.hotspot` is nil), so it never uses it.

**Unverified on hardware.** The flow is built from community reverse-engineering of the Anker SDK:
[tacshi/Soundcore's PROTOCOL.md](https://github.com/tacshi/Soundcore/blob/main/PROTOCOL.md) §6.4–6.5 and
§9, and its Wi‑Fi export service and `beginWifiExport` (read for reference; no code was copied or run).
It is tested end to end against the simulated recorder only. Until the owner captures a real Fast
Transfer, treat every byte below as a well-informed guess; any failure falls back to Bluetooth.

1. Over Bluetooth, after the usual key exchange (`2E 01`), whose session key the Wi‑Fi transfer reuses:
   `1A 05` with an access point name and password Daybook chooses, `[name length][name][password
   length][password]`. The name is the official app's form, `WiFi-<milliseconds>`; the password is 13
   random digits (the official app uses the milliseconds again, which anyone could guess from the name).
   The recorder answers `1A 05` with its IPv4 address, bytes reversed, and its port, little-endian.
2. Daybook lets Bluetooth go on purpose and waits ten seconds (`accessPointStartup`) for the recorder's
   network to start. The connection stays "Connected" meanwhile, and a Bluetooth drop then isn't a
   disconnect.
3. The iPhone joins the network (`NEHotspotConfiguration`, `joinOnce`: iOS asks the person each time
   and drops the network when Daybook leaves the foreground), and waits for an address on its subnet.
4. `wss://<address>:<port>`, three attempts two seconds apart. Daybook writes the opening handshake
   itself, with the header names, case, and order of the official app's HTTP client (`Upgrade`,
   `Connection`, `Sec-WebSocket-Key`, `Sec-WebSocket-Version`, `Host`, `Accept-Encoding: gzip`, and its
   `User-Agent`), because the recorder's parser may match them exactly. It accepts the recorder's
   self-signed certificate for that connection only. A UDP keep-alive
   (`soundcore-keep-alive-unicast`) goes to port 32003 every two seconds.
5. Each recording is asked for as hex text, `08 EE 00 00 00 1A 07 12 00 | offset | id | 1B` (18 bytes,
   no checksum, the offset always 0), and arrives as the same encrypted `1A 07`/`1A 08`/`1A 0A` frames
   as over Bluetooth, through the same session and the same checks (`SoundcoreSession.Medium.wifi`).
   With another recording queued, the Wi‑Fi link waits for it (`fastTransferLinger`), so a batch shares
   one access point.
6. To finish: `FINISH`, the WebSocket and keep-alive closed, the network forgotten, Bluetooth back, and
   `1A 02` to close the access point. Nothing deletes anything (deleting is `1A 10`, never sent).

**Falling back.** Any failure (the recorder refusing or not answering `1A 05`, the join declined or
failing, the WebSocket not opening or dropping, a slice missing, Daybook leaving the foreground) ends
Fast Transfer, brings Bluetooth back, and the transfer starts again from the beginning over Bluetooth:
nothing partial is kept, and it isn't counted as a failed attempt. An unanswered `1A 05` is followed by
`1A 02` over the link that's still up, in case the recorder opened it anyway. After a failure,
transfers stay on Bluetooth for 30 minutes (`fastTransferPause`); a join iOS fails at once ("internal
error", which is what a build without the Hotspot Configuration entitlement gets) keeps this build on
Bluetooth until the app's build changes or the person turns the preference off and on.

**Recovery.** From `1A 05`'s answer until `1A 02` is sent, the remembered recorder carries
`accessPointSSID` and `accessPointSince`. Whatever ends Fast Transfer (Disconnect, quitting, a crash,
Bluetooth not coming back), the next confirmed Bluetooth link sends `1A 02` before anything else and
clears it. While it's set and the recorder isn't connected, the page says "Fast Transfer didn’t finish"
("The recording is still on your Soundcore. Connect to turn off its Wi‑Fi.") with Connect. Whether the
recorder accepts a Bluetooth connection while its access point is open, and whether it closes the
access point on its own after `FINISH` or a timeout, is unverified.

**What the page says.** The import's line says "Starting Wi‑Fi…" while it sets up and "Over Wi‑Fi. Keep
Daybook open until it finishes." while it transfers; Device Details' "Fast Transfer" row says how the
last attempt went ("Over Wi‑Fi, Today, 10:02 AM", or "Back to Bluetooth, …" and why), or "Unavailable in
this build".

### Owner steps: the Hotspot Configuration entitlement

Joining another network needs the Hotspot Configuration capability. Done (2026-10-29):

1. The account owner enabled **Hotspot Configuration** on the App ID `local.daybook.phone` in the
   developer portal (Certificates, Identifiers & Profiles › Identifiers). It's also enabled on the Mac's
   App ID, which Daybook doesn't use: Fast Transfer is iPhone-only.
2. The entitlement is in the iPhone app's entitlements, from `Apps/iOS/project.yml` (the iPhone target's
   `entitlements.properties`, which XcodeGen writes to `DaybookPhone/Resources/DaybookPhone.entitlements`):
   `com.apple.developer.networking.HotspotConfiguration: true`. The widgets and the Mac app don't have it.

Profiles regenerate in the release pipeline; nothing here touches signing. A build without the
entitlement still works: its first join fails at once and every transfer stays on Bluetooth.

### Verifying it on a recorder

Until then it's unverified. To check it, on an iPhone build with the entitlement, near a charged
recorder, in the foreground: choose "Import over Wi‑Fi" for one recording, accept iOS's prompt to join
`WiFi-…`, and keep Daybook open. Then copy Device Details (its "Fast Transfer" row and "Last problem")
and the `local.daybook.devices` log (`Soundcore` category), and note whether the recorder's light
changed, whether its Wi‑Fi appeared in Settings › Wi‑Fi, how long the transfer took against Bluetooth,
and whether Bluetooth came back and the access point closed. A failure at the WebSocket step usually
means the handshake or TLS differs; a capture of the official app's Fast Transfer would settle it.

## The recorder's clock

Recording IDs are Unix start times by the recorder's own clock, which nothing keeps right. When the
recorder confirms a Start Daybook sent, the new recording's ID against the send time is its offset
(`SoundcoreClock`; a resume of a recording kept open isn't a measurement). It's kept with the
remembered recorder, per serial, and in `SoundcoreClocks` for the importers. Offsets beyond the
measurement's two-second resolution are taken off every start date: the list, Recording now, the
status, and a new conversation's date and title (`DeviceRecordingStart`). Device Details'
technical rows say "In step", or "5 min ahead" past a minute. An imported recording keeps the
offset in its track's capture details (`TrackCaptureDetails.recorderClock`: the offset, when it was
measured, and whether it was applied), through `DeviceRecordingStart.clock(of:)` and the importer's
`RecordingProvenance.recorderClock`; a recording imported again keeps the first one.

## What it never does

No delete, reset, bind or unbind, firmware update, time sync, Classic SPP, or vendor account call.
The recorder's Wi‑Fi is used only for Fast Transfer, as above. The simulator tests assert that only
status, list, key exchange, transfer, stop transport, (when asked) record control, and for Fast
Transfer only opening and closing the access point (`1A 05`, `1A 02`) are ever sent over Bluetooth,
and over Wi‑Fi only file requests (`1A 07`) and `FINISH` (`SoundcoreSimulatorTests.readOnlyCommands`).

## Verification

`SoundcoreProtocolTests` cover command bytes, fragmented and corrupted frame recovery,
battery and storage decoding, both list layouts, slice bounds, malformed lists, a 2,000-round
fuzz of every parser, the NIST AES-256-CTR vector, P-256/HKDF/file-key agreement with tampering,
and the native Opus path.

`SoundcoreSharedRecordingTests` cover the button heard and Daybook's own commands not, holding the
link (no idle release, back without the cooldown, the person's Disconnect, never a scan, the system's
record tried again), live audio saved into a shared recording and the recorder's file becoming the
same track (identical bytes) or replacing it (different), live audio that goes quiet kept, and what
live audio costs the link (above).

`SoundcoreFastTransferTests` run Fast Transfer end to end on loopback, against the simulated recorder's
access point: a TLS WebSocket server with a self-signed certificate made in memory (no keychain), whose
HTTP parser accepts only the official client's header names exactly, and a UDP listener counting
keep-alives. They cover a long recording over Wi‑Fi with the Bluetooth key reused and the access point
closed after, a batch sharing one access point, the link ending between two recordings, short
recordings staying on Bluetooth unless chosen, the foreground only (and leaving it mid-transfer), a
build without the entitlement (and not trying again), a declined join, the WebSocket dropping
mid-file, `1A 05` refused or unanswered, and an access point left open closed on the next connection
and remembered across a relaunch. `SoundcoreProtocolTests` cover `1A 05`'s payload and reply, the
18-byte file request, and WebSocket framing at every length form, masked and not.

`SoundcoreSimulatorTests` run the real connection, session, queue, and importer against the
simulated recorder: setup and remembered reconnection (direct and after a scan), paged listing
with the 8-byte fallback, imports with identity, one-at-a-time queues, integrity failures (gaps,
wrong sizes) with one retry, stalls, Try Again, Stop, disconnect mid-transfer with resume after
the reconnect, Bluetooth off mid-import, Bluetooth off and denied at setup, idle release,
automatic import since setup and its release, no automatic import before the library loads,
record control with and without confirmation, Listen Live portions, and the read-only command
set. A list request the recorder leaves unanswered or refuses is reported, tried again on its
schedule (and automatic import carries on once it lists), and another app's replies and audio on a
shared link are counted without changing anything. With the simulator emulating another app's paced
transfer (`beginAnotherAppsTransfer`), an import and a Start wait for it and say so, a transfer under way
gives way to it without asking the recorder to stop sending and starts again afterwards, nothing Daybook
sends cuts the other transfer off, and another app's key exchange is followed by one of Daybook's own.
The simulator also has firmware variants that list the active file and keep a paused one
open, a button press, and a skewed clock, for: no import from a remembered list on reconnect, a
paused-open recording neither imported nor queued, listing again on the button's start and stop,
the last-known recording as of its time and its expiry, the clock measured on Start and applied to
start dates, a recording arriving through sync during its transfer, and a background wake after
the cooldown. No microphone, real Bluetooth, or downloads are used.

**Not yet verified on hardware:** a shared recording's live audio over hours (sustained throughput,
the recorder's real live pacing and packet size, whether its stream ends when its button stops it),
holding the link in the background for days (the recorder's battery, whether it stays connectable),
the button's push reaching a backgrounded or relaunched iPhone, discovery and permissions on current firmware, actual battery
and storage values, the active recording's place in the list (among the entries or only after
them) and whether Pause keeps it open, whether the button reports `18 82`, how far real recorder
clocks drift, transfer throughput and packet loss, reconnect timing, live reception, and automatic
import alongside the phone app: whether the recorder answers a list request while the Soundcore app
is transferring, and what the list's trailing field names then. Two apps on one link: whether the
Soundcore app's transfer reaches Daybook as notifications on iOS, whether three quiet seconds is enough
between its files, whether a request of Daybook's really cuts its transfer off, and whether the recorder
keeps one audio key for both apps. Wi‑Fi Fast Transfer, all of it: `1A 05`'s payload and reply, the
access point's start time, the WebSocket's TLS and handshake, the file request's last byte, whether
the keep-alive matters, the recorder accepting Bluetooth while its access point is open, `1A 02`'s
reply, whether `FINISH` closes the access point, and the throughput.
