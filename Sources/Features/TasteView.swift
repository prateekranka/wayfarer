import MontageCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum TasteTab: String, CaseIterable, Identifiable {
    case preferences = "Preferences", references = "References", compare = "Compare"
    var id: Self { self }
}

struct TasteView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var tab: TasteTab
    @State private var intent: EditIntent = .beatSync
    @State private var showReset = false
    @State private var showRecovery = false
    @State private var showFiles = false
    @State private var photo: PhotosPickerItem?
    @State private var comparedID: UUID?
    @State private var reason: TasteFeedbackReason = .overall
    @State private var preview: MontagePlan?
    init(initialTab: TasteTab = .preferences) { _tab = State(initialValue: initialTab) }
    private var taste: TasteStore { store.taste }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("My Style section", selection: $tab) {
                    ForEach(TasteTab.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
                HStack {
                    Text("\(taste.profile.feedbackCount) comparisons recorded").accessibilityIdentifier("taste-feedback-count")
                        Spacer()
                    Text(taste.saveStatus).accessibilityIdentifier("taste-save-status")
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 8)
                Form {
                    switch tab {
                    case .preferences: preferences
                    case .references: references
                    case .compare: comparison
                    }
                }.scrollContentBackground(.hidden).id(tab)
            }.background(Theme.background).navigationTitle("My Style").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() }.accessibilityIdentifier("close-my-style") }
                .task { intent = store.project?.intent ?? .beatSync; await taste.loadIfNeeded() }
                .alert("Style library", isPresented: Binding(get: { taste.error != nil }, set: { if !$0 { taste.error = nil } })) {
                    Button("OK") { taste.error = nil }
                } message: { Text(taste.error ?? "") }
                .confirmationDialog("Reset all learned and manual preferences? Reference reels and approved edits will stay.", isPresented: $showReset, titleVisibility: .visible) {
                    Button("Reset preferences", role: .destructive) { taste.reset() }
                }
                .confirmationDialog("Start a new profile? The unreadable profile and its approved examples will be preserved in a separate local file.", isPresented: $showRecovery, titleVisibility: .visible) {
                    Button("Start a new profile") { Task { await taste.recover() } }
                }
                .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): taste.importReferences(urls)
                    case .failure(let error): taste.error = error.localizedDescription
                    }
                }
                .onChange(of: photo) { _, item in if let item { taste.importPhoto(item); photo = nil } }
                .sheet(item: $preview) { plan in
                    NavigationStack {
                        MontagePlayer(plan: plan, isActive: true).padding(20)
                            .navigationTitle(plan.displayName).navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("Done") { preview = nil }.accessibilityIdentifier("close-comparison-preview") }
                    }
                }
        }
    }
    private var preferences: some View {
        Group {
            Section {
                Text("Your editing style").font(Theme.section)
                Text("Choose the edits you prefer. Your choices guide future montages on this device.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Toggle("Use my taste for new edits", isOn: Binding(get: { taste.profile.isEnabled }, set: { taste.setEnabled($0) }))
                    .accessibilityIdentifier("taste-enabled")
                if taste.canRecover {
                    Button("Start a new profile") { showRecovery = true }.accessibilityIdentifier("recover-taste")
                }
            }
            Section("Preferences for this feeling") {
                Picker("Edit intent", selection: $intent) { ForEach(EditIntent.allCases) { Text($0.title).tag($0) } }
                ForEach(TasteDimension.allCases) { dimension in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(dimension.title)
                            Spacer()
                            Text(preferenceLabel(taste.profile.preferences(for: intent)[dimension], dimension: dimension))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { taste.profile.preferences(for: intent)[dimension] },
                                              set: { taste.set(dimension, value: $0, intent: intent) }), in: -1...1, step: 0.1)
                            .accessibilityLabel("\(intent.title) \(dimension.title)")
                            .accessibilityIdentifier("taste-\(dimension.rawValue)")
                    }
                }
                Text("These are gentle preferences. Your requested length, locked moments, rejected footage, and basic quality checks still take priority.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!taste.isLoaded)
            Section {
                Button("Reset preferences", role: .destructive) { showReset = true }
                    .disabled(!taste.isLoaded).accessibilityIdentifier("reset-taste")
                if let message = taste.feedbackMessage { Text(message).font(.caption).accessibilityIdentifier("taste-feedback-message") }
            }
        }
    }
    private var references: some View {
        Group {
            Section {
                Text("Show us what you love.").font(Theme.section)
                Text("Keep a few reels here. Add notes at the moments that work. Estimated cut timing can guide pacing; notes stay as examples for you to review.")
                    .font(.subheadline).foregroundStyle(.secondary)
                PhotosPicker(selection: $photo, matching: .videos, preferredItemEncoding: .current) {
                    Label("Add a reel from Photos", systemImage: "photo")
                }.disabled(taste.isImporting).accessibilityIdentifier("reference-photos")
                Button("Import a reel from Files", systemImage: "folder") { showFiles = true }
                    .disabled(taste.isImporting).accessibilityIdentifier("reference-files")
                if taste.isImporting {
                    ProgressView("Reading your reference reel…")
                    Button("Cancel import") { taste.cancelImport() }
                }
                Text("Up to 3 minutes and 1 GB per reel. Everything stays on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reference reels · \(taste.references.count)") {
                if let warning = taste.referenceWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                if taste.references.isEmpty { Text("Your reference reels will appear here.").foregroundStyle(.secondary) }
                ForEach(taste.references) { reference in
                    NavigationLink {
                        ReferenceDetailView(reference: reference)
                    } label: {
                        HStack(spacing: 12) {
                            ThumbnailView(url: taste.thumbnailURL(reference)).frame(width: 54, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(reference.title).lineLimit(2)
                                Text("\(timeLabel(reference.duration)) · \(CountLabel.make(reference.notes.count, singular: "note"))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.accessibilityIdentifier("reference-\(reference.id.uuidString)")
                }
            }
            Section("Approved edits · \(taste.examples.count)") {
                Text("An approved edit keeps the raw-clip references and exact selected ranges together. Save one from Compare after refining your edit.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(taste.examples) { example in
                    NavigationLink {
                        ApprovedExampleView(example: example)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(example.projectName)
                            Text("\(example.plan.displayName) · \(CountLabel.make(example.plan.segments.count, singular: "source range"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("approved-example-\(example.id.uuidString)")
                }
            }
        }
    }
    private var comparison: some View {
        Group {
            if let project = store.project, let selected = store.selectedPlan, !project.needsGeneration {
                let otherPlans = project.plans.filter { $0.id != selected.id }
                let other = otherPlans.first { $0.id == comparedID } ?? otherPlans.first
                Section {
                    Text("Which edit feels more like you?").font(Theme.section)
                    Text("Compare versions of this journey. We learn only when you record a choice. Swiping and watching do not change your preferences.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Selected: \(selected.displayName)").font(.headline).accessibilityIdentifier("comparison-selected")
                    Button("Watch selected edit", systemImage: "play.circle") { preview = selected }
                    if let other {
                        Picker("Compare with", selection: Binding(get: { other.id }, set: { comparedID = $0 })) {
                            ForEach(otherPlans) { Text($0.shortName).tag($0.id) }
                        }
                        Button("Watch \(other.shortName)", systemImage: "play.circle") { preview = other }
                        Picker("What matters most?", selection: $reason) {
                            ForEach(TasteFeedbackReason.allCases) { Text($0.title).tag($0) }
                        }
                        Button("I prefer \(selected.shortName)") { taste.prefer(selected, over: other, project: project, reason: reason) }
                            .accessibilityIdentifier("prefer-selected-edit")
                        Button("I prefer \(other.shortName)") { taste.prefer(other, over: selected, project: project, reason: reason) }
                            .accessibilityIdentifier("prefer-other-edit")
                    }
                    if let message = taste.feedbackMessage { Text(message).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("taste-feedback-message") }
                    }.disabled(!taste.isLoaded)
                Section("Keep a complete example") {
                    Text(CountLabel.make(taste.examples.count, singular: "approved edit")).accessibilityIdentifier("approved-example-count")
                    Button("Save selected edit as an example", systemImage: "bookmark") { taste.approve(selected, project: project) }
                        .accessibilityIdentifier("approve-edit-example")
                    Text("Saves this exact edit, source ranges, music reference, and rejected moments. It does not change your preferences by itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!taste.isLoaded)
            } else {
                Section {
                    ContentUnavailableView("Make an edit first", systemImage: "film.stack", description: Text("After generating a montage, compare its versions here to teach your style."))
                }
            }
        }
    }
}

private func preferenceLabel(_ value: Double, dimension: TasteDimension) -> String {
    if abs(value) < 0.05 { return "Balanced" }
    if dimension == .pacing { return value > 0 ? "Quicker cuts" : "Longer holds" }
    return value > 0 ? "More" : "Less"
}

struct ReferenceDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var reference: ReelReference
    @State private var note = ""
    @State private var noteTime: Double = 0
    @State private var intent: EditIntent = .beatSync
    @State private var showDelete = false
    @State private var pacingMessage: String?
    @FocusState private var noteIsFocused: Bool
    var body: some View {
        Form {
            Section {
                FilePlaybackView(url: store.taste.referenceURL(reference), owner: reference.id, autoplay: false,
                                 releaseOnDisappear: false).frame(height: 330)
            }
            Section("What works here?") {
                Button("Mark this moment · \(timeLabel(store.playback.seconds))", systemImage: "pin") {
                    noteTime = min(reference.duration, max(0, store.playback.seconds))
                    if store.playback.wantsPlayback { store.playback.togglePlayback() }
                }.accessibilityIdentifier("mark-reference-moment")
                TextField("Why this moment works", text: $note, axis: .vertical).lineLimit(2...5)
                    .focused($noteIsFocused).submitLabel(.done).onSubmit { noteIsFocused = false }
                    .accessibilityIdentifier("reference-note")
                Button("Save note at \(timeLabel(noteTime))") {
                    var updated = reference
                    updated.notes.append(ReferenceNote(time: noteTime, text: String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))))
                    Task { if await store.taste.updateReference(updated) { reference = updated; note = "" } }
                }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reference.notes.count >= 100)
                    .accessibilityIdentifier("save-reference-note")
                ForEach(reference.notes.sorted { $0.time < $1.time }) { annotation in
                    HStack(alignment: .top) {
                        Button(timeLabel(annotation.time)) { store.playback.seek(to: annotation.time) }.monospacedDigit()
                        Text(annotation.text).font(.subheadline)
                    }
                }
                Text("Notes preserve your examples. They do not automatically change editing preferences.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Estimated pacing") {
                if let average = reference.estimatedAverageShotDuration {
                    Text("\(CountLabel.make(reference.cutTimes.count, singular: "estimated cut")) · \(average, specifier: "%.1f") sec average shot")
                    Text("Cut detection is approximate. Camera movement and dissolves can affect this estimate.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Use for", selection: $intent) { ForEach(EditIntent.allCases) { Text($0.title).tag($0) } }
                    Button("Use this pacing preference") {
                        let neutral: Double = switch intent {
                        case .beatSync: 1.25
                        case .cinematic: 3.8
                        case .highlights: 1.75
                        case .story, .people, .places: 2.2
                        }
                        // A bounded preference, not a promise to copy exact cut lengths.
                        store.taste.set(.pacing, value: min(1, max(-1, (neutral - average) / neutral)), intent: intent)
                        pacingMessage = "Pacing preference saved for future \(intent.title) edits."
                    }.disabled(!store.taste.isLoaded || reference.analysisConfidence < 0.25)
                        .accessibilityIdentifier("use-reference-pacing")
                    if let pacingMessage { Text(pacingMessage).font(.caption) }
                } else { Text("There were not enough clear cuts to estimate pacing. Use notes and the preference controls instead.") }
            }
            Section {
                Button("Remove reference reel", role: .destructive) { showDelete = true }
            }
        }.navigationTitle(reference.title).navigationBarTitleDisplayMode(.inline)
            .onDisappear { store.playback.release(owner: reference.id) }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { noteIsFocused = false }.accessibilityIdentifier("close-note-keyboard")
                }
            }
            .confirmationDialog("Remove this reel and its notes from your style library?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Remove reel", role: .destructive) {
                    Task { if await store.taste.removeReference(reference) { dismiss() } }
                }
            }
    }
}

struct ApprovedExampleView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let example: ApprovedEditExample
    @State private var showDelete = false
    var body: some View {
        List {
            Section {
                Text(example.projectName).font(.headline)
                Text(example.plan.displayName)
                Text("Source files remain in the original journey. These decisions preserve exactly which part of each clip was used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Approved source ranges") {
                ForEach(Array(example.plan.segments.enumerated()), id: \.element.id) { index, segment in
                    let source = example.assets.firstIndex { $0.id == segment.sourceAssetID }.map { $0 + 1 } ?? 0
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Moment \(index + 1) · Clip \(source)")
                        Text("\(segment.sourceStartTime, specifier: "%.2f")–\(segment.sourceStartTime + segment.duration, specifier: "%.2f") sec")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section { Button("Remove example", role: .destructive) { showDelete = true } }
        }.navigationTitle("Approved edit").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Remove this saved example? Your journey and finished edit will stay.", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Remove example", role: .destructive) { store.taste.removeExample(example.id); dismiss() }
            }
    }
}
