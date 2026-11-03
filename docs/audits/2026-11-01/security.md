# Security

Audit of 2026-11-01 against main at 57ed5eb. 8 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| security-insecure-keyed-unarchive | medium | Account token from preferences is decoded with NSKeyedUnarchiver and requiresSecureCoding = false | `Sources/DaybookKit/LibrarySyncController.swift:1187` | w2-sync | fixed |
| security-sealed-library-accepts-plaintext | medium | Encrypted library still reads and seals any new plaintext Events/ or Metadata/ entry, so an iCloud-side writer can inject data | `Sources/DaybookCore/LibrarySyncSealing.swift:334` | w2-sync | fixed |
| security-ci-secrets-left-in-child-env | low | secrets.sh leaves the raw base64 .p8/.p12 and passwords in the environment of the build it runs | `scripts/ci/secrets.sh:245` | w2-scripts-release | fixed |
| security-cloud-key-cross-provider | low | An Anthropic key pasted in the OpenAI field (or the reverse) is sent to the other company | `Sources/DaybookKit/Cloud/CloudSetup.swift:85` | w2-core-data | fixed |
| security-presence-capabilities-plaintext | low | Encrypted library's presence keeps `capabilities.models` in plaintext, which the docs don't list as visible | `Sources/DaybookCore/LibrarySyncPresence.swift:143` | w2-sync | fixed |
| security-recovery-key-clipboard | low | Recovery key Copy puts the library's master secret on Universal Clipboard with no expiry | `Sources/Daybook/UI/SyncEncryptionViews.swift:200` | w2-settings-sync-cloud | fixed |
| security-soundcore-wifi-peer-identity | low | Fast Transfer can connect to a host on the wrong network (accept-all TLS) and reassembles fragments without limit | `Sources/DaybookDevices/Soundcore/SoundcoreHotspot.swift:33` | w2-devices-core | fixed |
| security-unsolicited-library-key-grant | low | Unsolicited `libraryKey.grant` from any paired peer is stored in iCloud Keychain and joins the keyring | `Sources/DaybookCore/LibrarySyncSealer.swift:150` | w2-sync | fixed |
