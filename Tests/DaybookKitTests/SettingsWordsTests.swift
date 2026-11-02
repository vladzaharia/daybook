import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// Settings' words, written once: the same model is the same size, the same vocabulary the same count, and each
/// label is one sentence-case string the iPhone title-cases where it draws it.
final class SettingsWordsTests: XCTestCase {
    func testBehaviorEachRoleHasOneName() {
        XCTAssertEqual(SettingsWords.role(.speakerEmbedding), "Voice profiles")
        XCTAssertEqual(SettingsWords.role(.liveTranscription), "Live transcription")
        XCTAssertEqual(ModelRole.diarization.displayName, "Speakers")
        XCTAssertEqual(SettingsWords.roleSubject(.diarization), "Speaker detection")
        XCTAssertEqual(SettingsWords.role(ModelRole("imageCaptions")), "Image captions", "a newer catalog's role in words")
        XCTAssertEqual(SettingsWords.words("image_captions"), "Image captions")
    }

    func testBehaviorCloudWords() {
        XCTAssertEqual(SettingsWords.provider(.anthropic), "Anthropic")
        XCTAssertEqual(SettingsWords.provider(.openai), "OpenAI")
        XCTAssertEqual(CloudTier.allCases.map(SettingsWords.tier), ["Best", "Balanced", "Economy"])
        XCTAssertEqual(CloudEffort.allCases.map(SettingsWords.effort), ["Low", "Medium", "High"])
        XCTAssertEqual(SettingsWords.policy(.ask), "Offer first")
        XCTAssertEqual(SettingsWords.policy(.never), "Never")
        XCTAssertEqual(SettingsWords.seconds(15), "15 seconds")
    }

    func testBehaviorVoiceprintOrigins() {
        XCTAssertEqual(SettingsWords.origin(.named), "Named")
        XCTAssertEqual(SettingsWords.origin(.confirmed), "Confirmed")
        XCTAssertEqual(SettingsWords.origin(.recognized), "Learned")
    }

    func testBehaviorOneSizeForTheSameModel() {
        XCTAssertEqual(ByteSize.format(632_200_000), "632 MB", "never 632.2 MB on one device and 632 MB on the other")
        XCTAssertEqual(ByteSize.format(1_600_000_000), "1.6 GB")
        XCTAssertEqual(ByteSize.format(400_000), "1 MB")
        XCTAssertEqual(ByteSize.format(0), "0 MB")
        XCTAssertEqual(ByteSize.progress(120_000_000, of: 632_000_000), "120 of 632 MB")
        XCTAssertEqual(ByteSize.progress(400_000_000, of: 1_600_000_000), "0.4 of 1.6 GB")
    }

    func testBehaviorCountsCountTheSameThings() {
        let approved = GlossaryTerm(term: "Daybook", approved: true)
        // A term from one conversation is used there (GlossaryStore.terms(for:)), so it's counted as a term.
        let fromAConversation = GlossaryTerm(term: "Sortformer", approved: false, sourceMeetingIDs: [UUID()])
        XCTAssertEqual(SettingsWords.vocabulary([]), "No terms yet")
        XCTAssertEqual(SettingsWords.vocabulary([fromAConversation, fromAConversation, fromAConversation]), "3 terms",
                       "terms from conversations aren't hidden behind No terms")
        XCTAssertEqual(SettingsWords.vocabulary([approved]), "1 term")
        XCTAssertEqual(SettingsWords.vocabulary([approved, approved, fromAConversation]), "3 terms")
        XCTAssertEqual(SettingsWords.profiles(0), "No profiles yet")
        XCTAssertEqual(SettingsWords.profiles(1), "1 profile")
        XCTAssertEqual(SettingsWords.profiles(4), "4 profiles")
        XCTAssertEqual(SettingsWords.templates(builtIn: 12, yours: 0), "12 built-in")
        XCTAssertEqual(SettingsWords.templates(builtIn: 12, yours: 2), "12 built-in, 2 yours")
        XCTAssertEqual(SettingsWords.templates(SummaryTemplate.builtIns), "\(SummaryTemplate.builtIns.count) built-in")
    }

    func testBehaviorDeviceGlyphs() {
        XCTAssertEqual(SettingsWords.deviceSymbol(.mac, name: "Vlad’s MacBook Pro"), "laptopcomputer")
        XCTAssertEqual(SettingsWords.deviceSymbol(.mac, name: "Studio Mac"), "desktopcomputer")
        XCTAssertEqual(SettingsWords.deviceSymbol(.phone), "iphone")
        XCTAssertEqual(SettingsWords.deviceSymbol(nil), "questionmark.app.dashed")
        XCTAssertEqual(SettingsWords.thisDeviceSymbol(model: "MacBookPro18,3"), "laptopcomputer")
        XCTAssertEqual(SettingsWords.thisDeviceSymbol(model: "Mac14,3", name: "Studio"), "desktopcomputer")
        XCTAssertEqual(SettingsWords.thisDeviceSymbol(model: "Mac15,3", name: "Vlad’s MacBook Air"), "laptopcomputer")
        XCTAssertEqual(SettingsWords.thisDeviceSymbol(model: "iPhone17,1"), "iphone")
        let device = KnownSyncDevice(id: "d", deviceClass: .mac, displayName: "Vlad’s MacBook Pro", isCurrentDevice: false)
        XCTAssertEqual(device.systemImage, "laptopcomputer")
    }

    func testBehaviorTheIPhoneTitleCasesOnce() {
        XCTAssertEqual(SettingsWords.titleCased("Use the cloud"), "Use the Cloud")
        XCTAssertEqual(SettingsWords.titleCased("15 seconds"), "15 Seconds")
        XCTAssertEqual(SettingsWords.titleCased("Create a recovery key"), "Create a Recovery Key")
        XCTAssertEqual(SettingsWords.titleCased("Sync with iCloud"), "Sync with iCloud", "a word's own capitals stay")
        XCTAssertEqual(SettingsWords.titleCased("Voice profiles"), "Voice Profiles")
        XCTAssertEqual(SettingsWords.titleCased("Offer first"), "Offer First")
        XCTAssertEqual(SettingsWords.titleCased("What to sign in to"), "What to Sign in To", "the last word is always capitalized")
        XCTAssertEqual(SettingsWords.titleCased("Third-party notices"), "Third-Party Notices", "each part of a hyphenated word")
        XCTAssertEqual(SettingsWords.titleCased("Also heard as"), "Also Heard As")
        XCTAssertEqual(SettingsWords.titleCased("Wi‑Fi only"), "Wi‑Fi Only", "a non-breaking hyphen's word keeps its capitals")
    }
}
