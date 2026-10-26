import DaybookIntelligence
import DaybookKit
import SwiftUI

/// Add Model: a Hugging Face repository (and optionally a revision or folder) is checked by every
/// engine this Daybook has; what would be added is shown before anything is written, and adding
/// downloads it. Whatever engines exist decide what can be added, so new engines need nothing here.
struct AddModelSheet: View {
    @ObservedObject var manager: ModelManager
    var initialText = ""
    var checksImmediately = false
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case editing, checking, proposal, adding }

    @State private var repositoryText = ""
    @State private var revision = ""
    @State private var folder = ""
    @State private var phase = Phase.editing
    @State private var input: ModelRepositoryInput?
    @State private var preview: ModelAdditionPreview?
    @State private var candidateID = ""
    @State private var name = ""
    @State private var familyID = ""
    @State private var problem: String?
    /// The system's words for `problem`, behind Details.
    @State private var problemDetails: String?
    @State private var showingDetails = false
    @State private var rejections: [ModelAdditionPreview.Rejection] = []
    /// The fields as they were checked; editing them makes the result stale.
    @State private var checkedFields = ""

    private var fields: String { "\(repositoryText)|\(revision)|\(folder)" }

    private var candidate: ModelAdditionPreview.Candidate? {
        preview?.candidates.first { $0.id == candidateID } ?? preview?.candidates.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Model")
                .font(.headline)
                .padding(.horizontal, Space.s5)
                .padding(.top, Space.s5)
            Form {
                Section {
                    TextField("Repository", text: $repositoryText, prompt: Text("owner/name or link"))
                    TextField("Revision", text: $revision, prompt: Text("main"))
                    TextField("Folder", text: $folder, prompt: Text("Optional"))
                }
                .disabled(phase == .checking || phase == .adding)
                if let problem { problemSection(problem) }
                if phase == .proposal || phase == .adding, let preview, let candidate { proposal(preview, candidate) }
            }
            .formStyle(.grouped)
            .frame(minHeight: phase == .proposal || phase == .adding ? 420 : nil)
            footer
        }
        .frame(width: 520)
        .onChange(of: repositoryText) { _, _ in invalidate() }
        .onChange(of: revision) { _, _ in invalidate() }
        .onChange(of: folder) { _, _ in invalidate() }
        .task {
            guard !initialText.isEmpty, repositoryText.isEmpty else { return }
            repositoryText = initialText
            if checksImmediately { await check() }
        }
    }

    // MARK: Parts

    /// A problem in one sentence; anything the system said goes behind Details.
    private func show(_ error: Error) {
        let addition = error as? ModelAdditionProblem
        problem = addition?.message ?? "Couldn’t add the model. Try again."
        problemDetails = addition == nil ? error.localizedDescription : addition?.details
    }

    private func problemSection(_ problem: String) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning)
                }
                if let problemDetails {
                    Spacer(minLength: Space.s3)
                    Button("Details…") { showingDetails = true }
                        .popover(isPresented: $showingDetails) {
                            Text(problemDetails).textSelection(.enabled).padding(Space.s4).frame(maxWidth: 360, alignment: .leading)
                        }
                }
            }
            ForEach(Self.grouped(rejections), id: \.engine) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.engine).font(.subheadline.weight(.semibold))
                    Text(group.reasons.joined(separator: " "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func proposal(_ preview: ModelAdditionPreview, _ candidate: ModelAdditionPreview.Candidate) -> some View {
        Section {
            TextField("Name", text: $name)
            if preview.candidates.count > 1 {
                Picker("Use for", selection: $candidateID) {
                    ForEach(preview.candidates) { option in Text("\(option.role.title) · \(option.engine.name)").tag(option.id) }
                }
            } else {
                LabeledContent("Use for", value: candidate.role.title)
            }
            Picker("Family", selection: $familyID) {
                Text("New family").tag("")
                ForEach(families(for: candidate), id: \.id) { family in Text(family.name).tag(family.id) }
            }
            LabeledContent("Runs with", value: "\(candidate.engine.name) · \(candidate.engine.runtime)")
            LabeledContent("Commit") {
                Text([String(preview.commit.id.prefix(7)), preview.commit.date?.formatted(date: .abbreviated, time: .omitted)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .monospacedDigit()
            }
            LabeledContent("License") {
                HStack(spacing: 6) {
                    if let url = URL(string: preview.license.url), !preview.license.url.isEmpty {
                        Link(preview.license.name, destination: url).buttonStyle(.daybookLink)
                    } else {
                        Text(preview.license.name)
                    }
                    if !preview.license.allowsCommercialUse { ModelLabelChip("Non-commercial") }
                }
            }
            if let memory = candidate.proposal.recommendedMemoryGB {
                LabeledContent("Memory", value: "\(memory) GB or more")
            }
            if !candidate.proposal.capabilities.descriptions.isEmpty {
                LabeledContent("Capabilities", value: candidate.proposal.capabilities.descriptions.joined(separator: " · "))
            }
            DisclosureGroup {
                ForEach(candidate.files, id: \.path) { file in
                    HStack {
                        Text(file.path).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.s3)
                        Text(ModelSize.format(file.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            } label: {
                LabeledContent("Download") {
                    Text("\(candidate.files.count == 1 ? "1 file" : "\(candidate.files.count) files") · \(ModelSize.format(candidate.bytes))")
                        .monospacedDigit()
                }
            }
            if let duplicate = candidate.duplicateOf {
                Label {
                    Text("Already in your models as \(duplicate).")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning)
                }
            }
        } header: {
            Text(preview.repository)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.s2) {
            if phase == .checking || phase == .adding {
                ProgressView().controlSize(.small)
                Text(phase == .checking ? "Checking…" : "Adding…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if phase == .proposal || phase == .adding {
                Button("Add and Download") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase == .adding || candidate?.duplicateOf != nil
                              || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button("Check") { Task { await check() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase == .checking || repositoryText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s4)
    }

    // MARK: Actions

    private func check() async {
        guard var parsed = ModelRepositoryInput(repositoryText) else {
            problem = "Enter a Hugging Face repository as owner/name, or paste its link."; problemDetails = nil
            rejections = []
            return
        }
        // A pasted link to a branch or folder fills those in.
        if revision.isEmpty, let linked = parsed.revision { revision = linked }
        if folder.isEmpty, let linked = parsed.folder { folder = linked }
        let trimmedRevision = revision.trimmingCharacters(in: .whitespaces)
        let trimmedFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        parsed.revision = trimmedRevision.isEmpty ? nil : trimmedRevision
        parsed.folder = trimmedFolder.isEmpty ? nil : trimmedFolder
        checkedFields = fields
        phase = .checking
        problem = nil; problemDetails = nil
        rejections = []
        do {
            let result = try await manager.preview(parsed)
            input = parsed
            guard let first = result.candidates.first else {
                problem = "This Daybook can’t run \(parsed.repository)\(parsed.folder.map { "/\($0)" } ?? "")."
                rejections = result.rejections
                phase = .editing
                return
            }
            preview = result
            candidateID = first.id
            familyID = first.familyID ?? ""
            name = parsed.suggestedName
            phase = .proposal
        } catch {
            show(error)
            phase = .editing
        }
    }

    private func add() async {
        guard let preview, var chosen = candidate, let input else { return }
        let family = families(for: chosen).first { $0.id == familyID }
        chosen.familyID = family?.id
        chosen.familyName = family?.name
        phase = .adding
        problem = nil; problemDetails = nil
        do {
            try await manager.add(chosen, from: preview, name: name, input: input)
            dismiss()
        } catch {
            show(error)
            phase = .proposal
        }
    }

    /// A changed field makes the proposal stale.
    private func invalidate() {
        guard phase == .proposal || problem != nil, fields != checkedFields else { return }
        phase = .editing
        preview = nil
        problem = nil; problemDetails = nil
        rejections = []
    }

    /// Families whose models this engine runs for this role: the model can join one of them.
    private func families(for candidate: ModelAdditionPreview.Candidate) -> [(id: String, name: String)] {
        var seen = Set<String>()
        return manager.state.modelCatalog.models
            .filter { $0.engine == candidate.engine.id && $0.serves(candidate.role) }
            .compactMap { seen.insert($0.familyID).inserted ? ($0.familyID, $0.familyName) : nil }
    }

    /// Each engine's reasons once, even when it serves several roles.
    static func grouped(_ rejections: [ModelAdditionPreview.Rejection]) -> [(engine: String, reasons: [String])] {
        var result: [(engine: String, reasons: [String])] = []
        for rejection in rejections {
            if let index = result.firstIndex(where: { $0.engine == rejection.engine.name }) {
                result[index].reasons += rejection.reasons.filter { !result[index].reasons.contains($0) }
            } else {
                result.append((rejection.engine.name, rejection.reasons))
            }
        }
        return result
    }
}
