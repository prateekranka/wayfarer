import AVKit
import MontageCore
import SwiftUI

/// Display current, factual names even when opening an edit saved by an older build.
extension MontagePlan {
    var displayName: String {
        guard intent == .beatSync else { return name }
        switch name {
        case "Beat Sync": return "Beat Sync · Balanced"
        case "Beat Sync · Flow": return "Beat Sync · Scenic"
        case "Beat Sync · Lift": return "Beat Sync · Motion"
        default: return name
        }
    }
    var shortName: String { displayName.components(separatedBy: " · ").last ?? displayName }
    var displaySummary: String {
        guard intent == .beatSync else { return summary }
        switch shortName {
        case "Scenic": return "Scenery and varied views, with quicker shot changes."
        case "Motion": return "Movement and visual interest, with longer holds."
        default: return "A balanced selection, with cuts shaped around strong musical points."
        }
    }
}

struct ResultsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var showEditor: Bool
    let isPreviewActive: Bool
    @State private var showExport = false
    @State private var showInfo = false
    @State private var showTaste = false
    private var plans: [MontagePlan] { store.project?.plans ?? [] }
    private var selection: Binding<UUID?> {
        Binding(get: { store.selectedPlan?.id }, set: { id in
            guard let id, plans.contains(where: { $0.id == id }) else { return }
            store.select(id)
        })
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Your edits").font(Theme.title).tracking(-1)
                        Spacer()
                        Button { showTaste = true } label: {
                            Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                        }.buttonStyle(.glass).accessibilityLabel("My Style")
                            .accessibilityIdentifier("teach-style")
                    }
                    if store.project?.needsGeneration == true {
                        Label("Your direction has changed. Make new edits to apply it.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline).foregroundStyle(Theme.accent).accessibilityIdentifier("new-edits-needed")
                    }
                    TabView(selection: selection) {
                        ForEach(plans) { plan in
                            VStack(alignment: .leading, spacing: 8) {
                                MontagePlayer(plan: plan,
                                    isSelected: store.selectedPlan?.id == plan.id,
                                    isActive: isPreviewActive && !showExport && !showInfo && !showTaste)
                                caption(for: plan)
                            }.padding(.horizontal, 2).tag(Optional(plan.id))
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? max(620, geometry.size.height) : min(620, max(290, geometry.size.height - 190)))
                    .accessibilityIdentifier("edit-pager")
                    variantSelector
                    LookControls()
                    TextControls()
                    let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 16))
                    layout {
                        Button { showEditor = true } label: {
                            Label("Make it yours", systemImage: "rectangle.stack").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        }.disabled(store.project?.needsGeneration == true).accessibilityIdentifier("refine-edit")
                        Spacer(minLength: 0)
                        Button("Try Another Edit", systemImage: "arrow.triangle.2.circlepath") { store.generate(keepLocks: true) }
                            .font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("try-another-edit")
                    }.foregroundStyle(Theme.secondary)
                }.padding(.horizontal, Theme.margin).padding(.vertical, 12)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.background(Theme.background)
        }
        .sensoryFeedback(.selection, trigger: store.selectedPlan?.id)
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: store.project?.needsGeneration == true ? "Make New Edits" : store.exportedURL == nil ? "Finish & Export" : "Save & Share", symbol: "square.and.arrow.up") {
                if store.project?.needsGeneration == true { store.generate(keepLocks: true) }
                else if store.exportedURL == nil { store.export() }
                else { showExport = true }
            }.accessibilityIdentifier("export-montage")
                .padding(.horizontal, Theme.margin).padding(.vertical, 12)
                .frame(maxWidth: 760).frame(maxWidth: .infinity).background(Theme.background)
        }
        .sheet(isPresented: $showExport) { ExportView() }
        .sheet(isPresented: $showTaste) { TasteView(initialTab: .compare) }
        .sheet(isPresented: $showInfo) { EditStyleInfoView(plans: plans) }
        .onChange(of: store.exportedURL) { _, url in if url != nil { showExport = true } }
        .onAppear { if store.shouldPresentExport { showExport = true; store.shouldPresentExport = false } }
    }
    private var variantSelector: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(plans) { plan in
                Button { store.select(plan.id) } label: {
                    Text(plan.shortName).font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 4)
                        .foregroundStyle(store.selectedPlan?.id == plan.id ? Theme.ink : Theme.secondary)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(store.selectedPlan?.id == plan.id ? Theme.accent : .clear).frame(height: 3)
                        }
                }.buttonStyle(.plain).accessibilityIdentifier("variant-\(plan.displayName)")
                    .accessibilityAddTraits(store.selectedPlan?.id == plan.id ? .isSelected : [])
            }
        }.overlay(alignment: .bottom) { Divider().overlay(Theme.rule).offset(y: 1) }
    }
    private func caption(for plan: MontagePlan) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(plan.displayName).font(.headline)
                    .accessibilityIdentifier(store.selectedPlan?.id == plan.id ? "selected-edit-name" : "inactive-edit-name-\(plan.id)")
                Text("\(Int(plan.duration.rounded())) sec · \(CountLabel.make(plan.segments.count, singular: "moment")) · \((plans.firstIndex(where: { $0.id == plan.id }) ?? 0) + 1) of \(plans.count)")
                    .font(.caption).foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier(store.selectedPlan?.id == plan.id ? "edit-page-position" : "inactive-edit-position-\(plan.id)")
            }
            Spacer(minLength: 0)
            Button { showInfo = true } label: { Image(systemName: "info.circle").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel("About edit styles")
                .accessibilityIdentifier(store.selectedPlan?.id == plan.id ? "edit-style-info" : "inactive-edit-info-\(plan.id)")
        }.fixedSize(horizontal: false, vertical: true)
    }
}

/// The switch and strength slider for the style's color look. The slider saves
/// when the finger lifts, so dragging does not rebuild the preview many times.
struct LookControls: View {
    @Environment(AppStore.self) private var store
    @State private var draft: Double?
    private var settings: LookSettings { store.project?.look ?? LookSettings() }
    private var lookName: String { store.selectedPlan.map { ColorLook.style(for: $0.intent).name } ?? "Style" }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { settings.isEnabled }, set: { value in store.update { $0.look.isEnabled = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Color look").font(.subheadline.weight(.semibold))
                    Text(lookName).font(.caption).foregroundStyle(Theme.secondary)
                }
            }.frame(minHeight: 44).accessibilityIdentifier("look-enabled")
            if settings.isEnabled {
                Slider(value: Binding(get: { draft ?? settings.strength }, set: { draft = $0 }), in: 0.1...1, step: 0.1) { editing in
                    guard !editing, let value = draft else { return }
                    draft = nil
                    store.update { $0.look.strength = value }
                }.accessibilityLabel("Look strength")
                    .accessibilityValue("\(Int(((draft ?? settings.strength) * 100).rounded())) percent")
                    .accessibilityIdentifier("look-strength")
            }
        }
    }
}

/// The title switch and its words. Text saves when typing ends, so each key
/// press does not rebuild the preview.
struct TextControls: View {
    @Environment(AppStore.self) private var store
    @State private var title = ""
    @State private var subtitle = ""
    @FocusState private var focused: Field?
    private enum Field { case title, subtitle }
    private var settings: TextSettings { store.project?.text ?? TextSettings(isEnabled: false) }
    private var styleName: String { store.selectedPlan.map { TextLook.style(for: $0.intent).name } ?? "Style" }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { settings.isEnabled }, set: { value in store.update { $0.text.isEnabled = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Title").font(.subheadline.weight(.semibold))
                    Text(styleName).font(.caption).foregroundStyle(Theme.secondary)
                }
            }.frame(minHeight: 44).accessibilityIdentifier("text-enabled")
            if settings.isEnabled {
                TextField(store.project?.name ?? "Title", text: $title)
                    .focused($focused, equals: .title).submitLabel(.done)
                    .frame(minHeight: 44).accessibilityIdentifier("text-title")
                TextField("Line under the title", text: $subtitle)
                    .focused($focused, equals: .subtitle).submitLabel(.done)
                    .font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("text-subtitle")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }.accessibilityIdentifier("close-title-keyboard")
            }
        }
        .onAppear(perform: load)
        .onChange(of: store.project?.id) { _, _ in load() }
        .onChange(of: settings.isEnabled) { _, _ in load() }
        .onChange(of: focused) { old, _ in if old != nil { save() } }
        .onSubmit(save)
    }
    private func load() {
        title = store.project?.titleText ?? settings.title ?? ""
        subtitle = store.project?.subtitleText ?? settings.subtitle ?? ""
    }
    private func save() {
        guard let project = store.project else { return }
        // Keep following the project's name and dates until someone changes them.
        let newTitle: String? = title == (project.text.title ?? project.name) ? project.text.title : title
        let dates = TextSettings.dateLine(for: project.assets.compactMap(\.timestamp)) ?? ""
        let newSubtitle: String? = subtitle == (project.text.subtitle ?? dates) ? project.text.subtitle : subtitle
        guard newTitle != project.text.title || newSubtitle != project.text.subtitle else { return }
        store.update { $0.text.title = newTitle; $0.text.subtitle = newSubtitle }
    }
}

struct EditStyleInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let plans: [MontagePlan]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(plans.first?.intent == .beatSync ? "What is Beat Sync?" : "Three takes on your journey")
                        .font(Theme.section)
                    Text(plans.first?.intent == .beatSync
                         ? "Beat Sync uses detected musical accents to guide cut timing. It does not cut on every beat. The footage and your chosen length also shape the rhythm."
                         : "Each version uses the same creative intent, with a different selection of moments and pacing.")
                    ForEach(plans) { plan in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan.displayName).font(.headline)
                            Text(plan.displaySummary).foregroundStyle(.secondary)
                            Text("This edit: \(CountLabel.make(plan.segments.count, singular: "moment")) · \(plan.metrics.averageDuration, specifier: "%.1f") sec average shot")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Scenic was previously called Flow. Motion was previously called Lift. These names describe selection and pacing, not a guaranteed musical build or drop.")
                        .font(.caption).foregroundStyle(.secondary)
                        .opacity(plans.first?.intent == .beatSync ? 1 : 0)
                }.padding(24).frame(maxWidth: 520)
            }.navigationTitle("About these edits").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() }.accessibilityIdentifier("close-edit-info") }
        }.presentationDetents([.large]).frame(minWidth: 300, idealWidth: 460)
    }
}

struct MontagePlayer: View {
    @Environment(AppStore.self) private var store
    let plan: MontagePlan
    var isSelected = true
    let isActive: Bool
    @State private var error: String?
    @State private var useProxy = false
    @State private var loadedConfiguration: PreviewConfiguration?
    @State private var owner = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct PreviewConfiguration: Equatable {
        let plan: MontagePlan
        let ratio: OutputRatio?
        let originalSound: Double?
        let look: LookSettings?
        let text: TextSettings?
        let musicFile: String?
        let useProxy: Bool
        let needsGeneration: Bool
        let isSelected: Bool
        let isActive: Bool
    }
    private var configuration: PreviewConfiguration {
        PreviewConfiguration(plan: plan, ratio: store.project?.outputRatio,
            originalSound: store.project?.originalSound, look: store.project?.look, text: store.project?.textSettings, musicFile: store.project?.music?.fileName,
            useProxy: useProxy, needsGeneration: store.project?.needsGeneration == true,
            isSelected: isSelected, isActive: isActive)
    }
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                if isSelected, store.playback.owner == owner {
                    PlaybackSurface(player: store.playback.player).accessibilityIdentifier("montage-player")
                        .accessibilityLabel("Montage preview. Swipe left or right to change edits.")
                } else if let error { Text(error).foregroundStyle(.white).padding() }
                else if isSelected { ProgressView("Preparing preview").tint(.white).foregroundStyle(.white) }
                else {
                    ThumbnailView(url: plan.segments.first.flatMap { segment in
                        store.project?.moments.first(where: { $0.id == segment.momentID })?.thumbnailFileName
                    }.flatMap { store.directory?.appending(path: $0) })
                }
            }.clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
            if isSelected {
                PlaybackControls(duration: plan.duration, owner: owner)
                Text(error ?? store.playback.error ?? store.playback.audioError ?? (store.playback.isReady ? "Ready to play" : "Preparing preview"))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("playback-state")
            } else { Color.clear.frame(height: 72) }
        }
        .task(id: configuration) {
            guard isSelected else { store.playback.release(owner: owner); return }
            guard isActive else { store.playback.setActive(false, owner: owner); return }
            if loadedConfiguration == configuration, store.playback.owner == owner {
                store.playback.setActive(true, owner: owner); return
            }
            error = nil
            guard store.project?.needsGeneration != true else {
                store.playback.release(owner: owner); error = "Make new edits to preview this direction."; return
            }
            do {
                let item = try await store.playerItem(for: plan, useProxy: useProxy)
                try Task.checkCancellation()
                await store.playback.load(item: item, owner: owner, autoplay: reduceMotion ? false : nil)
                guard !Task.isCancelled else { return }
                loadedConfiguration = configuration
                store.playback.setActive(isActive, owner: owner)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: store.playback.itemFailed) { _, failed in
            if isSelected, store.playback.owner == owner, failed, !useProxy { useProxy = true }
        }
        .onChange(of: isActive) { _, active in store.playback.setActive(active && isSelected, owner: owner) }
        .onChange(of: isSelected) { _, selected in if !selected { store.playback.setActive(false, owner: owner) } }
        .onDisappear { store.playback.release(owner: owner) }
    }
}

struct PlaybackControls: View {
    @Environment(AppStore.self) private var store
    let duration: Double
    let owner: UUID
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { store.playback.togglePlayback() } label: {
                    Image(systemName: store.playback.wantsPlayback ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(store.playback.wantsPlayback ? "Pause video" : "Play video")
                    .accessibilityIdentifier("preview-play-pause")
                Text("\(timeLabel(store.playback.seconds)) / \(timeLabel(duration.rounded()))")
                    .font(.caption).monospacedDigit().accessibilityIdentifier("playback-position")
                Spacer(minLength: 0)
                Button { store.playback.toggleMute() } label: {
                    Image(systemName: store.playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(store.playback.isMuted ? "Unmute video" : "Mute video")
                    .accessibilityValue(store.playback.isMuted ? "Muted" : "Sound on")
                    .accessibilityIdentifier("preview-mute")
            }
            Slider(value: Binding(get: { min(max(0, store.playback.seconds), max(0.1, duration)) },
                                  set: { store.playback.seek(to: $0) }), in: 0...max(0.1, duration))
                .accessibilityLabel("Playback position").accessibilityIdentifier("preview-scrubber")
        }.disabled(store.playback.owner != owner || !store.playback.isReady)
    }
}

func timeLabel(_ seconds: Double) -> String {
    let value = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}

struct FilePlaybackView: View {
    @Environment(AppStore.self) private var store
    let url: URL
    let owner: UUID
    var autoplay: Bool? = nil
    var startTime: Double = 0
    var endTime: Double?
    var releaseOnDisappear = true
    var body: some View {
        VStack(spacing: 8) {
            PlaybackSurface(player: store.playback.player).clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
                .accessibilityLabel("Video preview").accessibilityIdentifier("file-player")
            PlaybackControls(duration: store.playback.duration, owner: owner)
            if let error = store.playback.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if let error = store.playback.audioError { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.task(id: url) {
            // A reference player may live in a recycled Form row. Keep its
            // position while the reference screen still owns playback.
            if !releaseOnDisappear, store.playback.owner == owner, store.playback.isReady {
                store.playback.setActive(true, owner: owner); return
            }
            let item = AVPlayerItem(url: url)
            if let endTime { item.forwardPlaybackEndTime = CMTime(seconds: endTime, preferredTimescale: 600) }
            await store.playback.load(item: item, owner: owner, autoplay: autoplay)
            guard !Task.isCancelled, store.playback.owner == owner else { return }
            if startTime > 0 { _ = await store.playback.player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) }
            guard !Task.isCancelled, store.playback.owner == owner else { return }
            store.playback.setActive(true, owner: owner)
        }.onDisappear { if releaseOnDisappear { store.playback.release(owner: owner) } }
    }
}

struct ExportView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var owner = UUID()
    @State private var referenceCountBeforeSave: Int?
    private var savedReference: Bool {
        referenceCountBeforeSave.map { store.taste.references.count > $0 } ?? false
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Ready to share.").font(Theme.section); Spacer(); Button("Done") { dismiss() }.accessibilityIdentifier("close-export") }
            if let url = store.exportedURL { FilePlaybackView(url: url, owner: owner).frame(height: 380) }
            Text(store.selectedPlan?.displayName ?? "Your montage").font(.headline).accessibilityIdentifier("export-edit-name")
            Label("\(store.project?.outputRatio.width ?? 1080) × \(store.project?.outputRatio.height ?? 1920) · H.264", systemImage: "checkmark.seal")
                .font(.subheadline).foregroundStyle(.secondary)
            PrimaryButton(title: store.saveSucceeded ? "Saved to Photos" : store.isSavingPhotos ? "Saving…" : "Save to Photos", symbol: store.saveSucceeded ? "checkmark" : "photo") {
                store.saveToPhotos()
            }.accessibilityIdentifier("save-photos").disabled(store.saveSucceeded || store.isSavingPhotos)
            if store.saveSucceeded { Text("Saved to Photos").font(.headline).accessibilityIdentifier("photos-saved") }
            if let url = store.exportedURL {
                ShareLink(item: url) { Label("Share your montage", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity, minHeight: 48) }
                Button(savedReference ? "Saved to My Style" : store.taste.isImporting ? "Reading reference…" : "Keep this reel as a reference", systemImage: "bookmark") {
                    referenceCountBeforeSave = store.taste.references.count
                    store.taste.importReferences([url])
                }.frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(savedReference || store.taste.isImporting)
                    .accessibilityIdentifier("keep-export-reference")
            }
            Spacer(minLength: 0)
        }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.background(Theme.background).presentationDragIndicator(.visible)
            .alert("Reference library", isPresented: Binding(get: { store.taste.error != nil }, set: { if !$0 { store.taste.error = nil } })) {
                Button("OK") { store.taste.error = nil }
            } message: { Text(store.taste.error ?? "") }
    }
}
