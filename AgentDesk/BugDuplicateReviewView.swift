#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import AgentDeskRuntime
import AgentDeskPersistence
import AgentDeskSecurity
import SwiftUI
import AppKit

struct BugDuplicateReviewView: View {
    @StateObject private var context: ProjectRunContextModel
    @StateObject private var session = NativeBugReviewSession()
    private let openServices: () async throws -> ProjectNativeServices
    @State private var showAmbiguity = false
    @State private var actionError: String?
    @State private var availableHeight: CGFloat = 640
    let incomingID: BugID
    @Environment(\.dismiss) private var dismiss
    init(project: ProjectRecord, incomingID: BugID, open: @escaping () async throws -> ProjectNativeServices) {
        self.incomingID = incomingID; self.openServices = open
        _context = StateObject(wrappedValue: ProjectRunContextModel(project: project, open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Duplicate Review").font(.title2).bold().accessibilityIdentifier("bug.review.title")
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("bug.review.done")
            }
            Text(context.project.name).foregroundStyle(.secondary)
            if let error = actionError ?? context.errorMessage ?? session.error { Text(error).foregroundStyle(.orange) }
            if session.model == nil {
                Picker("Agent", selection: $context.selectedAgentID) {
                    Text("Choose agent").tag(AgentID?.none)
                    ForEach(context.agents, id: \.id) { Text($0.definition.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("bug.review.agent")
                Picker("Environment", selection: $context.selectedEnvironmentID) {
                    Text("Choose environment").tag(EnvironmentID?.none)
                    ForEach(context.environments) { Text($0.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("bug.review.environment")
                Button("Review Context") { Task { await context.preview() } }.accessibilityIdentifier("bug.review.context")
                    .disabled(context.isBusy || session.busy || context.selectedAgentID == nil || context.selectedEnvironmentID == nil)
                if let preview = context.presentation {
                    Text("\(preview.agentName) · \(preview.environmentName)")
                    Button("Compare Current Evidence") { Task { await session.open(using: context, incomingID: incomingID) } }
                        .disabled(session.busy).accessibilityIdentifier("bug.review.compare")
                }
                Text("Uses current requirements and verified local evidence. Deterministic comparison does not start Codex.").font(.caption)
            }
            if session.busy { ProgressView("Verifying current context…") }
            if let model = session.model {
                Button("Change Context") { Task { await session.close() } }
                if model.review?.matches.contains(where: { $0.result.classification == .possibleDuplicate }) == true {
                    Button("Review Ambiguity with Codex") {
                        actionError = nil
                        Task {
                            do {
                                _ = try await model.currentReview()
                                await session.close()
                                showAmbiguity = true
                            } catch { actionError = "Refresh the current evidence before preparing a Codex review." }
                        }
                    }.disabled(model.busy).accessibilityIdentifier("bug.ambiguity.open")
                }
                BugComparisonContentView(model: model)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20).macEditorLayout(idealWidth: 960, idealHeight: 640)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .sheet(isPresented: $showAmbiguity) {
            ProjectRunConsoleView(project: context.project, bugReviewID: incomingID,
                selectedAgentID: context.selectedAgentID, selectedEnvironmentID: context.selectedEnvironmentID, open: openServices)
                .frame(height: max(480, min(640, availableHeight - 24)))
        }
        .task { await context.load() }
        .onDisappear { Task { await session.close() } }
    }
}

private struct BugComparisonContentView: View {
    @ObservedObject var model: NativeBugReviewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Refresh Comparison") { Task { await model.load() } }.disabled(model.busy)
            if model.busy { ProgressView("Verifying evidence…") }
            if let error = model.error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("bug.review.error") }
            if let decision = model.decision {
                ScrollView {
                    GroupBox("Review Decision") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Proposed bug version \(decision.proposedRevision)").bold()
                            Text("\(decision.decision.resolution.rawValue.capitalized) · existing bug \(decision.decision.existingID)")
                            Text("Source v\(decision.decision.sourceRevision) · existing v\(decision.decision.existingRevision)")
                            Text(verbatim: decision.decision.reason)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }.accessibilityIdentifier("bug.review.scroll")
                HStack {
                    Button("Back") { Task { await model.discardDecision() } }
                    Button("Save Reviewed Decision") { Task { await model.publishResolution() } }
                        .accessibilityIdentifier("bug.decision.publish")
                }.disabled(model.busy)
            } else if let review = model.review {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let readiness = review.readiness { Text(readiness.reviewTitle).bold().foregroundStyle(.orange) }
                        ForEach(review.matches, id: \.existingID) { match in
                            GroupBox(match.result.classification.reviewTitle) {
                                VStack(alignment: .leading) {
                                    Text("Existing bug: \(match.existingID)")
                                    Text(match.result.reason)
                                    if let resolution = review.recordedResolution(for: match.existingID) {
                                        Text("Recorded user decision: \(resolution.rawValue.capitalized)").bold()
                                    }
                                    if !match.result.matchingFields.isEmpty { Text("Matching fields: \(match.result.matchingFields.joined(separator: ", "))") }
                                    if !match.result.differingFields.isEmpty { Text("Different fields: \(match.result.differingFields.joined(separator: ", "))") }
                                    if review.readiness == nil { BugDecisionControls(model: model, existingID: match.existingID) }
                                    if review.readiness == nil, review.registeredCandidateIDs.contains(match.existingID) {
                                        Button("Prepare Ticket Addition") { Task { await model.prepareTicketAddition(existingID: match.existingID) } }
                                            .disabled(model.busy)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                        }
                        if review.matches.isEmpty { Text("No other records in this environment. This does not by itself verify a new defect.") }
                        if review.readiness == nil {
                            BugReportControls(model: model, candidates: review.matches.filter { !review.registeredCandidateIDs.contains($0.existingID) })
                        }
                        if let draft = model.draft { BugPreparedDraftView(model: model, draft: draft) }
                        DisclosureGroup("Evidence and current requirements") {
                            if let evidence = try? NativeBugReviewEvidence(review) {
                                ForEach(evidence.sources) { source in
                                    BugReviewSourceView(source: source, incoming: source.id == review.incomingID)
                                }
                            } else { Text("The reviewed evidence could not be displayed safely. Refresh the comparison.").foregroundStyle(.orange) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("bug.review.scroll")
            }
        }
    }
}
private struct BugReviewSourceView: View {
    let source: NativeBugReviewEvidence.Source
    let incoming: Bool
    var body: some View {
        GroupBox(incoming ? "Incoming finding" : "Existing candidate") {
            VStack(alignment: .leading, spacing: 10) {
                Text(source.content.title).font(.headline)
                Text("Bug \(source.id) · version \(source.revision)")
                if source.staleRequirements { Text("Recorded requirement associations need review.").foregroundStyle(.orange) }
                if let fields = try? BugPresentation.fields(after: source.content) {
                    ForEach(fields.filter { !["sources", "evidence", "comparisonReview"].contains($0.id) }) { field in
                        VStack(alignment: .leading) { Text(field.title).bold(); Text(verbatim: field.after).textSelection(.enabled) }
                    }
                } else { Text("Finding fields are unavailable.").foregroundStyle(.orange) }
                Text("Source statements").font(.headline)
                ForEach(Array(source.content.sources.enumerated()), id: \.offset) { _, provenance in
                    Text("\(provenance.origin.rawValue): \(provenance.label)")
                }
                ForEach(source.requirements) { requirement in
                    GroupBox("Current requirement: \(requirement.id) v\(requirement.version)") {
                        VStack(alignment: .leading) {
                            if let fields = try? requirement.content.changes(from: nil) {
                                ForEach(fields) { field in
                                    Text(field.field).bold(); Text(verbatim: field.after).textSelection(.enabled)
                                }
                            } else { Text("Requirement fields are unavailable.").foregroundStyle(.orange) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(Array(source.evidence.enumerated()), id: \.offset) { _, artifact in
                    GroupBox("Saved evidence · \(artifact.source.rawValue) · \(artifact.basis.rawValue)") {
                        VStack(alignment: .leading) {
                            Text("Run \(artifact.reference.run) · artifact \(artifact.reference.artifact)").font(.caption)
                            Text(verbatim: artifact.text).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

private struct BugPreparedDraftView: View {
    @ObservedObject var model: NativeBugReviewModel
    let draft: NativeBugDraft
    @State private var copyStatus: String?
    var body: some View {
        GroupBox("Prepared Draft") {
            VStack(alignment: .leading, spacing: 8) {
                Text(draft.title).font(.headline)
                Text(verbatim: draft.text).textSelection(.enabled)
                Text("Local draft only. No ticket has been created or changed.").font(.caption)
                Button("Copy Reviewed Draft") {
                    Task {
                        do {
                            let text = try await model.validatedDraftText()
                            NSPasteboard.general.clearContents()
                            copyStatus = NSPasteboard.general.setString(text, forType: .string) ? "Draft copied." : "Copy failed."
                        } catch { copyStatus = "Refresh and prepare a current draft before copying." }
                    }
                }.disabled(model.busy).accessibilityIdentifier("bug.draft.copy")
                if let copyStatus { Text(copyStatus).font(.caption) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }.onChange(of: draft.text) { copyStatus = nil }
    }
}

private struct BugReportControls: View {
    @ObservedObject var model: NativeBugReviewModel
    let candidates: [BugReviewMatch]
    @State private var expanded = false
    @State private var component: CityPayReportContext.Component?
    @State private var region: CityPayReportContext.Region?
    @State private var area = ""
    @State private var module = ""
    @State private var grouped: Set<BugID> = []
    @State private var problem = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                Label("Prepare CityPay Report", systemImage: expanded ? "chevron.down" : "chevron.right")
            }.accessibilityIdentifier("bug.report.form")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Component", selection: $component) {
                        Text("Choose component").tag(CityPayReportContext.Component?.none)
                        Text("Backend").tag(Optional(CityPayReportContext.Component.backend))
                        Text("Frontend").tag(Optional(CityPayReportContext.Component.frontend))
                    }.accessibilityIdentifier("bug.report.component")
                    Picker("Region", selection: $region) {
                        Text("Choose region").tag(CityPayReportContext.Region?.none)
                        Text("UZ").tag(Optional(CityPayReportContext.Region.uz))
                        Text("GEO").tag(Optional(CityPayReportContext.Region.geo))
                        Text("TR").tag(Optional(CityPayReportContext.Region.tr))
                    }.accessibilityIdentifier("bug.report.region")
                    TextField("Area", text: $area).accessibilityIdentifier("bug.report.area")
                    TextField("Module", text: $module).accessibilityIdentifier("bug.report.module")
                    if !candidates.isEmpty {
                        DisclosureGroup("Group observations of the same root behavior") {
                            ForEach(candidates, id: \.existingID) { candidate in
                                Toggle("Include \(candidate.existingID)", isOn: Binding(get: { grouped.contains(candidate.existingID) }, set: {
                                    if $0 { grouped.insert(candidate.existingID) } else { grouped.remove(candidate.existingID) }
                                })).disabled(grouped.count >= 15 && !grouped.contains(candidate.existingID))
                            }
                        }
                    }
                    if !grouped.isEmpty { TextField("Shared problem title", text: $problem) }
                    if let error { Text(error).foregroundStyle(.orange) }
                    Button("Prepare Report Draft") {
                        do {
                            let context = try CityPayReportContext(component: component, region: region, area: area, module: module)
                            error = nil
                            let ids = grouped.sorted { $0.rawValue < $1.rawValue }, title = grouped.isEmpty ? nil : problem
                            Task { await model.prepareReport(context: context, groupedIDs: ids, problem: title) }
                        } catch { self.error = "Choose the component and region and enter valid area/module names." }
                    }.disabled(model.busy).accessibilityIdentifier("bug.report.prepare")
                    Text("Grouping requires current requirements and verified observations of the same root behavior. Unresolved duplicates block a new report.").font(.caption)
                }
            }
        }
    }
}

private struct BugDecisionControls: View {
    @ObservedObject var model: NativeBugReviewModel
    let existingID: BugID
    @State private var resolution = BugReviewDecision.Resolution.distinct
    @State private var reason = ""
    var body: some View {
        VStack(alignment: .leading) {
            Picker("Decision", selection: $resolution) {
                Text("Duplicate").tag(BugReviewDecision.Resolution.duplicate)
                Text("Related").tag(BugReviewDecision.Resolution.related)
                Text("Distinct").tag(BugReviewDecision.Resolution.distinct)
            }.accessibilityIdentifier("bug.decision.resolution")
            TextField("Reason for this decision", text: $reason).accessibilityIdentifier("bug.decision.reason")
            Button("Review Decision") {
                Task { await model.prepareResolution(existingID: existingID, resolution: resolution, reason: reason) }
            }.disabled(model.busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("bug.decision.review")
        }
    }
}
private extension BugComparisonResult.Classification {
    var reviewTitle: String {
        switch self {
        case .duplicate: "Duplicate"
        case .possibleDuplicate: "Possible duplicate"
        case .related: "Related behavior"
        case .distinct: "Distinct behavior"
        case .blocked: "Blocked behavior"
        case .needsEvidence: "More evidence needed"
        case .needsEnvironment: "Environment needed"
        case .needsRequirementReview: "Requirement review needed"
        }
    }
}
#endif
