import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// What the iPhone says when something goes wrong: a plain sentence with what to do, and the
/// system's own words kept for Details rather than shown.
@MainActor
final class PlainWordsTests: XCTestCase {
    private func makeModel(rig: RecorderRig? = nil) throws -> PhoneAppModel {
        let rig = rig ?? RecorderRig()
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
        return PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                             options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]))
    }

    func testANoticeKeepsTheSystemsWordsForDetailsAndANewOneClearsThem() throws {
        let model = try makeModel()
        model.say("Couldn’t add the recording to your library.", details: "The operation couldn’t be completed. (NSCocoaErrorDomain error 640.)")
        XCTAssertEqual(model.notice, "Couldn’t add the recording to your library.")
        XCTAssertEqual(model.noticeDetails, "The operation couldn’t be completed. (NSCocoaErrorDomain error 640.)")

        model.say("Allow Daybook to use the microphone in Settings.", fix: .openSettings)
        XCTAssertNil(model.noticeDetails, "a new notice doesn't keep the last one's details")
        XCTAssertEqual(model.noticeFix, .openSettings)

        model.dismissNotice()
        XCTAssertNil(model.notice)
        XCTAssertNil(model.noticeFix)
    }

    func testRecordingProblemsKeepTheirInternalsForDetails() {
        let stopped = PlainError.message(for: PhoneRecorderError.encoderUnavailable("join convert"), fallback: "Try again.")
        XCTAssertEqual(stopped.message, "Recording couldn’t continue. Everything up to then is saved.")
        XCTAssertEqual(stopped.details, "The audio encoder stopped (join convert).")
        // A Shortcut, the control, or a Live Activity button gets a sentence of Daybook's own, never the system's words.
        func said(_ error: RecordingCommandError) -> String { String(localized: error.localizedStringResource) }
        XCTAssertEqual(said(PhoneAppModel.commandFailure(PhoneRecorderError.encoderUnavailable("convert"), starting: true)),
                       "Couldn’t start recording. Open Daybook to try again.")
        XCTAssertEqual(said(PhoneAppModel.commandFailure(CocoaError(.fileWriteOutOfSpace), starting: false)),
                       "Couldn’t resume recording. Open Daybook to try again.")
        XCTAssertEqual(said(PhoneAppModel.commandFailure(PhoneRecorderError.noMicrophone, starting: true)), "No microphone is available.")
        XCTAssertEqual(said(PhoneAppModel.commandFailure(PhoneRecorderError.microphoneDenied, starting: true)),
                       "Allow Daybook to use the microphone in Settings.")
        // Sync and audio errors of Daybook's own are shown as they are.
        XCTAssertEqual(PlainError.message(for: LibrarySyncError.keyAvailable, fallback: "Try again.").message,
                       "One of your devices has this library’s key. Get the key from it instead.")
        XCTAssertEqual(PlainError.message(for: AudioFetchError.keyUnavailable, fallback: "Try again.").message,
                       "This recording plays once this device has the library’s key.")
        XCTAssertEqual(PlainError.message(for: AudioFetchError.downloadFailed("The network connection was lost."), fallback: "Try again.").message,
                       "Try again.")
    }

    func testDetailsThatOnlyRepeatTheMessageAreLeftOut() throws {
        let model = try makeModel()
        model.say("No audio was recorded.", details: "No audio was recorded.")
        XCTAssertNil(model.noticeDetails)
        model.say("Recording stopped. Everything up to then is saved.", details: "")
        XCTAssertNil(model.noticeDetails)
    }

    func testAMicrophoneThatIsntAllowedOffersSettings() async throws {
        let rig = RecorderRig()
        rig.session.permission = false
        let model = try makeModel(rig: rig)
        do { try await model.startRecording(); XCTFail("started without permission") } catch {}
        XCTAssertEqual(model.notice, "Allow Daybook to use the microphone in Settings.")
        XCTAssertEqual(model.noticeFix, .openSettings)
        XCTAssertNil(model.noticeDetails)
    }

    func testAJournalThatCantBeWrittenSaysWhatToDo() {
        let full = PhoneAppModel.recorderWarning(PhoneRecorder.journalWarning + ": The file couldn’t be saved because there isn’t enough space.")
        XCTAssertEqual(full?.message, "Notes and bookmarks aren’t being saved as you go. Free up space on this iPhone.")
        XCTAssertEqual(full?.details, "The file couldn’t be saved because there isn’t enough space.")

        let other = PhoneAppModel.recorderWarning(PhoneRecorder.journalWarning + ": You don’t have permission.")
        XCTAssertEqual(other?.message, "Notes and bookmarks aren’t being saved as you go.")
        XCTAssertEqual(other?.details, "You don’t have permission.")

        XCTAssertNil(PhoneAppModel.recorderWarning(nil))
        XCTAssertNil(PhoneAppModel.recorderWarning(""))
    }

    func testTheRecordersJournalWarningIsWhatTheRecordingScreenReads() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Full disk")
        rig.pump(2)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        rig.recorder.editNotes("A note the journal can't hold")
        await rig.recorder.flush()
        await rig.recorder.flush()
        let warning = try XCTUnwrap(PhoneAppModel.recorderWarning(rig.recorder.lastError))
        XCTAssertTrue(warning.message.hasPrefix("Notes and bookmarks aren’t being saved as you go."), warning.message)
        let details = try XCTUnwrap(warning.details)
        XCTAssertFalse(warning.message.contains(details), "the system's words stay behind Details")
    }

    func testDaybooksOwnErrorsAreShownAndTheSystemsGoBehindDetails() {
        let offline = PlainError.message(for: AudioProvidingError.offline, fallback: "Try again.")
        XCTAssertEqual(offline.message, "The audio isn’t on this iPhone yet. It downloads when you’re online.")
        XCTAssertNil(offline.details)

        let system = PlainError.message(for: CocoaError(.fileWriteOutOfSpace), fallback: "The audio couldn’t be prepared. Try again.")
        XCTAssertEqual(system.message, "The audio couldn’t be prepared. Try again.")
        XCTAssertNotNil(system.details)

        let alert = ReadingAlert(title: "Couldn’t Share", error: CocoaError(.fileWriteOutOfSpace), fallback: "Try again.")
        XCTAssertEqual(alert.title, "Couldn’t Share")
        XCTAssertEqual(alert.message, "Try again.")
        XCTAssertEqual(alert.details, CocoaError(.fileWriteOutOfSpace).localizedDescription)
    }
}
