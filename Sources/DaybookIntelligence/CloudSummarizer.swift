import DaybookCore
import DaybookKit
import Foundation

/// Summarizes a conversation with a cloud model (docs/cloud.md, "The summary"): `CloudSynthesis`'s single pass,
/// streamed, with the reply's limit raised once when it runs into it, and the provider and model, tokens, estimated
/// cost, and sending device recorded in the summary's provenance. Only the transcript text, the notes and bookmarks,
/// the template, and the vocabulary are sent: never audio, photos, or voiceprints.
public struct CloudSummarizer: CloudSummarizing {
    public let directory: CloudDirectory
    /// The device sending the conversation, for provenance: "Vlad's MacBook Pro".
    public var deviceName: String?

    public init(directory: CloudDirectory, deviceName: String? = nil) {
        self.directory = directory
        self.deviceName = deviceName
    }

    /// A summary with what came with it: suggested vocabulary terms, warnings to show, and its provenance.
    public struct Result: Sendable {
        public var summary: MeetingSummary
        public var suggestedTerms: [String]
        public var warnings: [String]
        public var provenance: CloudProvenance
    }

    public func availableModels(refresh: Bool) async -> [CloudModel] {
        await directory.offers(refresh: refresh).map(\.model)
    }

    public func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel,
                          effort: CloudEffort, progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary {
        try await summary(meeting, template: template, vocabulary: vocabulary, model: model, effort: effort, progress: progress).summary
    }

    public func summary(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel,
                        effort wanted: CloudEffort, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let source = MeetingEvidence.summarySource(meeting)
        guard !source.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DaybookError.noSpeech }
        guard let key = try directory.keys.key(for: model.provider) else { throw CloudError.noKey(model.provider) }
        progress(0.02)
        let catalog = directory.catalog
        let offers = await directory.currentOffers()
        let offer = offers.offer(model.id, provider: model.provider)
            ?? CloudOffer(model: model, price: model.inputPrice.map { CloudPrice(input: $0, output: model.outputPrice ?? 0) })
        let effort = offer.effort(wanted)
        let kind = template?.kind ?? meeting.kind
        let built = CloudSynthesis.prompt(source: source, template: kind, glossary: vocabulary, templateInstructions: template?.instructions,
                                          provider: model.provider, catalog: catalog)

        // How much it should write, for the limit and for progress while it streams.
        let minutes = Self.minutes(meeting)
        let expected = catalog.expectedOutputTokens(model.id, provider: model.provider, minutes: minutes, effort: effort)
        let ceiling = max(1_024, offer.maxOutputTokens)
        let expectedCharacters = Double(expected) * catalog.provider(model.provider).visibleCharactersPerOutputToken
        let reported = ProgressGate(progress)
        let received: @Sendable (Int) -> Void = { characters in
            reported.report(0.05 + 0.9 * min(1, Double(characters) / max(1, expectedCharacters)))
        }
        var request = CloudRequest(provider: model.provider, model: model.id, modelName: model.name, instructions: built.instructions,
                                   prompt: built.prompt, schema: offer.structuredOutputs ? built.schema : nil,
                                   maxOutputTokens: min(ceiling, max(16_000, expected * 2 + 8_000)), effort: effort,
                                   refusalFallback: offer.refusalFallback)
        var reply = try await directory.client.respond(request, key: key, received: received)
        if reply.stop == .lengthCap {
            // A long conversation can outrun the estimate: once more, with all the model can write.
            guard request.maxOutputTokens < ceiling else {
                throw CloudError.tooLong(model: model.name, details: "stop: max output tokens (\(request.maxOutputTokens))")
            }
            request.maxOutputTokens = ceiling
            reply = try await directory.client.respond(request, key: key, received: received)
            guard reply.stop == .complete else {
                throw CloudError.tooLong(model: model.name, details: "stop: max output tokens (\(request.maxOutputTokens))")
            }
        }
        try Task.checkCancellation()

        // The model that wrote it: a refusal fallback can name another.
        let writer = reply.model.isEmpty || reply.model == model.id || reply.model.hasPrefix(model.id + "-")
            ? offer : offers.offer(reply.model, provider: model.provider)
        let writerID = writer?.id ?? reply.model
        let writerName = writer?.model.name ?? catalog.name(reply.model, provider: model.provider)?.displayName ?? reply.model
        var price = writer?.price
        if writer == nil, let name = catalog.name(reply.model, provider: model.provider) { price = await directory.prices[name.openRouterID]?.price }
        let provenance = CloudProvenance(provider: model.provider, model: writerID, name: writerName, effort: effort,
                                         inputTokens: reply.inputTokens, outputTokens: reply.outputTokens,
                                         estimatedCost: price?.cost(inputTokens: reply.inputTokens, outputTokens: reply.outputTokens),
                                         priceIsEstimated: writer?.model.priceIsEstimated ?? false, sentBy: deviceName)

        let notes = CloudSynthesis.notes(reply.text, prompt: built, template: kind, modelID: provenance.modelID)
        var summary = PhotoPlacement.arrange(notes.summary, in: meeting)
        var parameters = provenance.parameters
        parameters["templateID"] = template?.id ?? "auto"
        parameters["templateInstructions"] = template?.instructions ?? "Automatic selection"
        summary.modelID = provenance.modelID
        summary.processingSettings = ProcessingSettings(modelID: provenance.modelID, parameters: parameters, model: provenance.modelProvenance)
        progress(1)
        return Result(summary: summary, suggestedTerms: notes.suggestedTerms, warnings: notes.warnings, provenance: provenance)
    }

    /// What summarizing `meeting` with `model` should cost, in USD, before it's sent: the prompt's own length in the
    /// provider's tokens, and what the model is expected to write for a conversation this long; nil without a price.
    public func estimatedCost(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel,
                              effort: CloudEffort) async -> Double? {
        let catalog = directory.catalog
        let offer = await directory.currentOffers().offer(model.id, provider: model.provider)
        guard let price = offer?.price ?? model.inputPrice.map({ CloudPrice(input: $0, output: model.outputPrice ?? 0) }) else { return nil }
        let built = CloudSynthesis.prompt(source: MeetingEvidence.summarySource(meeting), template: template?.kind ?? meeting.kind,
                                          glossary: vocabulary, templateInstructions: template?.instructions, provider: model.provider, catalog: catalog)
        let input = catalog.estimatedTokens(built.instructions + built.prompt + built.schema, provider: model.provider)
        let output = catalog.expectedOutputTokens(model.id, provider: model.provider, minutes: Self.minutes(meeting),
                                                  effort: offer?.effort(effort) ?? effort)
        return price.cost(inputTokens: input, outputTokens: output)
    }

    /// The conversation's length in minutes, from its transcript.
    static func minutes(_ meeting: Meeting) -> Double {
        guard let first = meeting.unifiedTranscript.map(\.start).min(), let last = meeting.unifiedTranscript.map(\.end).max() else { return 0 }
        return max(0, last - first) / 60
    }
}

/// Passes progress on only when it moves by a percent or more, and never backwards: a reply streams in
/// hundreds of pieces a second.
private final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func report(_ fraction: Double) {
        let value = min(0.95, fraction)
        let send: Bool = lock.withLock {
            guard value >= last + 0.01 else { return false }
            last = value
            return true
        }
        if send { report(value) }
    }
}
