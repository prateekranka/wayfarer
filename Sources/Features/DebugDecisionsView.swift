import MontageCore
import SwiftUI

#if DEBUG
struct DebugDecisionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Processing") {
                    LabeledContent("Sources", value: "\(store.project?.assets.count ?? 0)")
                    LabeledContent("Analyzed sources", value: "\(store.project?.analyzedAssetIDs.count ?? 0)")
                    LabeledContent("Candidate moments", value: "\(store.project?.moments.count ?? 0)")
                    LabeledContent("Analysis", value: String(format: "%.2f seconds", store.analysisSeconds))
                    LabeledContent("Generation", value: String(format: "%.2f seconds", store.generationSeconds))
                }
                if let plan = store.selectedPlan {
                    Section("Zooms") {
                        let edits = EditPlanner.edits(for: plan, music: store.project?.music?.analysis, recipe: .recipe(for: plan.intent))
                        ForEach(ZoomKind.allCases, id: \.self) { kind in
                            LabeledContent(kind.rawValue, value: "\(edits.filter { $0.kind == kind }.count)")
                        }
                    }
                    Section("Sequence quality") {
                        LabeledContent("Used sources", value: "\(plan.metrics.usedSources)")
                        LabeledContent("Average shot", value: String(format: "%.2f seconds", plan.metrics.averageDuration))
                        LabeledContent("Cuts near beats", value: String(format: "%.0f%%", plan.metrics.beatAlignment * 100))
                        LabeledContent("Chronological consistency", value: String(format: "%.0f%%", plan.metrics.chronologicalConsistency * 100))
                        LabeledContent("Semantic categories", value: "\(plan.metrics.semanticDiversity)")
                        LabeledContent("Mean quality", value: String(format: "%.2f", plan.metrics.meanQuality))
                        LabeledContent("Mean motion", value: String(format: "%.2f", plan.metrics.meanMotion))
                    }
                    Section("Decisions") {
                        ForEach(Array(plan.segments.enumerated()), id: \.element.id) { index, segment in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Moment \(index + 1) · \(segment.duration, specifier: "%.2f")s").font(.headline)
                                Text("Source range \(segment.sourceStartTime, specifier: "%.2f")–\(segment.sourceStartTime + segment.duration, specifier: "%.2f")s")
                                ForEach(segment.reasons, id: \.self) { Text($0).font(.caption) }
                            }
                        }
                    }
                }
            }.navigationTitle("Editing decisions").toolbar { Button("Done") { dismiss() } }
        }
    }
}
#endif
