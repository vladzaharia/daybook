import Foundation

public struct SummaryTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    @Extensible public var kind: MeetingKind
    public var instructions: String
    public var updatedAt: Date

    public init(id: String = "custom-" + UUID().uuidString.lowercased(), name: String,
                kind: MeetingKind = .general, instructions: String, updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind
        self.instructions = instructions; self.updatedAt = updatedAt
    }

    /// Stable IDs allow a user's edited version to override the built-in format.
    public static let builtIns: [SummaryTemplate] = [
        standard("general", "Meeting notes", .general, """
        Purpose: help someone remember a conversation and act on what was agreed.
        Write a concise overview followed by Topics discussed, Decisions, Open questions, and Next steps. Use short paragraphs or concrete bullets. Keep names, dates, quantities, and tradeoffs when stated. Give an action an owner or deadline only when the conversation supplies one. Treat personal notes and marked moments as priorities, and include extra surrounding context for those moments. Distinguish proposals from decisions and uncertainty from fact.
        """),
        standard("one-on-one", "1:1", .oneOnOne, """
        Purpose: remember the support, feedback, and commitments from a one-on-one.
        Organize the notes into Check-in, Progress and challenges, Feedback, Support needed, and Commitments. Prefer a clear, respectful tone and moderate detail. Preserve concrete examples and different perspectives without assigning motives. Attribute feedback only when the speaker is known. Highlight follow-up questions and promised help; do not turn casual suggestions into commitments. Give extra detail to topics marked in the user's notes.
        """),
        standard("scrum", "Daily standup", .scrum, """
        Purpose: show the team's current work and what needs coordination today.
        Keep the result brief. Use Progress, Next work, Blockers and dependencies, and Follow-ups. Group by person only when speaker identity is supported; otherwise group by work item. Retain ticket names, delivery dates, and dependencies mentioned. Separate an actual blocker from a possible risk. Omit conversational filler while preserving decisions and explicit requests for help.
        """),
        standard("therapy-reflection", "Therapy reflection", .therapy, """
        Purpose: help the person revisit their own therapy conversation with care.
        Use gentle, plain language and the sections What felt important, Feelings and experiences discussed, Perspectives explored, Practices or experiments discussed, and Things to revisit. Reflect the person's own words and retain uncertainty. Record exercises only as discussed in the session, with no new recommendations. Do not infer diagnoses, hidden motives, treatment plans, or clinical conclusions. Distinguish the person's account from another speaker's suggestions. Expand on user-marked moments without judging them.
        """),
        standard("personal", "Personal conversation", .personal, """
        Purpose: remember a meaningful conversation without turning it into a work report.
        Use a warm, natural tone. Include What we talked about, Moments to remember, Plans and promises, and Things to follow up on. Preserve names, stories, preferences, and important feelings when explicitly expressed. Keep casual discussion separate from commitments. Use only supported speaker attribution. Give the user's notes and highlights space, and avoid speculative interpretations of relationships or intentions.
        """),
        standard("interview", "Interview", .interview, """
        Purpose: retain the evidence and open questions from an interview.
        Organize into Context, Questions and responses, Concrete examples, Themes, and Follow-up questions. Focus on what the interviewee actually described. Keep relevant quotations short and faithful, and preserve the surrounding context. Separate observed evidence from the interviewer's interpretation. Do not invent evaluations or scores. Include unanswered questions and contradictions as unresolved rather than smoothing them away.
        """),
        standard("lecture", "Lecture or learning", .lecture, """
        Purpose: make the material useful to review and study later.
        Start with the main idea, then use Key concepts, Explanations and examples, Connections, and Questions to explore. Keep enough detail to explain how the ideas fit together. Preserve important definitions, formulas stated in words, references, and examples from the recording. Mark unclear or incomplete material instead of filling gaps from general knowledge. Bring user-written questions and highlighted explanations into the relevant sections.
        """),
        standard("planning", "Planning session", .general, """
        Purpose: capture a workable plan and the assumptions behind it.
        Use Goal and constraints, Options considered, Agreed plan, Dependencies and risks, and Next checkpoints. Retain scope, sequencing, estimates, and tradeoffs explicitly discussed. Separate committed dates from guesses and decisions from options still under consideration. List owners only when assigned. Expand highlighted decisions enough to explain their rationale and any conditions that would change them.
        """),
        standard("retrospective", "Retrospective", .general, """
        Purpose: preserve learning from a shared experience and the changes people agreed to try.
        Use What happened, What helped, What was difficult, Lessons, and Experiments for next time. Keep the tone factual and non-blaming. Include concrete examples before broader themes. Preserve differing views and unresolved questions. Distinguish proposed improvements from agreed experiments, and record how an experiment will be reviewed only when discussed.
        """),
        standard("customer-discovery", "Customer discovery", .interview, """
        Purpose: understand a customer's actual situation, needs, and current behavior.
        Use Context and workflow, Problems and impact, Current alternatives, Reactions and evidence, and Questions to validate. Prioritize concrete stories, frequency, costs, and workarounds described by the customer. Separate their requests from assumptions made by the interviewer. A positive reaction is not proof of willingness to buy. Retain uncertainty, contradictions, and useful short quotes with their context.
        """),
        standard("design-review", "Design review", .general, """
        Purpose: retain design reasoning and the changes agreed during a review.
        Use Problem and audience, Approach reviewed, Feedback and tradeoffs, Decisions, and Revisions to make. Separate usability evidence from personal preference. Preserve constraints, accessibility concerns, alternatives, and open questions when raised. Associate feedback with the relevant part of the design. Do not claim a mockup, screenshot, or interaction was observed unless that information is present in the supplied material.
        """),
        standard("decision-memo", "Decision memo", .general, """
        Purpose: create a record of a decision that someone can understand later.
        Use Decision, Context, Alternatives considered, Rationale, Consequences and risks, and Follow-through. State explicitly when no final decision was reached. Preserve dissent, conditions, and uncertainties. Include evidence mentioned in the conversation without adding outside facts. Keep rationale specific enough to explain why the chosen option fit the stated constraints. Record ownership and review dates only when agreed.
        """)
    ]

    /// De-duplicates by stable ID, retaining the most recently edited version.
    /// Custom entries override built-ins, including edited built-in IDs.
    public static func catalog(templates: [SummaryTemplate]) -> [SummaryTemplate] {
        var values = Dictionary(uniqueKeysWithValues: builtIns.map { ($0.id, $0) })
        for template in templates {
            if let existing = values[template.id], existing.updatedAt > template.updatedAt { continue }
            values[template.id] = template
        }
        let order = Dictionary(uniqueKeysWithValues: builtIns.enumerated().map { ($0.element.id, $0.offset) })
        return values.values.sorted {
            let left = order[$0.id] ?? Int.max, right = order[$1.id] ?? Int.max
            if left != right { return left < right }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    public static func resolved(id: String?, kind: MeetingKind, templates: [SummaryTemplate]) -> SummaryTemplate {
        let catalog = catalog(templates: templates)
        if let id, let selected = catalog.first(where: { $0.id == id }) { return selected }
        let defaultID: String
        switch kind {
        case .auto, .general: defaultID = "general"
        case .oneOnOne: defaultID = "one-on-one"
        case .scrum: defaultID = "scrum"
        case .therapy: defaultID = "therapy-reflection"
        case .personal: defaultID = "personal"
        case .interview: defaultID = "interview"
        case .lecture: defaultID = "lecture"
        }
        return catalog.first(where: { $0.id == defaultID }) ?? builtIns[0]
    }

    public var isBuiltIn: Bool { Self.builtIns.contains(where: { $0.id == id }) }

    public func duplicated() -> SummaryTemplate {
        SummaryTemplate(name: name + " copy", kind: kind, instructions: instructions)
    }

    private static func standard(_ id: String, _ name: String, _ kind: MeetingKind, _ instructions: String) -> SummaryTemplate {
        SummaryTemplate(id: id, name: name, kind: kind, instructions: instructions,
                        updatedAt: Date(timeIntervalSince1970: 0))
    }
}
