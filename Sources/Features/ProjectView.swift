import MontageCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ProjectView: View {
    @Environment(AppStore.self) private var store
    @State private var showSources = false
    @State private var showSettings = false
    @State private var showDebug = false
    @State private var showEditor = false
    @State private var showAddSources = false
    var body: some View {
        Group {
            if store.isBusy { ProcessingView() }
            else if store.project?.plans.isEmpty == false {
                ResultsView(showEditor: $showEditor,
                            isPreviewActive: !(showSources || showSettings || showAddSources || showDebug || showEditor))
            }
            else { SetupView() }
        }.background(Theme.background)
            .navigationDestination(isPresented: $showEditor) { MomentEditorView() }
            .navigationTitle(store.project?.name ?? "Your montage").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add more clips", systemImage: "plus.rectangle.on.rectangle") { showAddSources = true }
                        Button("Browse source moments", systemImage: "rectangle.stack") { showSources = true }
                        Button("Creative settings", systemImage: "slider.horizontal.3") { showSettings = true }
                        #if DEBUG
                        Button("Editing decisions", systemImage: "ladybug") { showDebug = true }
                        #endif
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Project options")
                }
            }
            .sheet(isPresented: $showSources) { NavigationStack { SourceBrowserView() } }
            .sheet(isPresented: $showAddSources) { AddSourcesView() }
            .navigationDestination(isPresented: $showSettings) {
                SetupView().navigationTitle("Creative settings")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSettings = false }
                                .accessibilityIdentifier("close-creative-settings")
                        }
                    }
            }
            .onChange(of: store.project?.plans) { _, plans in if plans?.isEmpty == false { showSettings = false } }
            #if DEBUG
            .sheet(isPresented: $showDebug) { DebugDecisionsView() }
            #endif
    }
}

struct AddSourcesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [PhotosPickerItem] = []
    @State private var showFiles = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Add more clips.").font(Theme.title)
                Text("Add footage to this journey. Your existing edits and locked moments stay available.").foregroundStyle(.secondary)
                PhotosPicker(selection: $selection, maxSelectionCount: 300, matching: .videos, preferredItemEncoding: .current) {
                    Label("Choose videos from Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
                Button("Import videos from Files", systemImage: "folder") { showFiles = true }
                    .frame(minHeight: 44)
                    .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video], allowsMultipleSelection: true) { result in
                        switch result {
                        case .success(let urls): store.importFiles(urls, appending: true); dismiss()
                        case .failure(let error): store.errorMessage = error.localizedDescription
                        }
                    }
                Spacer()
            }.padding(28).background(Theme.background).navigationTitle("Add clips")
                .toolbar { Button("Done") { dismiss() } }
                .onChange(of: selection) { _, items in
                    guard !items.isEmpty else { return }
                    store.create(from: items, appending: true); dismiss()
                }
        }
    }
}

struct ProcessingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var progressSize = 64
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if store.project?.assets.isEmpty == false {
                    ProjectPreviewStrip(height: 180)
                } else { EditFramesArtwork().frame(height: 180) }
                Text(store.progressTitle).font(Theme.title).tracking(-0.7)
                    .accessibilityIdentifier("processing-title")
                Text(store.progressDetail).font(.body).foregroundStyle(Theme.secondary)
                if store.progressTitle == "Finishing your montage" {
                    Text("\(Int(store.exportProgress * 100))%")
                        .font(.system(size: progressSize, weight: .bold).width(.condensed)).monospacedDigit()
                    ProgressView(value: store.exportProgress)
                    Text("Rendered").font(.subheadline).foregroundStyle(Theme.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(store.completed)").font(.system(size: progressSize, weight: .bold).width(.condensed)).monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText())
                        Text("of \(store.total)").font(.title3).foregroundStyle(Theme.secondary)
                    }
                    ProgressView(value: Double(store.completed), total: Double(max(1, store.total)))
                }
                Text("Your clips stay on this device. Completed work is saved as we go.")
                    .font(.subheadline).foregroundStyle(Theme.secondary)
                Button("Pause processing") { store.cancel() }.font(.headline).frame(minHeight: 44)
                    .accessibilityIdentifier("pause-processing")
            }.padding(Theme.margin).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }.background(Theme.background)
    }
}

struct ProjectPreviewStrip: View {
    @Environment(AppStore.self) private var store
    var height: CGFloat = 70
    var body: some View {
        GeometryReader { geometry in
            let assets = Array((store.project?.assets ?? []).prefix(3))
            let gaps = CGFloat(max(0, assets.count - 1)) * 6
            let width = max(0, (geometry.size.width - gaps) / CGFloat(max(1, assets.count)))
            HStack(spacing: 6) {
                ForEach(assets) { asset in
                    ThumbnailView(url: asset.thumbnailFileName.flatMap { store.directory?.appending(path: $0) })
                        .frame(width: width, height: height).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }.frame(height: height).accessibilityHidden(true)
    }
}

struct SetupView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showMusic = false
    @State private var showWarnings = false
    @State private var showCustom = false
    @State private var showAdvanced = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Make a reel.").font(Theme.title).tracking(-1)
                HStack(alignment: .center, spacing: 16) {
                    ProjectPreviewStrip().frame(width: 115)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Name your journey", text: Binding(get: { store.project?.name ?? "" }, set: { value in store.update { $0.name = value } }))
                            .font(.headline).accessibilityLabel("Project name")
                        Text(CountLabel.make(store.project?.assets.count ?? 0, singular: "clip"))
                            .font(.caption).foregroundStyle(Theme.secondary).accessibilityIdentifier("clip-count")
                        Text("\(CountLabel.make(store.project?.moments.count ?? 0, singular: "moment")) found")
                            .font(.caption).foregroundStyle(Theme.secondary).accessibilityIdentifier("moment-count")
                    }
                }
                if let notice = store.notice { Text(notice).font(.subheadline).foregroundStyle(Theme.secondary) }
                if store.project?.assets.contains(where: { store.project?.analyzedAssetIDs.contains($0.id) == false }) == true {
                    Button("Continue finding moments") { store.resume() }.buttonStyle(.borderedProminent)
                }
                if store.project?.warnings.isEmpty == false {
                    Button { showWarnings = true } label: { Label("Some clips need attention", systemImage: "exclamationmark.circle") }
                        .frame(minHeight: 44)
                }
                musicSection
                durationSection
                intentSection
                VStack(spacing: 0) {
                    HStack {
                        Text("Format").font(.headline)
                        Spacer()
                        Picker("Format", selection: Binding(get: { store.project?.outputRatio ?? .vertical }, set: { value in store.update { $0.outputRatio = value } })) {
                            ForEach(OutputRatio.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu).accessibilityIdentifier("output-format")
                    }.frame(minHeight: 48)
                    Divider().overlay(Theme.rule)
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(spacing: 24) {
                            CreativeSlider(left: "Story", right: "Highlights", value: parameter(\.highlights))
                            CreativeSlider(left: "Calm", right: "Energetic", value: parameter(\.energy))
                            CreativeSlider(left: "Longer shots", right: "Fast cuts", value: parameter(\.fastCuts))
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Original sound").font(.headline)
                                Text("Keep sound from your clips underneath the music.").font(.subheadline).foregroundStyle(Theme.secondary)
                                Slider(value: Binding(get: { store.project?.originalSound ?? 0 }, set: { value in store.update { $0.originalSound = value } }), in: 0...1)
                                    .accessibilityLabel("Original sound level")
                            }
                        }.padding(.top, 20).padding(.bottom, 12)
                    } label: {
                        Text("Creative controls").font(.headline).frame(minHeight: 48)
                    }.accessibilityIdentifier("creative-controls")
                    Divider().overlay(Theme.rule)
                }
            }.padding(Theme.margin).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(Theme.background)
            .sensoryFeedback(.selection, trigger: store.project?.targetDuration)
            .sensoryFeedback(.selection, trigger: store.project?.intent)
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Make My Reel", symbol: "play.fill", disabled: store.project?.music == nil || store.project?.moments.isEmpty != false) {
                    store.generate()
                }.accessibilityIdentifier("make-reel")
                    .padding(.horizontal, Theme.margin).padding(.vertical, 12)
                    .frame(maxWidth: 720).frame(maxWidth: .infinity).background(Theme.background)
            }
            .fileImporter(isPresented: $showMusic, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { store.chooseMusic(url: url) }
                case .failure(let error): store.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showWarnings) {
                NavigationStack {
                    List(store.project?.warnings ?? [], id: \.self) { Text($0) }
                        .navigationTitle("Import notes")
                        .toolbar { Button("Done") { showWarnings = false } }
                }
            }
    }
    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Soundtrack").font(.subheadline).foregroundStyle(Theme.secondary)
            Divider().overlay(Theme.rule)
            Button { showMusic = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "music.note").font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.project?.music?.title ?? "Import a song from Files").font(.headline).multilineTextAlignment(.leading)
                        if let music = store.project?.music {
                            Text("\(Int(music.analysis.duration)) sec · \(music.analysis.bpm.map { "\(Int($0)) BPM estimate" } ?? "Rhythm analyzed")")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        } else { Text("MP3, M4A, WAV, and compatible audio").font(.caption).foregroundStyle(Theme.secondary) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: store.project?.music == nil ? "plus" : "arrow.triangle.2.circlepath")
                }.frame(minHeight: 52).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("choose-music")
            Divider().overlay(Theme.rule)
            Button("Use sample soundtrack") { store.sampleMusic() }.font(.subheadline).frame(minHeight: 44)
                .accessibilityIdentifier("sample-music")
        }
    }
    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Length").font(.headline)
                Spacer()
                Button("Custom") { showCustom.toggle() }.font(.subheadline).frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("custom-duration")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 100 : 60))], spacing: 8) {
                ForEach([15, 30, 45, 60], id: \.self) { duration in
                    Button("\(duration)s") { showCustom = false; store.update { $0.targetDuration = Double(duration) } }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                        .background(store.project?.targetDuration == Double(duration) ? Theme.ink : Theme.card, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(store.project?.targetDuration == Double(duration) ? Theme.background : Theme.ink)
                        .accessibilityIdentifier("duration-\(duration)")
                        .accessibilityAddTraits(store.project?.targetDuration == Double(duration) ? .isSelected : [])
                }
            }.buttonStyle(.plain)
            if showCustom || ![15.0, 30, 45, 60].contains(store.project?.targetDuration ?? 30) {
                Stepper("\(store.project?.targetDuration ?? 30, specifier: "%.1f") seconds",
                        value: Binding(get: { store.project?.targetDuration ?? 30 }, set: { value in store.update { $0.targetDuration = value } }),
                        in: 5...180, step: 0.5)
            }
        }
    }
    private var intentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Feeling").font(.headline)
                Spacer()
                Picker("More feelings", selection: Binding(get: { store.project?.intent ?? .beatSync }, set: { value in store.update { $0.intent = value } })) {
                    ForEach(EditIntent.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
            }.frame(minHeight: 44)
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                ForEach([EditIntent.beatSync, .story, .cinematic]) { intent in
                    Button { store.update { $0.intent = intent } } label: {
                        Text(intent.title).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 6)
                            .background(store.project?.intent == intent ? Theme.ink : Theme.card, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(store.project?.intent == intent ? Theme.background : Theme.ink)
                    }.buttonStyle(.plain).accessibilityIdentifier("intent-\(intent.rawValue)")
                        .accessibilityLabel(intent.title + ". " + intent.subtitle)
                        .accessibilityAddTraits(store.project?.intent == intent ? .isSelected : [])
                }
            }
            Text((store.project?.intent ?? .beatSync).subtitle).font(.caption).foregroundStyle(Theme.secondary)
        }
    }
    private func parameter(_ key: WritableKeyPath<CreativeParameters, Double>) -> Binding<Double> {
        Binding(get: { store.project?.parameters[keyPath: key] ?? 0.5 }, set: { value in store.update { $0.parameters[keyPath: key] = value } })
    }
}

struct CreativeSlider: View {
    let left: String
    let right: String
    @Binding var value: Double
    var body: some View {
        VStack(spacing: 8) {
            HStack { Text(left); Spacer(); Text(right) }.font(.subheadline)
            Slider(value: $value, in: 0...1).accessibilityLabel("\(left) to \(right)")
        }
    }
}
