import MontageCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var showProject = false
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--break-ui") {
            BreakUIFixturesView { navigation }
        } else { navigation }
        #else
        navigation
        #endif
    }
    private var navigation: some View {
        NavigationStack {
            Group {
                if store.isLibraryLoaded {
                    HomeView(showProject: $showProject)
                }
                else {
                    VStack(alignment: .leading, spacing: 25) {
                        Text("WAYFARER").font(.caption.weight(.bold)).tracking(3)
                        Text("Your trips.").font(Theme.title)
                        Text("Opening your trips…").foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 25).fill(Theme.card).frame(height: 220).redacted(reason: .placeholder)
                        Spacer()
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Theme.background)
                }
            }
                .navigationDestination(isPresented: $showProject) { ProjectView() }
        }.background(Theme.background)
            .alert("Let’s fix that", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Binding var showProject: Bool
    @State private var showImport = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showTaste = false
    @State private var nextPicker: ImportPicker?
    private enum ImportPicker { case photos, files }
    @State private var selection: [PhotosPickerItem] = []
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize = 44

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("WAYFARER").font(.caption.weight(.bold)).tracking(2)
                        Spacer()
                        Button { showTaste = true } label: {
                            Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                        }.buttonStyle(.glass).accessibilityLabel("My Style")
                            .accessibilityIdentifier("open-my-style")
                    }
                    if store.projects.isEmpty {
                        EditFramesArtwork()
                            .frame(height: max(140, min(280, geometry.size.height * 0.4)))
                        Text("Your next reel\nstarts here.")
                            .font(.system(size: displaySize, weight: .bold).width(.expanded)).tracking(-1.2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Choose clips and a song.\nGet three finished edits.")
                            .font(.body).foregroundStyle(Theme.secondary)
                        Button("Try a sample trip") { showImport = true }
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    } else {
                        Text("Your trips.")
                            .font(.system(size: displaySize, weight: .bold).width(.expanded)).tracking(-1.2)
                        if let first = store.projects.first {
                            projectButton(first, featured: true)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(store.projects.dropFirst()) { project in
                                Divider().overlay(Theme.rule)
                                projectButton(project, featured: false)
                            }
                        }
                    }
                }
                .foregroundStyle(Theme.ink)
                .padding(Theme.margin).frame(maxWidth: 880).frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(Theme.background).toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                PrimaryButton(title: "Create a Montage", symbol: "plus") { showImport = true }
                    .accessibilityIdentifier("create-montage")
                    .accessibilityValue(showImport ? "Selecting sources" : "Ready")
                Text("Your clips stay on this device.").font(.caption).foregroundStyle(Theme.secondary)
            }.padding(.horizontal, Theme.margin).padding(.top, 12).padding(.bottom, 8)
                .frame(maxWidth: 880).frame(maxWidth: .infinity).background(Theme.background)
        }
        .sheet(isPresented: $showImport, onDismiss: {
            let picker = nextPicker; nextPicker = nil
            switch picker {
            case .photos: showPhotos = true
            case .files: showFiles = true
            case nil: break
            }
        }) { importSheet }
        .sheet(isPresented: $showTaste) { TasteView() }
            .photosPicker(isPresented: $showPhotos, selection: $selection, maxSelectionCount: 300, matching: .videos,
                          preferredItemEncoding: .current)
            .onChange(of: selection) { _, items in
                if !items.isEmpty { store.create(from: items); showProject = true; selection = [] }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): store.importFiles(urls); showProject = true
                case .failure(let error): store.errorMessage = error.localizedDescription
                }
            }
    }
    private var importSheet: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            Text("Add clips.").font(Theme.title).fixedSize(horizontal: false, vertical: true)
            Text("Choose videos from your trip. We’ll find the moments to keep.").foregroundStyle(.secondary)
            PrimaryButton(title: "Choose from Photos", symbol: "photo.on.rectangle") { nextPicker = .photos; showImport = false }
                .accessibilityIdentifier("choose-photos")
            Button { nextPicker = .files; showImport = false } label: { Label("Import videos from Files", systemImage: "folder") }
                .font(.headline).frame(minHeight: 44)
                .accessibilityIdentifier("choose-files")
            Divider()
            Text("Try a sample trip").font(.headline)
            Text("Original illustrated videos and a sample soundtrack. Analysis and editing stay on your device.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("A little escape · 12 clips") { showImport = false; store.createSample(count: 12); showProject = true }
                .frame(minHeight: 44).accessibilityIdentifier("sample-12")
            Button("A week away · 85 clips") { showImport = false; store.createSample(count: 85); showProject = true }
                .frame(minHeight: 44).accessibilityIdentifier("sample-85")
            Spacer(minLength: 0)
        }.padding(28).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }.presentationDetents([.large]).presentationDragIndicator(.visible).background(Theme.background)
    }
    private func projectButton(_ project: MontageProject, featured: Bool) -> some View {
        Button { store.open(project); showProject = true } label: {
            ProjectCard(project: project, featured: featured)
        }.buttonStyle(.plain).accessibilityIdentifier("project-card-\(project.id.uuidString)")
    }

}

struct ProjectCard: View {
    let project: MontageProject
    var featured = true
    private var thumbnailURL: URL? {
        guard let file = project.assets.first?.thumbnailFileName else { return nil }
        return URL.applicationSupportDirectory.appending(path: "Wayfarer/Projects/\(project.id.uuidString)/\(file)")
    }
    private var stateLabel: String {
        project.needsGeneration ? "Needs new edits" : project.stage == .exported ? "Exported" : project.plans.isEmpty ? "Draft" : "Ready to watch"
    }
    var body: some View {
        Group {
            if featured {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack(alignment: .bottomLeading) {
                        ThumbnailView(url: thumbnailURL).frame(height: 350)
                        LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(project.name).font(Theme.title).tracking(-0.7)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(project.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(CountLabel.make(project.assets.count, singular: "clip"))")
                                .font(.caption)
                        }.foregroundStyle(.white).padding(22)
                    }.clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
                    HStack {
                        Text(stateLabel).font(.headline)
                        Spacer()
                        Text(project.plans.isEmpty ? "\(Int(project.targetDuration)) sec" : CountLabel.make(project.plans.count, singular: "edit"))
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            } else {
                HStack(spacing: 16) {
                    ThumbnailView(url: thumbnailURL).frame(width: 64, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(project.name).font(.headline)
                        Text("\(CountLabel.make(project.assets.count, singular: "clip")) · \(Int(project.targetDuration)) sec · \(stateLabel)")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        Text(project.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.subheadline)
                }.padding(.vertical, 16)
            }
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}
