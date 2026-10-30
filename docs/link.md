# DaybookLink: the Mac ↔ iPhone local link

DaybookLink is the local-network channel between Daybook on a Mac and Daybook on an iPhone
(docs/iphone.md, "Local link"). It carries what iCloud is too slow for: multipoint start and
stop (cascading, docs/multipoint.md, "Starting anywhere"), live recording state, notes and
bookmarks during a shared recording, live processing progress, nudges about processing
requests, presence, and clock samples. Everything else still travels through sync, so without the
link the apps keep working, only later.

It is local only: Bonjour on the shared network, one TCP connection per phone, no servers, no
relays, no accounts. `Sources/DaybookLink` builds for macOS 15 and iOS 26 and depends only on
Foundation, Network, CryptoKit and Security.

| Piece | Choice |
| --- | --- |
| Discovery | Bonjour `_daybook-link._tcp`. The Mac advertises; the phone browses. The TXT record carries salted tags of the library and Mac IDs |
| Pairing | The Mac shows a six-digit code; the person chooses that Mac on the phone, then types the code (the code boxes appear only once a Mac is chosen, so a code never goes to the wrong one). Passkey-entry exchange over P-256 ECDH (below) |
| Transport | TLS 1.2, `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`, with the pairing key as PSK; session authentication bound to the TLS session |
| Framing | `NWProtocolFramer`: 4-byte big-endian length, then one JSON message (max 256 KiB) |
| Messages | `{"v": version, "type": "...", "body": {...}}`; unknown types and fields are ignored |
| Keys | Data-protection keychain, `…AfterFirstUnlockThisDeviceOnly`, behind `LinkKeyStore` (`MemoryLinkKeyStore` in tests) |

## Threat model

**Setting.** The Mac and phone are on the same network, which may be café or hotel Wi-Fi. Anyone
else on it can see Bonjour adverts, watch and inject traffic, answer Bonjour queries, connect to
the Mac's port, and sit in the middle of a connection (ARP or DNS-SD spoofing).

**Worth protecting.**
- Control: starting and stopping recordings, marking bookmarks.
- Content of the traffic: conversation IDs, timings, Mac and phone names, processing progress.
  Audio and transcripts never travel over the link.
- The pairing key, which grants all of the above later on any network.

**What the design ensures.**
- Only a phone whose user saw the Mac's screen can pair. A guesser gets one try per code, with
  success probability 2⁻²⁰ (about 10⁻⁶), and at most 5 tries before pairing closes.
- A device in the middle of a pairing can't learn the key or finish pairing with either side
  (it, too, succeeds with probability 2⁻²⁰).
- A passive eavesdropper learns nothing about the key (ECDH) or later traffic (TLS with ECDHE,
  so recorded traffic stays private even if a key leaks later).
- Sessions are mutually authenticated. A recorded handshake replayed in another session fails,
  whether or not the attacker has a key.
- Unpairing either side stops the other from connecting. Keys stay on the device that made them
  (`…ThisDeviceOnly`, never iCloud Keychain).

**Out of scope or accepted.**
- **Denial of service.** Someone on the network can burn pairing codes, take the single pairing
  slot (60 s at most), spoof adverts, or drop packets. The link fails closed, and sync still
  delivers.
- **Presence.** Bonjour shows a Mac named "Studio Mac" running Daybook. The Mac advertises only
  while pairing is open or a phone is paired. The TLS PSK identity is a stable pseudonym per pair,
  sent in the clear, so sessions of one pair can be linked by an observer. Message sizes and
  timing are visible.
- **A stolen, unlocked phone**, or malware on either device. Such a phone can control recordings
  until it's unpaired. The Mac always shows when it's recording.

## Pairing

The brief allowed a PAKE or a code-authenticated key confirmation. The obvious construction,
ECDH plus "HMAC the transcript with the code", is not sound with a six-digit code. A device in
the middle receives the first HMAC, tries all 10⁶ codes offline in milliseconds, and completes
both sides. SPAKE2 and CPace need elliptic-curve point arithmetic that CryptoKit doesn't expose.
SRP needs big-integer code. Apple's SPAKE2+ in Security.framework is private SPI. Writing curve
arithmetic for this would mean inventing cryptographic code.

DaybookLink therefore uses **Bluetooth LE Secure Connections Passkey Entry** (Core Spec v5.x, Vol
3 Part H §2.3.5.6.3). It is published, analysed, and needs only P-256 ECDH, HMAC and HKDF, all from
CryptoKit. The only change is that HMAC-SHA256 and HKDF-SHA256 replace AES-CMAC (`PasskeyExchange`
in `LinkPairing.swift`):

1. **Exchange keys.** The phone sends `pair.begin` with its ID, name and ephemeral P-256 key; the
   Mac answers `pair.accept`. A peer echoing either side's own key or ID is rejected (reflection).
2. **Prove the code bit by bit.** For each of the code's 20 bits rᵢ:
   - Each side commits Cᵢ = HMAC(Nᵢ, label ‖ role ‖ own key ‖ peer key ‖ rᵢ) under a fresh 32-byte
     nonce. The phone commits first, then the Mac.
   - The phone reveals its nonce, and the Mac checks it. Only then does the Mac reveal its own
     nonce, and the phone checks it.
   - A device in the middle has different keys on each side, so it must commit to every bit before
     learning it.
3. **Confirm.** The transcript T is SHA-256 of every frame through the last reveal. Both sides
   compute HKDF(ECDH secret, salt T, info "… keys v1" ‖ both IDs) and split the 80 bytes into a
   confirmation key, the 32-byte link key, and a 16-byte PSK identity. The phone sends
   HMAC(confirm key, "initiator" ‖ T ‖ code). The Mac checks it, stores the pairing, rebuilds its
   listener with the new key, and only then sends its own confirmation, so the phone's first
   session finds the key ready.

**Codes are single-use.** A failed attempt reveals bits up to the failure, so:
- The Mac replaces its code after **any** attempt that doesn't finish: a wrong bit, a broken
  confirmation, a timeout, or a dropped connection.
- The phone never sends a code that failed (`codeAlreadyUsed`). It burns the code before the
  attempt and gives it back only when the Mac turned the attempt away before either side committed
  to a bit (`notPairing`, `busy`, `unsupportedVersion`, or no answer at all), so a crash part-way
  leaves it burned too.
- Burned codes outlive a relaunch: UserDefaults (`daybook.link.burnedCodes`) keeps them as salted
  SHA-256 digests, never digits, each forgotten after the 5 minutes a code can live on the Mac.
- A refusal (`pair.refuse`) is believed only before the phone's first commitment. Later it counts
  as a wrong code. Otherwise a device spoofing the Mac's advert could commit a guess for each bit,
  learn the bit from the phone's reveal, refuse as `busy` whenever it guessed wrong, and so collect
  the 20 bits in about ten retries while the code is still good on the real Mac.
- Codes expire after 5 minutes.
- Pairing closes after 5 failed attempts.
- One attempt runs at a time; others get `busy`.

Pairing runs over the same TLS listener as sessions, using a **public** PSK
(`daybook-link-pairing-v1`). That PSK gives no authentication; it only lets an unpaired phone in
and hides the exchange from passive observers. All of pairing's security comes from the exchange
above.

## Transport and session authentication

**TLS version.** The brief asked for TLS 1.3 with a PSK. Network.framework's public API doesn't
negotiate external PSKs in TLS 1.3. Verified on this SDK:
- With a PSK configured, BoringSSL logs "TLS 1.3 external PSK callback is not enabled" and caps the
  maximum version at 1.2.
- Pinning 1.3 fails with `NO_SUPPORTED_VERSIONS_ENABLED`.
- The 1.3 PSK calls (`sec_protocol_options_add_external_pre_shared_key`) exist only as private SPI.

So the link pins **TLS 1.2** with `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (RFC 5489, RFC
7905). The PSK authenticates, ephemeral ECDH gives forward secrecy, ChaCha20-Poly1305 is an AEAD,
and tickets and resumption are off. Moving to 1.3 once Apple exposes it is a change to
`LinkTransport.parameters` only.

**Two Network.framework details found while testing:**
- **PSK identities are C strings.** A NUL byte truncates them. A random binary identity failed
  about 1 connection in 16 with "unknown PSK identity", so identities go on the wire as
  `dbl1-<hex>`. Keys are binary-safe, which was verified with keys that differ only after a
  NUL byte.
- **The listener's PSK list is fixed when it's created.** Pairing or unpairing reopens the
  listener on the same port. Connections it has already accepted carry on.

**Session handshake.** On the Mac, the listener holds every paired phone's PSK plus the pairing
PSK, and TLS doesn't say which one a client used. Sessions are therefore authenticated inside TLS,
bound to the TLS session with an RFC 5705 exporter E (`EXPORTER-DaybookLink-session-v1`):

- The phone sends `hello`: its versions, device ID, the Mac ID it expects, capabilities,
  heartbeat interval, and HMAC(link key, label ‖ "C" ‖ E ‖ phone ID ‖ Mac ID).
- The Mac looks up that phone's key and checks the HMAC (constant time). It answers `welcome`
  with the agreed version, its capabilities, and the same HMAC with "S".
- Otherwise it answers `refused` with a reason: `incompatibleVersion` (with its range),
  `notPaired`, `authenticationFailed` or `wrongDevice`.

A hello copied into another TLS session, or relayed by a device in the middle, has the wrong E
and fails, even when sent by someone who has the key. Connections that don't authenticate within
the handshake timeout (10 s) are closed. At most 16 unauthenticated connections are held.

**Local connections only.** A listener can't be bound to "the local network", so the Mac drops a
connection before TLS unless it comes from loopback, a private (RFC 1918) or link-local IPv4
address, a link-local or unique local (`fc00::/7`) IPv6 address, or a subnet one of its interfaces
is on (`LinkLocalNetwork`; point-to-point links such as VPN tunnels don't count). A Mac with a
public address can't be reached for pairing or sessions from the internet.

## Discovery

The Mac advertises `_daybook-link._tcp` under its name, with this TXT record:

| Key | Value |
| --- | --- |
| `s` | 8-byte random salt, hex; new each time the service starts |
| `l` | first 8 bytes of SHA-256("DaybookLink library tag v1" ‖ salt ‖ library UUID), hex |
| `d` | the same for the Mac's device ID ("device tag") |
| `v` | protocol versions, `min-max` |
| `p` | `1` while pairing is open |

A phone recognises its library and its paired Macs by computing the tags. Nobody else learns the
IDs or can follow a Mac between networks by them. The phone offers only Macs that share its
library, plus Macs it's already paired with. With no library yet, it offers all. A spoofed advert
can copy the tags, but it can't complete TLS without the key.

## Messages

| Type | Body | Direction | Notes |
| --- | --- | --- | --- |
| `hello` / `welcome` / `refused` | handshake | phone → Mac / Mac → phone | always written at version 1 |
| `capabilities` | `LinkCapabilities` | both | device class, name, app version, library ID, `canProcess`, features, `syncDeviceID` (optional) |
| `recording.state` | `LinkRecordingState` | both | phase, conversation, start, elapsed, sent-at; the recorders the sender manages (optional); the shared recording it takes part in only through its recorders (`sharedConversationID`, optional) |
| `record.request` / `record.reply` | `LinkRecordRequest` / `LinkRecordReply` | both | start or stop, conversation, prior timing (with where the timeline began), the conversation's title and date, standalone, a recorder the receiver manages, a cascading start (`cascade`: what started it, whether the requester records itself, its recorders) (all optional but the first two); reply is an ack or a refusal with a reason |
| `bookmark` | `LinkBookmark` | both | conversation, recording time, created-at, label: a bookmark made during a shared recording, by its ID |
| `bookmark.change` | `LinkBookmarkChange` | both | a shared bookmark's label changed, or it was deleted; changed-at |
| `note` | `LinkNote` | both | a paragraph written, edited, or deleted during a shared recording: its anchor ID, text, the time its writer files it at, made-at, changed-at |
| `captions` | `LinkCaptions` | iPhone → Mac | the live captions an iPhone makes of a shared recording, the lines that changed since it last sent (each with its ID, times in its recording, text, tentative, the voice and person live speakers heard, and the recorder that heard it, if not the phone), and when its recording began on its clock; only to a Mac recording the same conversation that lists `liveCaptions` |
| `processing.progress` | `LinkProcessingProgress` | Mac → phone | meeting, phase, fraction, Mac name, detail |
| `processing.nudge` | `LinkProcessingNudge` | phone → Mac | "I just wrote request X": the request itself travels through sync |
| `recorder.handoff.request` | `LinkRecorderHandoffRequest` | both | take (or give) a recorder, by kind and serial, addressed by the owner's sync ID |
| `recorder.handoff.reply` | `LinkRecorderHandoffReply` | both | accepted (what it finishes first, time left) or refused with a reason; repeated as progress |
| `recorder.release` | `LinkRecorderRelease` | both | the old owner let go: imports that were waiting, recordings it imported recently, the recording in progress and the conversation waiting for it (with whether it stops when that conversation's recording does; optional) |
| `libraryKey.request` | `LinkLibraryKeyRequest` | both | an encrypted library's ID and the key IDs the sender waits for |
| `libraryKey.grant` | `LinkLibraryKeyGrant` | both | library ID, key ID, the key's 32 bytes |
| `ping` / `pong` | sequence, interval | both | presence |
| `clock.request` / `clock.reply` | t1 / t1 t2 t3 | both | NTP-style samples |
| `unpair`, `goodbye` | | both | |
| `pair.*` | begin, accept, refuse, commit, reveal, confirm, fail | pairing only | |

**Closing.** A side that ends a connection sends its last frame (`goodbye`, `unpair`, a refusal, or the final pairing reply), then keeps reading and dropping frames until the other side closes, or for at most a second, and only then closes. Closing with unread data makes the kernel reset the connection, and a reset can discard the last frame before the other side reads it: the other side then sees a lost connection instead of a goodbye, or never learns it was unpaired (`LinkChannel.close(after:)`).

**Compatibility rules.**
- Within a version, only optional fields and new types are added. Receivers ignore unknown types,
  unknown fields, and known types whose body they can't read (counted, not fatal).
- Values that may grow (phases, reasons, modes, device classes) are `LinkOpenValue`s, so an
  unknown value is kept, not rejected.
- A record reply this build can't read is a refusal, never a silent yes.
- A breaking change gets a new version. Each side offers a range, the highest common version
  wins, and handshake messages never change shape.
- With no common version, the phone shows `failed(.incompatibleVersion(peerVersions:))` and
  stops retrying until one side updates.

## Recorder handoff

Moving a recorder (Soundcore Work) between a Mac and a phone (docs/devices.md, "Handing a
recorder over"). Who manages a recorder is a synced library setting; these messages only make the
change take seconds instead of a sync round trip. They're app messages, added within version 1:

- A device that understands them lists `recorderHandoff` in its capability features and sends its
  sync replica ID as `syncDeviceID` (ownership records name devices by it; on the iPhone it differs
  from the link device ID).
- A request is idempotent by ID: a repeat gets the first answer. It names the device it's for
  (`addressedTo`), so another device says `notOwner` instead of acting.
- A reply this build can't read is a refusal, never a yes. Unknown intents are refused as
  `unsupported`; unknown reasons are kept.
- An older peer ignores the types; the requester hears nothing within 5 s and falls back to sync.
- Replies and the release are sent in order, one after another.

## Record control

`request(_:from:)` sends a `LinkRecordRequest` and waits up to 10 s for the reply. The receiver's
`LinkRecordControlHandler` decides the answer:
- `.accepted(LinkRecordAck)`: start or stop time on the receiver's clock, the receiver's
  recording ID (each recording's own, not the conversation's), and `wasAlreadyRecording`.
- `.refused(LinkRecordRefusal)`: one of `recordingSomethingElse` (with that conversation),
  `notRecording`, `microphoneUnavailable`, `permissionDenied`, `storageFull`, `busy`, `declined`,
  `recorderUnavailable` or `unsupported`.

Without a handler, every request is refused as `unsupported`. The iPhone's handler refuses a start
from a Mac the person hasn't allowed to start recording there (asked once per pairing;
docs/iphone.md, "Local link") as `declined`, with a sentence the Mac shows. Requests are idempotent by ID: a
retry after a lost reply, even on a new connection, gets the first answer and never starts a
second recording, and a request repeated while the first is still being answered (a microphone
prompt that outlasts the timeout) reaches the app once, with every connection that asked getting
its answer. Both apps therefore ask again with the same ID when an answer doesn't come, rather than
giving up. `LinkTiming` carries the requester's prior: its own start, where the conversation's
timeline began and how much of it has passed, and its clock-offset estimate with uncertainty.

Additions within version 1, all optional, which older builds ignore:
- `title` and `date`: the conversation as the requester has it, so a receiver that hasn't synced it
  makes the same record rather than a placeholder.
- `standalone`: record a conversation of the receiver's own (a device page's Start Recording). A
  start without timing, from an older Mac, means the same.
- `recorder` (`LinkRecorderTarget`: kind, serial, and for a stop the recording's ID): start or stop
  a recorder the receiver manages instead of its microphone. Sent only to a peer that lists
  `recorderControl` in its features, since an older one would record its own microphone; a stop
  pauses only the named recording, and only once the recorder's list has been read again (an older
  one may name a recording the person has stopped since): without that, it's refused as
  `recorderUnavailable`, to ask again.
- `LinkTiming.timelineStart`: from an older build, `elapsed` counted from the requester's own start.

## Shared recordings

Additions within version 1 for recording across devices (docs/multipoint.md, "Starting anywhere" and
"Notes and bookmarks during a shared recording"). An older build ignores the new types and fields:
`note` and `bookmark.change` reach it as types it doesn't know (ignored and counted), a `cascade` on a
start reads as a start the person chose, and `sharedConversationID` isn't read.

- **Features.** `cascade` (`LinkCapabilities.cascadeFeature`): the device joins and stops shared
  recordings on its own, reads `cascade` and `sharedConversationID`, and accepts a stop from a device
  recording a conversation with it. `sharedNotes`: it takes `note`, `bookmark.change`, and `bookmark` in
  both directions. Both apps list both. `liveCaptions` (the Mac lists it): it shows another device's
  `captions` of a shared recording beside its own; an older Mac is never sent them.
- **Cascading start.** `LinkRecordRequest.cascade` says what started the requester's recording
  (`person`, `recorder`, `automatic`, or another `device`; an open value), whether the requester records
  the conversation itself (`requesterRecords`; false for an iPhone whose recorder records while it
  can't, sent only to devices listing `cascade`), and its recorders. A start with `cascade` always
  joins the requester's conversation, never one of the receiver's own (`isStandalone`).
- **Recording state.** `sharedConversationID` names a shared recording the sender takes part in only
  through its recorders; `LinkRecordingState.takesPart(in:)` is what a follower checks.
- **Notes and bookmarks** carry their IDs (a paragraph's anchor ID, a bookmark's ID), so the copy over
  the link and the one through sync are one item. A note carries the time its writer files it at,
  which the receiver keeps exactly, and when it was written and changed on the sender's clock; the
  receiver moves those onto its own and keeps the latest change of each item.

## Recording state

`recording.state` says what the sender is recording: when that changes, every 15 s while
recording, and as the phone connects (each side sends its own then). It carries the recorders the
sender manages (`LinkRecorderState`: kind, serial, name, recording or not, the recording's ID and
start, the conversation it records along with, and when that was last confirmed), filled from what
its device sessions know and sent again when they change. A receiver moves the times onto its own
clock, keeps a phase for 45 s (it's repeated while recording), and a recorder's state until 20
minutes past its as-of time. A recorder entry it can't read is dropped, never the whole state.

A device recording because the other asked follows it: when the one that asked says it isn't
recording that conversation any more, or has been unreachable for 30 minutes, it stops too.

## Clock samples

Each side sends a burst of 6 samples, 0.2 s apart, after connecting, then one every 2 minutes;
`sampleClock(of:)` forces one. For each sample:
- offset = ((t2 − t1) + (t3 − t4)) / 2, and round trip = (t4 − t1) − (t3 − t2);
- t2 is taken when the frame arrives and t3 just before the reply is written.

The estimate is NTP's clock filter: of the last 8 samples (at most 15 minutes old), the one with
the shortest round trip. `LinkClockEstimate` holds the offset (peer − local), the round trip and
`uncertainty` (half the round trip, the most a lopsided path can move it), and converts dates
both ways. It appears on `LinkPeer.clock` and in `.peerUpdated`.

For multipoint, this replaces "the recorders' clocks only, ±120 s" (docs/multipoint.md) with a
measured prior good to a few milliseconds on a quiet LAN. A phone recording can be placed by
clock before any sound is compared.

## Lifecycle

- **Heartbeats.** Both sides ping every 5 s and give up after 15 s of silence. Each ping carries
  the sender's interval, and the slower side sets the pace for both, so a phone recording in the
  background (20 s / 60 s) isn't woken every 5 s by the Mac. After a wake, a network change, or
  lost viability, `probe()` asks for an answer within 3 s.
- **Reconnection.** The phone retries with exponential backoff: 0.5 s doubling to 30 s, ±20%
  jitter (2 s to 60 s while recording in the background). A Mac that drops is looked up again by
  Bonjour, because its address may have changed.
  - Authentication failures retry at the slowest rate and show `failed(.authenticationFailed)`:
    the Mac may have forgotten the phone, or this isn't really that Mac. Only an authenticated
    `unpair` deletes a key.
  - Version mismatches stop retrying.
- **Network changes.** The phone watches the path, with cellular excluded. With no local network
  it stops retrying (`waitingForNetwork`). When a network comes back or changes, it probes live
  sessions and retries the rest at once. Connections never use cellular.
- **iOS battery and background.** The app reports its state with `setActivity(_:)`:
  - `.foreground`: browse, connect, normal heartbeats.
  - `.backgroundRecording`, while a recording with a Live Activity runs, or while only a recorder
    this iPhone manages records a shared recording (its button started it with Daybook in the
    background; docs/multipoint.md): keep the connection (bringing it back from a background launch),
    with slow heartbeats and slow retries.
  - `.background`: say goodbye, close everything, stop browsing and path monitoring. iOS would
    suspend the app anyway; calling `.foreground` again reconnects.
- **Mac sleep and wake.** Call `systemDidWake()` from `NSWorkspace.didWakeNotification`. It probes
  every phone and reopens the listener if it failed. The listener also reopens on its own after a
  failure, with backoff, falling back to any port, which Bonjour carries.

## API

### Mac

```swift
let service = LinkService(identity: LinkIdentity(deviceID: macID, name: "Studio Mac", deviceClass: .mac,
                                                 appVersion: version, libraryID: library, canProcess: true),
                          keyStore: KeychainLinkKeyStore())
try await service.start()                        // listen and, if useful, advertise
for await event in service.events() { … }        // .pairingCode, .paired, .connected, .received, …

let code = await service.beginPairing()          // show code.formatted ("482 913")
await service.endPairing()
await service.connectedPeers                     // [LinkPeer]: capabilities, version, clock
try await service.pairedDevices()                // [LinkPairedDevice], never keys
try await service.send(.processingProgress(…), to: phoneID)   // nil = every phone
let reply = try await service.request(LinkRecordRequest(action: .start, conversationID: id,
                                                        timing: prior), from: phoneID)
await service.setRecordControlHandler { peer, request in … }  // phone asks the Mac to record
try await service.unpair(phoneID)
await service.updateIdentity(newIdentity)        // name, library, canProcess changes
await service.systemDidWake()
await service.stop()
```

### iPhone

```swift
let client = LinkClient(identity: LinkIdentity(deviceID: phoneID, name: UIDevice.current.name, deviceClass: .iPhone,
                                               appVersion: version, libraryID: library),
                        keyStore: KeychainLinkKeyStore())
for await event in client.events() { … }         // .discovered, .connectionState, .connected, .received, …

await client.startBrowsing()                     // pairing screen: .discovered([LinkDiscoveredMac])
let mac = try await client.pair(with: discovered.endpoint, code: typedCode)   // throws LinkPairingError
try await client.connect(to: mac.deviceID)       // keep connected; found by Bonjour
try await client.send(.bookmark(LinkBookmark(conversationID: id, recordingTime: t)))
try await client.send(.processingNudge(…))
let reply = try await client.request(LinkRecordRequest(action: .start, …), from: mac.deviceID)
await client.setRecordControlHandler { mac, request in … }   // Mac asks the phone to record
await client.setActivity(.backgroundRecording)   // scene phase + Live Activity
await client.connectionState(of: mac.deviceID)   // searching, connecting, connected, waitingToRetry, …
try await client.unpair(mac.deviceID)
```

Both are actors whose executor is the serial queue that Network.framework calls back on.
`events()` can be called any number of times; each stream gets every event.

### For the Mac and iPhone integration phase

- **"Daybook on iPhone" as a DeviceKind (direct method).** Adapt `LinkService` into a
  `RecordControlConnection`:
  - `startRecording` and `pauseRecording` map to `request(_:from:)`;
  - `status` follows `.received(.recordingState)`;
  - `connectedPeers` gives presence, and `LinkPeer.clock` gives the start-time prior.
  - Use the ack's `recordingID` and `startedAt` to fill `CompanionRecording.recordingID` and
    `recorderStartedAt`. The recording itself arrives through sync.
- **Processing status.** The Mac sends `processingProgress` as its queue runs. The phone shows it
  over the coarse, synced status, and sends `processingNudge` after writing a `ProcessingRequest`.
- **Identities.** Keep `deviceID` stable per install. `libraryID` is the sync manifest's library
  UUID.
- **Testing.** Tests and diagnostics use `LinkConfiguration.loopback()` (loopback, no Bonjour, short
  timers) and `MemoryLinkKeyStore`.

## App requirements

Both apps' Info.plist:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Daybook finds your Mac on this network to record together.</string>
<key>NSBonjourServices</key>
<array><string>_daybook-link._tcp</string></array>
```

- iOS needs both keys before browsing or connecting; without `NSBonjourServices` the browser
  finds nothing. macOS 15 applies local-network privacy to the Mac app too, so add them to
  `Resources/Info.plist`.
- No entitlement is needed for Bonjour through Network.framework:
  `com.apple.developer.networking.multicast` is for raw multicast only.
- An unsandboxed Mac app needs no network entitlement. In the App Sandbox the listener needs
  `com.apple.security.network.server` and connections `.client` (docs/sandbox.md), loopback included.
- Keychain: the default access group works.
  - Items are in the data-protection keychain as `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
    so a recording that continues on the iPhone's Lock Screen can reconnect, and neither iCloud
    Keychain, a backup, nor Migration Assistant carries a key to another device.
  - If an extension ever needs the link, add a `keychain-access-groups` entry and pass it as
    `KeychainLinkKeyStore(accessGroup:)`.
  - On macOS the data-protection keychain needs a signed build with an application identifier
    (the provisioning profile the iCloud capability already requires). Earlier versions kept Mac
    keys in the login keychain; the first use moves them (read, write the new item, delete the
    old). If any item can't be moved, the store stays on the login keychain for that run so no
    pairing goes missing, and tries again at the next launch; when both keychains hold a pairing,
    the newer one wins. Builds that can't use the data-protection keychain (unsigned development
    and `swift test` builds get `errSecMissingEntitlement`, as do ad hoc builds) keep the login
    keychain. `LinkKeyStoreTests` cover the move and the fallback against a keychain in memory.
- Background: the link adds no background mode. It rides on the recorder's `audio` mode while
  recording, and on `bluetooth-central` while only a recorder records a shared recording (iOS keeps
  Daybook running for the recorder's stream), and is closed otherwise.

## Library keys

An encrypted library's key (docs/icloud-sync.md, "Encryption") normally reaches a device through iCloud Keychain. When
that's off on a device, or slow, the link carries it: a device waiting for the key shows Get Key from (a connected Mac on
the iPhone, a connected iPhone on the Mac), which sends `libraryKey.request` with the library's ID and the current key's
ID. The other device sends one `libraryKey.grant` per key it holds of those asked for, and only when the asker's
capabilities name the same library as its own and the request does too (`LinkLibraryKeyRequest.grants`); every session
is with a paired device, and the session is encrypted with the pairing's key. It then says so ("Sent this library’s key
to Alex’s iPhone."). The receiver keeps a granted key only when its ID matches its bytes and the library is its own, and
syncs at once. Both types are additive within version 1: an older build ignores them, and the asker keeps waiting for
iCloud Keychain. There's no Mac-to-Mac path; two Macs rely on iCloud Keychain or a recovery key.

## Tests

`swift test --filter DaybookLinkTests`: 73 tests, about 9 s. Everything runs on 127.0.0.1 inside
the test process, and nothing is advertised.
- **The exchange on its own:** same keys on both sides; a wrong code fails at its first different
  bit; a guessing device in the middle fails; tampering with the transcript fails; a reflected
  key is rejected.
- **Pairing over loopback:**
  - success, then an immediate session;
  - a wrong code is rejected, the code is burned and replaced, and a failed code is never resent;
  - a refusal is believed only before the first commitment: a Mac impersonator that refuses after
    a reveal burns the code, across a relaunch too, while an early `busy` leaves it usable; burned
    codes are stored as salted digests that expire;
  - pairing closes after too many failures, and is refused while the Mac isn't pairing;
  - a recorded pairing replayed frame for frame against the same Mac and the same code fails at
    the first reveal;
  - a recorded hello replayed in a new TLS session is refused, with and without the key;
  - an unknown phone is refused.
- **Sessions:**
  - round trips of every app message both ways, and capability updates;
  - unknown types, fields and values are tolerated and counted;
  - version negotiation, and incompatible versions without retries;
  - reconnection after the connection drops;
  - heartbeat timeout on both sides through a relay that goes silent, then reconnection;
  - background, foreground and background recording;
  - clock offset of +2.5 s through a 40 ms + 40 ms relay is within 20 ms, and a lopsided
    60/10 ms path stays within the reported uncertainty;
  - record control: acknowledged, refused with a reason, idempotent repeat, unsupported, and
    timeout; a repeat on a new connection while the first is still being answered reaches the app
    once and gets that answer;
  - unpairing from either side, and a phone the Mac forgot while it was away;
  - pairing identities containing zero bytes.
- **Shared recordings** (`LinkSharedRecordingTests`): round trips of a cascading start, a recording
  state with `sharedConversationID`, notes (written and deleted), bookmarks and their changes, and the
  features; what an older build sends still reads the same (no `cascade`: chosen by the person, and
  standalone without timing; missing and unknown fields); the new types read as unknown types by a
  build that doesn't know them, and over a session both ways.
- **Library keys:** a request and its grant over a loopback session, only the keys asked for; nothing for a device of
  another library, or without one (`LinkLibraryKeyTests`).
- **Recorder handoff:** round trips of the request (take and give), both replies and the release;
  an unreadable reply is a refusal; earlier and later fields and values decode; capabilities carry
  the sync ID and feature, and older ones don't; the messages over a loopback session both ways.
  The handoff itself, over loopback with a simulated recorder, is `RecorderHandoffTests` in
  DaybookKit.
- **Local network:** which addresses count as local (IPv4, IPv6, IPv4-mapped, attached subnets,
  names), and that the listener drops a connection from elsewhere before any pairing attempt.
- **Units:** wire round trips (with the optional request fields and recorders), older requests and
  unreadable recorders decoding, frames, TXT tags, backoff, clock filter, key store (memory, and
  the keychain store's move to the data-protection keychain against a keychain in memory).

The relay in `LinkTestSupport.swift` is a loopback TCP proxy with per-direction delay that can
freeze (hold connections open, pass nothing) or drop every connection.

## Needs real devices

- **Real network.** Bonjour browse and advertise (not exercised by tests by design), the
  local-network permission prompt on both platforms, and interface changes:
  - Wi-Fi to cellular to Wi-Fi;
  - joining another network;
  - café networks with client isolation, where the link can't work and sync is the fallback;
  - AWDL (`allowPeerToPeer`, off by default).
- **Sleep and wake.** The Mac's listener and sessions across sleep, the phone's probe and
  reconnect timing after the Mac wakes, and whether a stop sent while sleep is held back (up to 5 s)
  reaches the phone before the network goes.
- **iOS background limits:**
  - that `.backgroundRecording` keeps the connection alive with the audio background mode and a
    Live Activity, including on the Lock Screen and across calls and interruptions;
  - that a phone woken in the background by its recorder's Bluetooth traffic (its button) can bring
    the link back (Bonjour lookup, TLS) and ask its Macs to record before iOS suspends it, and keeps it
    while the recorder streams;
  - that `.background` closes cleanly before suspension;
  - the battery cost of 20 s heartbeats.
- **Keychain.** `KeychainLinkKeyStore` in the signed apps: access after first unlock on iPhone;
  on the Mac, that a pairing made by an earlier version moves out of the login keychain without a
  prompt and keeps connecting. Tests use memory storage.
- **Clock accuracy on real Wi-Fi**, where delay is noisier and more lopsided than the relay's.
