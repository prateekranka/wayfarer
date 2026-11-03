import AVFoundation
import MontageCore
import Observation
import Photos
import PhotosUI
import SwiftUI

@MainActor @Observable
final class AppStore {
    let playback = PlaybackController()
    let taste = TasteStore()
    var projects: [MontageProject] = []
    var isLibraryLoaded = false
    var project: MontageProject?
    var directory: URL?
    var isBusy = false
    var progressTitle = ""
    var progressDetail = ""
    var completed = 0
    var total = 0
    var exportProgress: Double = 0
    var errorMessage: String?
    var notice: String?
    var exportedURL: URL?
    var selectedPlanID: UUID?
    var saveSucceeded = false
    var shouldPresentExport = false
    var isSavingPhotos = false
    var analysisSeconds: Double = 0
    var generationSeconds: Double = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private let repository = ProjectRepository()
    @ObservationIgnored private let importer = MediaImportService()
    @ObservationIgnored private let videoAnalyzer = VideoAnalysisService()
    @ObservationIgnored private let musicAnalyzer = MusicAnalysisService()
    @ObservationIgnored private let demo = DemoMediaService()
    @ObservationIgnored private let renderer = PreviewRenderer()
    @ObservationIgnored private let exporter = ExportService()

    var selectedPlan: MontagePlan? {
        guard let project else { return nil }
        return project.plans.first { $0.id == selectedPlanID } ?? project.plans.first
    }

    func load() async {
        await taste.loadIfNeeded()
        defer { isLibraryLoaded = true }
        do {
            let library = try await repository.loadAll()
            projects = library.projects
            if library.unreadableCount > 0 {
                errorMessage = "\(library.unreadableCount) saved project(s) could not be read. Their media remains on this device. Your other journeys are available."
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func open(_ value: MontageProject) {
        begin("Opening your journey", detail: "Loading your saved moments and edits…", total: 1)
        directory = nil
        project = value; selectedPlanID = value.selectedPlanID ?? value.plans.first?.id
        saveSucceeded = false; exportedURL = nil
        task = Task {
            do {
                let savedDirectory = try await repository.directory(for: value.id)
                try Task.checkCancellation()
                directory = savedDirectory
                if let file = value.exportFileName, let directory { exportedURL = directory.appending(path: file) }
                if value.assets.contains(where: { !value.analyzedAssetIDs.contains($0.id) }) {
                    try await analyzeRemaining()
                } else { completed = 1; finish() }
            } catch { handle(error) }
        }
    }

    func create(from items: [PhotosPickerItem], appending: Bool = false) {
        guard !items.isEmpty else { return }
        if appending && project == nil { return }
        begin("Bringing your clips together", detail: "Downloading selected videos if needed…", total: items.count)
        if !appending { startNewProject(name: "A new journey") }
        task = Task {
            do {
                guard let id = project?.id else { return }
                let destination = try await repository.directory(for: id)
                try Task.checkCancellation()
                directory = destination
                let directory = destination
                try await checkpoint()
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    progressTitle = "Importing \(index + 1) of \(CountLabel.make(items.count, singular: "clip"))"
                    do {
                        guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                            throw MontageError.invalidMedia("One selected clip could not be downloaded. Check your connection and try selecting it again.")
                        }
                        defer { try? FileManager.default.removeItem(at: movie.url) }
                        let known = Set(project?.assets.map(\.fingerprint) ?? [])
                        if let asset = try await importer.importVideo(url: movie.url, photoIdentifier: item.itemIdentifier,
                                                                    directory: directory, knownFingerprints: known) {
                            project?.assets.append(asset)
                            try await checkpoint()
                            progressDetail = "Finding the best moments…"
                            try await analyze(asset, directory: directory)
                        } else {
                            project?.warnings.append("A duplicate clip was already imported.")
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { project?.warnings.append("Clip \(index + 1): \(error.localizedDescription)") }
                    completed = index + 1
                    try await checkpoint()
                }
                project?.stage = .setup
                try await checkpoint(); finish()
            } catch { handle(error) }
        }
    }

    func createSample(count: Int) {
        begin("Preparing your sample trip", detail: "Bringing illustrated clips together…", total: count)
        startNewProject(name: count >= 85 ? "A week of little wonders" : "A little escape")
        task = Task {
            do {
                guard let id = project?.id else { return }
                let destination = try await repository.directory(for: id)
                try Task.checkCancellation()
                directory = destination
                let directory = destination
                let assets = try await demo.create(directory: directory, count: count) { [self] completed in
                    await MainActor.run {
                        guard self.project?.id == id, !Task.isCancelled else { return }
                        self.completed = completed
                    }
                }
                try Task.checkCancellation()
                project?.assets = assets
                project?.stage = .analyzing
                try await checkpoint()
                try await analyzeRemaining()
            } catch { handle(error) }
        }
    }

    func importFiles(_ urls: [URL], appending: Bool = false) {
        guard !urls.isEmpty else { return }
        if appending && project == nil { return }
        begin("Bringing your clips together", detail: "Finding the best moments…", total: urls.count)
        if !appending { startNewProject(name: "A new journey") }
        task = Task {
            do {
                guard let id = project?.id else { return }
                let destination = try await repository.directory(for: id)
                try Task.checkCancellation()
                directory = destination
                let directory = destination
                try await checkpoint()
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        if let asset = try await importer.importVideo(url: url, photoIdentifier: nil, directory: directory,
                                                                    knownFingerprints: Set(project?.assets.map(\.fingerprint) ?? [])) {
                            project?.assets.append(asset); try await checkpoint()
                            progressTitle = "Analyzing \(index + 1) of \(CountLabel.make(urls.count, singular: "clip"))"
                            try await analyze(asset, directory: directory)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { project?.warnings.append("Clip \(index + 1): \(error.localizedDescription)") }
                    completed = index + 1; try await checkpoint()
                }
                project?.stage = .setup; try await checkpoint(); finish()
            } catch { handle(error) }
        }
    }

    func resume() {
        begin("Finding your best moments", detail: "Continuing where you left off…", total: project?.assets.count ?? 0)
        task = Task { do { try await analyzeRemaining() } catch { handle(error) } }
    }

    func chooseMusic(url: URL) {
        guard let directory else { return }
        begin("Listening to your music", detail: "Finding the rhythm and changes in energy…", total: 1)
        task = Task {
            do {
                let copy = try await importer.importAudio(url: url, directory: directory)
                let analysis = try await musicAnalyzer.analyze(url: copy)
                try Task.checkCancellation()
                project?.music = MusicSource(fileName: copy.lastPathComponent,
                                             title: url.deletingPathExtension().lastPathComponent, analysis: analysis)
                try await checkpoint(); finish()
            } catch { handle(error) }
        }
    }

    func sampleMusic() {
        guard let directory else { return }
        begin("Finding the rhythm", detail: "Listening to the sample soundtrack…", total: 1)
        task = Task {
            do {
                let url = try await demo.createMusic(directory: directory)
                let analysis = try await musicAnalyzer.analyze(url: url)
                try Task.checkCancellation()
                project?.music = MusicSource(fileName: url.lastPathComponent, title: "Little Wanderings • original sample", analysis: analysis)
                try await checkpoint(); finish()
            } catch { handle(error) }
        }
    }

    func generate(keepLocks: Bool = false) {
        guard let current = project, let music = current.music else { return }
        let locked = keepLocks || !current.plans.isEmpty ? selectedPlan?.segments.filter(\.isLocked) ?? [] : []
        begin("Making three different edits", detail: "Choosing moments, shaping the story, and finding the right cuts…", total: 3)
        task = Task {
            do {
                let start = ContinuousClock.now
                let request = PlanningRequest(moments: current.moments, music: music.analysis,
                                              targetDuration: current.targetDuration, intent: current.intent,
                                              parameters: current.parameters, lockedSegments: locked,
                                              rejectedSourceIDs: current.rejectedSourceIDs,
                                              rejectedMomentIDs: current.rejectedMomentIDs,
                                              priorPlans: keepLocks ? current.plans : [], seed: current.seed,
                                              tasteProfile: taste.profile.isEnabled ? taste.profile : nil)
                let planningTask = Task.detached(priority: .userInitiated) {
                    try MontagePlanner().generate(request)
                }
                let plans = try await withTaskCancellationHandler {
                    try await planningTask.value
                } onCancel: { planningTask.cancel() }
                try Task.checkCancellation()
                for plan in plans {
                    try PlanValidator.validate(plan, target: current.targetDuration, assets: current.assets,
                                               musicDuration: music.analysis.duration,
                                               rejectedSources: current.rejectedSourceIDs,
                                               rejectedMoments: current.rejectedMomentIDs)
                }
                generationSeconds = Double(start.duration(to: .now).components.attoseconds) / 1e18
                    + Double(start.duration(to: .now).components.seconds)
                project?.plans = plans; project?.seed &+= 17; project?.stage = .ready
                project?.plannedSettings = current.planningSettings
                selectedPlanID = plans.first?.id; project?.selectedPlanID = selectedPlanID
                invalidateExport(); try await checkpoint(); completed = 3; finish()
            } catch { handle(error) }
        }
    }

    func select(_ id: UUID) {
        if selectedPlanID != id { invalidateExport() }
        selectedPlanID = id; project?.selectedPlanID = id; persist()
    }
    func update(_ action: (inout MontageProject) -> Void) {
        guard var value = project else { return }
        let old = value; action(&value); project = value
        if old.planningSettings != value.planningSettings || old.outputRatio != value.outputRatio || old.originalSound != value.originalSound || old.look != value.look || old.text != value.text {
            invalidateExport()
        }
        persist()
    }
    func lock(_ segmentID: UUID) {
        mutatePlan { plan in
            guard let index = plan.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            plan.segments[index].isLocked.toggle()
            plan.segments[index].preferredTimelineStart = plan.segments[index].isLocked
                ? plan.segments.prefix(index).reduce(0) { $0 + $1.duration } : nil
        }
    }

    func replace(_ segmentID: UUID, moment: CandidateMoment) {
        guard let plan = selectedPlan, let project else { return }
        do { commitPlan(try PlanRefiner.replace(plan: plan, segmentID: segmentID, with: moment, moments: project.moments)) }
        catch { errorMessage = error.localizedDescription }
    }

    func resize(_ segmentID: UUID, delta: Double) {
        guard let plan = selectedPlan, let project,
              let segment = plan.segments.first(where: { $0.id == segmentID }) else { return }
        do {
            commitPlan(try PlanRefiner.resize(plan: plan, segmentID: segmentID,
                                             to: max(0.5, segment.duration + delta), moments: project.moments))
        } catch { errorMessage = error.localizedDescription }
    }

    func move(_ segmentID: UUID, offset: Int) {
        guard let plan = selectedPlan else { return }
        do { commitPlan(try PlanRefiner.move(plan: plan, segmentID: segmentID, by: offset)) }
        catch { errorMessage = error.localizedDescription }
    }

    func reject(_ segmentID: UUID, entireSource: Bool) {
        guard let segment = selectedPlan?.segments.first(where: { $0.id == segmentID }), !segment.isLocked else { return }
        if entireSource, selectedPlan?.segments.contains(where: { $0.isLocked && $0.sourceAssetID == segment.sourceAssetID }) == true {
            errorMessage = "This clip contains a locked moment. Unlock that moment before rejecting the clip."; return
        }
        if entireSource { project?.rejectedSourceIDs.insert(segment.sourceAssetID) }
        else { project?.rejectedMomentIDs.insert(segment.momentID) }
        generate(keepLocks: true)
    }

    func alternatives(for segment: MontageSegment) -> [CandidateMoment] {
        guard let project else { return [] }
        let used = Set(selectedPlan?.segments.map(\.momentID) ?? [])
        return project.moments.filter {
            $0.id != segment.momentID && !used.contains($0.id) && $0.duration >= segment.duration
                && !project.rejectedSourceIDs.contains($0.sourceAssetID)
                && !project.rejectedMomentIDs.contains($0.id)
        }.sorted {
            let lhs = $0.features.quality + ($0.sourceAssetID == segment.sourceAssetID ? 0.2 : 0)
            let rhs = $1.features.quality + ($1.sourceAssetID == segment.sourceAssetID ? 0.2 : 0)
            return lhs > rhs
        }.prefix(5).map { $0 }
    }

    func playerItem(for plan: MontagePlan, useProxy: Bool = false) async throws -> AVPlayerItem {
        guard let project, let directory else { throw MontageError.invalidMedia("Open this project again to preview it.") }
        return try await renderer.playerItem(project: project, plan: plan, directory: directory, useProxy: useProxy)
    }

    func export() {
        guard project?.needsGeneration != true else {
            errorMessage = "Your creative direction has changed. Make new edits before exporting."; return
        }
        guard let project, let plan = selectedPlan, let directory else { return }
        begin("Finishing your montage", detail: "Rendering a high-quality video…", total: 1)
        exportProgress = 0; saveSucceeded = false
        task = Task {
            do {
                let url = try await exporter.export(project: project, plan: plan, directory: directory) { [self] value in
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.exportProgress = value }
                }
                try Task.checkCancellation()
                exportedURL = url; self.project?.exportFileName = url.lastPathComponent; self.project?.stage = .exported
                shouldPresentExport = true
                try await checkpoint(); finish(); notice = "Your montage is ready to save or share."
            } catch { handle(error) }
        }
    }

    func saveToPhotos() {
        guard let exportedURL, !isSavingPhotos, !saveSucceeded else { return }
        isSavingPhotos = true
        task = Task {
            defer { isSavingPhotos = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                errorMessage = "Photos access is disabled. Allow access in Settings, or use Share to save your video elsewhere."; return
            }
            do {
                // PhotoKit executes this block on its own queue. Do not inherit MainActor isolation.
                try await PHPhotoLibrary.shared().performChanges { @Sendable in
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: exportedURL)
                }
                saveSucceeded = true; notice = "Saved to Photos"
            } catch { handle(error) }
        }
    }

    func cancel() {
        if isBusy { notice = "Paused. Completed clips and edits are saved. You can continue when you’re ready." }
        task?.cancel(); task = nil; isBusy = false
    }
    func pauseForBackground() {
        taste.cancelImport()
        if isBusy { cancel(); notice = "Processing paused. Your completed clips are saved. Continue when you return." }
        persist(immediately: true)
    }

    private func analyzeRemaining() async throws {
        guard let current = project, let directory else { return }
        isBusy = true; total = current.assets.count
        let start = ContinuousClock.now
        for (index, asset) in current.assets.enumerated() {
            try Task.checkCancellation()
            completed = index
            if project?.analyzedAssetIDs.contains(asset.id) == true { continue }
            progressTitle = "Analyzing \(index + 1) of \(total) clips"
            progressDetail = "Finding interesting moments…"
            do { try await analyze(asset, directory: directory) }
            catch is CancellationError { throw CancellationError() }
            catch { project?.warnings.append("Clip \(index + 1): \(error.localizedDescription)") }
            try await checkpoint()
        }
        completed = total
        analysisSeconds = Double(start.duration(to: .now).components.seconds)
        project?.stage = .setup; try await checkpoint(); finish()
    }

    private func analyze(_ asset: SourceAsset, directory: URL) async throws {
        var moments = try await videoAnalyzer.analyze(asset: asset, directory: directory)
        try Task.checkCancellation()
        // Spatial descriptors support coarse duplicate grouping across clips. This is a heuristic,
        // not semantic identity. Preserve the descriptor so a learned service can replace it.
        for index in moments.indices {
            moments[index].importOrder = project?.assets.firstIndex(where: { $0.id == asset.id })
            if let match = project?.moments.first(where: { candidate in
                candidate.featureVector.count == moments[index].featureVector.count
                    && !candidate.featureVector.isEmpty
                    && zip(candidate.featureVector, moments[index].featureVector)
                        .reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) } / Double(candidate.featureVector.count) < 0.035
            }) {
                moments[index].clusterID = match.clusterID
                moments[index].features.novelty = 0.2
            } else { moments[index].clusterID = (project?.moments.count ?? 0) + index }
        }
        project?.moments.append(contentsOf: moments)
        project?.analyzedAssetIDs.insert(asset.id)
        if let thumbnail = moments.first?.thumbnailFileName,
           let index = project?.assets.firstIndex(where: { $0.id == asset.id }) {
            project?.assets[index].thumbnailFileName = thumbnail
        }
    }

    private func begin(_ title: String, detail: String, total: Int) {
        cancel(); isBusy = true; progressTitle = title; progressDetail = detail
        completed = 0; self.total = total; notice = nil; errorMessage = nil
    }
    private func startNewProject(name: String) {
        project = MontageProject(name: name)
        directory = nil; selectedPlanID = nil; exportedURL = nil
        saveSucceeded = false; shouldPresentExport = false
        analysisSeconds = 0; generationSeconds = 0
    }
    private func finish() { isBusy = false }
    private func handle(_ error: Error) {
        // A cancelled old operation must not change a new project's UI or metadata.
        guard !Task.isCancelled else { return }
        isBusy = false
        if error is CancellationError { notice = "Paused. Your completed work is saved." }
        else { errorMessage = error.localizedDescription }
        persist()
    }
    private func checkpoint() async throws {
        persistenceTask?.cancel()
        guard let project else { return }; try await repository.save(project)
        try Task.checkCancellation()
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.insert(project, at: 0) }
    }
    private func persist(immediately: Bool = false) {
        persistenceTask?.cancel()
        guard let snapshot = project else { return }
        persistenceTask = Task {
            do {
                if !immediately { try await Task.sleep(for: .milliseconds(200)) }
                try Task.checkCancellation()
                try await repository.save(snapshot)
                try Task.checkCancellation()
                await load()
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
    private func mutatePlan(_ action: (inout MontagePlan) -> Void) {
        guard var value = selectedPlan else { return }; action(&value); commitPlan(value)
    }
    private func commitPlan(_ value: MontagePlan) {
        guard let index = project?.plans.firstIndex(where: { $0.id == value.id }), let current = project,
              let music = current.music else { return }
        do {
            try PlanValidator.validate(value, target: current.targetDuration, assets: current.assets,
                                       musicDuration: music.analysis.duration, rejectedSources: current.rejectedSourceIDs,
                                       rejectedMoments: current.rejectedMomentIDs)
            project?.plans[index] = value; invalidateExport(); persist()
        } catch { errorMessage = error.localizedDescription }
    }
    private func invalidateExport() {
        exportedURL = nil; project?.exportFileName = nil; saveSucceeded = false
        if project?.plans.isEmpty == false { project?.stage = .ready }
    }
}
