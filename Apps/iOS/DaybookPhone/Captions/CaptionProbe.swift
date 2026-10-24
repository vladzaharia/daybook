import DaybookCaptions
import AVFoundation
import Foundation
import Speech

/// `--caption-probe [file]` (debug): records what live captions can do on this device to
/// `Documents/caption-probe.json` — availability, languages, the asset status, speech-recognition
/// authorization — and, when the language is already installed, captions `file` without asking for
/// authorization first, to show whether `SpeechTranscriber` needs it. It never downloads anything.
enum CaptionProbe {
    @MainActor
    static func run(file: String?, locale: Locale) async {
        var report: [String: Any] = ["locale": locale.identifier, "date": ISO8601DateFormatter().string(from: Date())]
        report["speechRecognitionAuthorization"] = describe(SFSpeechRecognizer.authorizationStatus())
        do {
            report["isAvailable"] = SpeechTranscriber.isAvailable
            let supported = await SpeechTranscriber.supportedLocales
            report["supportedLocales"] = supported.count
            report["installedLocales"] = await SpeechTranscriber.installedLocales.map(\.identifier)
            let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            report["supportedEquivalent"] = equivalent?.identifier ?? NSNull()
            if let equivalent {
                let status = await AssetInventory.status(forModules: [SpeechCaptioner.transcriber(locale: equivalent)])
                report["assetStatus"] = "\(status)"
                if status == .installed, let file {
                    report["analysis"] = await analyze(URL(fileURLWithPath: file), locale: equivalent)
                    report["speechRecognitionAuthorizationAfter"] = describe(SFSpeechRecognizer.authorizationStatus())
                }
            }
            switch await LiveCaptionAvailability.check(locale: locale) {
            case .ready(let found): report["availability"] = "ready (\(found.identifier))"
            case .needsDownload(let found): report["availability"] = "needs a download (\(found.identifier))"
            case .unavailable(let reason): report["availability"] = reason
            }
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: documents.appendingPathComponent("caption-probe.json"), options: .atomic)
            NSLog("Daybook caption probe: %@", String(decoding: data, as: UTF8.self))
        }
    }

    private static func analyze(_ url: URL, locale: Locale) async -> String {
        do {
            let transcriber = SpeechCaptioner.transcriber(locale: locale)
            let file = try AVAudioFile(forReading: url)
            let collect = Task { () -> String in
                var finals: [String] = []
                for try await result in transcriber.results where result.isFinal { finals.append(String(result.text.characters)) }
                return finals.joined(separator: " ")
            }
            _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
            let text = try await collect.value
            return "ok: \(text)"
        } catch {
            return "error: \(error)"
        }
    }

    private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }
}
