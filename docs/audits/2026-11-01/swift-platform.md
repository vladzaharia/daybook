# Swift: platform modules and scripts

Audit of 2026-11-01 against main at 57ed5eb. 20 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| QUAL-01 | medium | Stopping a capture while its live model loads leaves the model loaded and leased until quit | `Sources/DaybookLive/LocalStreamingCaptioner.swift:110` | w2-engines-captions | fixed |
| QUAL-05 | medium | The iPhone doesn't link DaybookDesign; its own copies have drifted from the shared components | `Apps/iOS/Shared/PhoneStyle.swift:10` | w1-design-system | partial |
| QUAL-02 | low | package-mac.sh aborts silently after the ZIP when no Developer ID identity matches the team | `scripts/ci/package-mac.sh:193` | w2-scripts-release | fixed |
| QUAL-03 | low | build-ios.sh --test exits silently when there's no iPhone Duo simulator, and duplicates pick-simulator.sh | `scripts/build-ios.sh:250` | w2-scripts-release | fixed |
| QUAL-04 | low | Early-exit readers under pipefail: the SIGPIPE race 57ed5eb fixed in one script remains in others | `scripts/ci/asc-profile.sh:91` | w2-scripts-release | fixed |
| QUAL-06 | low | The shared device framework is ObservableObject/Combine; the iPhone bridges it to Observation with a global revision counter | `Sources/DaybookDevices/Framework/DeviceSession.swift:15` | w1-observation | fixed |
| QUAL-07 | low | Generic DeviceSession downcasts to SoundcoreConnection in 12 places | `Sources/DaybookDevices/Framework/DeviceSession.swift:596` | w2-devices-core | fixed |
| QUAL-08 | low | ImportFolderWatcher lists and stats the watched folder on the main actor every 5 seconds | `Sources/DaybookDevices/Files/ImportFolderWatcher.swift:234` | w2-devices-core | fixed |
| QUAL-09 | low | A device list that fails to decode silently becomes empty, and the next save overwrites it | `Sources/DaybookDevices/Framework/DeviceHub.swift:51` | w2-devices-core | fixed |
| QUAL-10 | low | One unreadable keychain item disables the whole link, and it can't be listed or unpaired | `Sources/DaybookLink/LinkKeyStore.swift:118` | w2-link-pairing | fixed |
| QUAL-11 | low | MeetingSynthesis.generate is a 162-line function with inline magic numbers and stringly-typed JSON | `Sources/DaybookIntelligence/MeetingSynthesis.swift:154` | w2-engines-captions | fixed |
| QUAL-12 | low | The Mac and iPhone link actors duplicate record-request answering and delegate wiring | `Sources/DaybookLink/LinkClient.swift:415` | w2-link-pairing | fixed |
| QUAL-13 | low | Pairing timeouts are matched by string; LinkError.pairing is never thrown; forgetEndpoint forgets nothing | `Sources/DaybookLink/LinkService.swift:549` | w2-link-pairing | fixed |
| QUAL-14 | low | NSLock + @unchecked Sendable in 22 places; adopt Synchronization.Mutex for checked state | `Sources/DaybookCaptions/LiveCaptioning.swift:131` | w2-engines-captions | fixed |
| QUAL-15 | low | Duplicated helpers across Live, Captions, and Intelligence: buffer time, Nemotron presets, runtime strings, hex | `Sources/DaybookLive/LiveAudio.swift:63` | w2-engines-captions | fixed |
| QUAL-16 | low | LiveModelHost counts a user only after awaiting the lease, leaving a reentrancy window | `Sources/DaybookLive/LiveModelHost.swift:86` | w2-engines-captions | fixed |
| QUAL-17 | low | Shared Soundcore copy is Mac-only; the iPhone re-maps it by raw-value string | `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift:88` | w2-devices-core | partial |
| QUAL-19 | low | A wall-clock benchmark with timing assertions runs in the ordinary test suite | `Tests/DaybookDevicesTests/SoundcoreSharedRecordingTests.swift:326` | w2-devices-core | fixed |
| QUAL-20 | low | Small modernization items: polling loops, completion-handler APIs, leftover idioms | `Sources/DaybookDevices/Framework/DeviceSession.swift:621` | w2-devices-core | fixed |
| QUAL-21 | low | build-app.sh and build-ios.sh duplicate the release guard and project setup; the ASC scripts duplicate their helpers | `scripts/build-ios.sh:105` | w2-scripts-release | fixed |

## Notes on partial fixes

- **QUAL-05:** Fixed: the link, facades, TimeLabel removal, and the parity test. Also, the shared components can now be used on iOS without dead code: metrics follow the density, and the caption strip follows Dynamic Type. Not done: replacing RollingMeter, RecordingClockText, RecordingStatusHeader, MultipointStatus, and LiveCaptionsView in the iPhone recording files, which are wave 2.
- **QUAL-17:** My part is done. New DevicePlatform type (.mac/.iPhone/.current, thisDevice, system). SoundcoreIssue gains title(on:), message(on:) and problem(on:), with the iPhone's exact current wording, including its deliberate differences (Import Audio, Settings › Daybook, 'the Soundcore app' on the same phone). SoundcoreWorkIntegration.deviceKind(on:) gives platform-aware tips, summary and setup note, and the transport's error text is platform-aware too. Stale 'this Mac' comments in shared code now say 'this device'. Deleting PhoneDeviceCopy's override table in DeviceScreens.swift is w2-devices-screens' job; the shared words now match it exactly, so deleting it changes nothing on screen.
