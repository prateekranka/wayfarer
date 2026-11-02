import AVKit
import MontageCore
import SwiftUI

struct MomentEditorView: View {
    @Environment(AppStore.self) private var store
    @State private var alternativeSegment: MontageSegment?
    @State private var sourceSegment: MontageSegment?
    var body: some View {
        Group {
            if store.isBusy { ProcessingView() }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Keep the parts\nyou love.").font(Theme.title).tracking(-1)
                        Text("Lock a favorite. Swap a moment. We’ll take care of the rest.").foregroundStyle(.secondary)
                        Text("\(CountLabel.make(store.selectedPlan?.segments.filter(\.isLocked).count ?? 0, singular: "moment")) locked")
                            .font(.headline).accessibilityIdentifier("locked-count")
                        ForEach(Array((store.selectedPlan?.segments ?? []).enumerated()), id: \.element.id) { index, segment in
                            momentRow(segment, index: index)
                        }
                    }.padding(24).frame(maxWidth: 800).frame(maxWidth: .infinity)
                }.background(Theme.background)
                    .safeAreaInset(edge: .bottom) {
                        PrimaryButton(title: "Try Another Edit", symbol: "arrow.triangle.2.circlepath") { store.generate(keepLocks: true) }
                            .accessibilityIdentifier("regenerate-with-locks").padding(20).background(Theme.background)
                    }
            }
        }.navigationTitle("Make it yours").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $alternativeSegment) { segment in AlternativesView(segment: segment) }
            .sheet(item: $sourceSegment) { segment in SourceMomentPlayer(segment: segment) }
    }
    private func momentRow(_ segment: MontageSegment, index: Int) -> some View {
        let moment = store.project?.moments.first { $0.id == segment.momentID }
        let sourceNumber = store.project?.assets.firstIndex { $0.id == segment.sourceAssetID }.map { $0 + 1 }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Button { sourceSegment = segment } label: {
                    ThumbnailView(url: moment?.thumbnailFileName.flatMap { store.directory?.appending(path: $0) })
                        .frame(width: 85, height: 112).clipShape(RoundedRectangle(cornerRadius: 13))
                        .overlay(Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Preview moment \(index + 1)")
                VStack(alignment: .leading, spacing: 7) {
                    Text("Moment \(index + 1)").font(.headline)
                    Text(segment.duration.formatted(.number.precision(.fractionLength(1))) + " seconds").monospacedDigit().font(.subheadline)
                    Text("Clip \(sourceNumber ?? 0) · from \(segment.sourceStartTime, specifier: "%.1f")s")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("source-reference-\(index)")
                    Text(moment?.semanticTags.prefix(2).joined(separator: " · ").capitalized ?? "A moment from your trip")
                        .font(.caption).foregroundStyle(.secondary)
                    if segment.isLocked { Label("Locked", systemImage: "lock.fill").font(.caption.weight(.semibold)) }
                }
                Spacer(minLength: 0)
                Button { store.lock(segment.id) } label: {
                    Image(systemName: segment.isLocked ? "lock.fill" : "lock.open").font(.title3)
                        .frame(width: 44, height: 44).background(Theme.card, in: Circle())
                }.accessibilityLabel(segment.isLocked ? "Unlock moment \(index + 1)" : "Lock moment \(index + 1)")
                    .accessibilityIdentifier("lock-shot-\(index)")
            }
            HStack {
                Button("Use another moment") { alternativeSegment = segment }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    .disabled(segment.isLocked).accessibilityIdentifier("replace-shot-\(index)")
                Spacer()
                Menu {
                    Button("Make shorter", systemImage: "minus") { store.resize(segment.id, delta: -0.5) }
                    Button("Make longer", systemImage: "plus") { store.resize(segment.id, delta: 0.5) }
                    Button("Move earlier", systemImage: "arrow.up") { store.move(segment.id, offset: -1) }
                    Button("Move later", systemImage: "arrow.down") { store.move(segment.id, offset: 1) }
                    Divider()
                    Button("Remove this moment", systemImage: "trash", role: .destructive) { store.reject(segment.id, entireSource: false) }
                    Button("Never use this clip", systemImage: "nosign", role: .destructive) { store.reject(segment.id, entireSource: true) }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .disabled(segment.isLocked).accessibilityLabel("More actions for moment \(index + 1)")
            }
        }.padding(.vertical, 20).overlay(alignment: .bottom) { Divider().overlay(Theme.rule) }
    }
}

struct AlternativesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let segment: MontageSegment
    @State private var teachPreference = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Another way to see it.").font(Theme.title)
                    Text("Each choice fits the same space in your edit.").foregroundStyle(.secondary)
                    Toggle("Learn this preference for future edits", isOn: $teachPreference)
                        .accessibilityIdentifier("learn-moment-preference")
                    Text("Off keeps this change in this journey. On also teaches which kinds of moments you prefer for this edit intent.")
                        .font(.caption).foregroundStyle(.secondary)
                    let alternatives = store.alternatives(for: segment)
                    if alternatives.isEmpty { ContentUnavailableView("No more moments fit", systemImage: "film", description: Text("Make this shot shorter, or import more footage.")) }
                    ForEach(Array(alternatives.enumerated()), id: \.element.id) { index, moment in
                        Button {
                            if teachPreference, let previous = store.project?.moments.first(where: { $0.id == segment.momentID }),
                               let intent = store.project?.intent {
                                store.taste.prefer(moment, over: previous, intent: intent)
                            }
                            store.replace(segment.id, moment: moment); dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                ThumbnailView(url: moment.thumbnailFileName.flatMap { store.directory?.appending(path: $0) })
                                    .frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 18))
                                HStack {
                                    Text(moment.semanticTags.prefix(3).joined(separator: " · ").capitalized.isEmpty ? "A different moment" : moment.semanticTags.prefix(3).joined(separator: " · ").capitalized)
                                        .font(.headline)
                                    Spacer(); Label("Use this", systemImage: "arrow.right")
                                }
                            }.padding(15).background(Theme.card, in: RoundedRectangle(cornerRadius: 22))
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                                .contentShape([.interaction, .accessibility], Rectangle())
                                .accessibilityElement(children: .combine)
                        }.buttonStyle(.plain).accessibilityIdentifier("alternative-\(index)")
                    }
                }.padding(24)
            }.background(Theme.background).navigationTitle("Alternatives").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct SourceMomentPlayer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let segment: MontageSegment
    @State private var owner = UUID()
    var body: some View {
        VStack(spacing: 20) {
            HStack { Text("A closer look").font(.title2); Spacer(); Button("Done") { dismiss() } }.padding()
            if let file = store.project?.assets.first(where: { $0.id == segment.sourceAssetID })?.fileName,
               let url = store.directory?.appending(path: file) {
                FilePlaybackView(url: url, owner: owner, startTime: segment.sourceStartTime,
                                 endTime: segment.sourceStartTime + segment.duration).padding(20)
            }
        }
    }
}
