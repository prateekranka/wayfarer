import Foundation
import MontageCore
import Observation
import PhotosUI
import SwiftUI

/// An approved edit keeps the decisions and original source references together.
/// Media stays in the source journey; no duplicate videos or uploads are needed.
struct ApprovedEditExample: Codable, Identifiable, Sendable {
    var id: UUID
    var projectID: UUID
    var projectName: String
    var savedAt: Date
    var plan: MontagePlan
    var assets: [SourceAsset]
    var moments: [CandidateMoment]
    var music: MusicSource?
    var rejectedMomentIDs: Set<UUID>
    var rejectedSourceIDs: Set<UUID>
}

private struct TasteLibraryData: Codable, Sendable {
    var profile = TasteProfile()
    var examples: [ApprovedEditExample] = []
}

private actor TasteRepository {
    private let file = URL.applicationSupportDirectory.appending(path: "Wayfarer/Style/taste.json")
    func load() throws -> TasteLibraryData {
        guard FileManager.default.fileExists(atPath: file.path) else { return TasteLibraryData() }
        return try JSONDecoder().decode(TasteLibraryData.self, from: Data(contentsOf: file))
    }
    func save(_ data: TasteLibraryData) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(data).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func recover() throws -> TasteLibraryData {
        let data = TasteLibraryData()
        if FileManager.default.fileExists(atPath: file.path) {
            let backup = file.deletingLastPathComponent().appending(path: "taste-preserved-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: file, to: backup)
        }
        try save(data)
        return data
    }
}

@MainActor @Observable
final class TasteStore {
    private(set) var profile = TasteProfile()
    private(set) var examples: [ApprovedEditExample] = []
    private(set) var references: [ReelReference] = []
    private(set) var isLoaded = false
    private(set) var canRecover = false
    private(set) var referenceWarning: String?
    private(set) var isImporting = false
    private(set) var saveStatus = ""
    var error: String?
    var feedbackMessage: String?
    @ObservationIgnored private let repository = TasteRepository()
    @ObservationIgnored private let referenceLibrary = ReferenceLibrary()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveSequence = 0

    func loadIfNeeded() async {
        if isLoaded { return }
        if let loadTask { await loadTask.value; return }
        let task = Task { [self] in
            do {
                let data = try await repository.load()
                profile = data.profile; examples = data.examples; isLoaded = true
                saveStatus = "Saved on this device"
            } catch {
                canRecover = true
                self.error = "Your taste profile could not be opened. Your saved files have been kept. Use Start a new profile in My Style to recover."
            }
            do {
                references = try await referenceLibrary.load()
                let skipped = await referenceLibrary.unreadableCount
                referenceWarning = skipped > 0 ? "\(skipped) saved reference(s) could not be opened. Their files have been kept. Your other references are available." : nil
            }
            catch { self.error = error.localizedDescription }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func set(_ dimension: TasteDimension, value: Double, intent: EditIntent) {
        guard isLoaded else { return }
        profile.set(dimension, value: value, for: intent)
        persist()
    }
    func setEnabled(_ enabled: Bool) {
        guard isLoaded else { return }
        profile.setEnabled(enabled); persist()
    }
    func reset() {
        guard isLoaded else { return }
        profile.reset(); feedbackMessage = "Preferences reset. Your reference reels and approved edits are still here."
        persist()
    }
    func recover() async {
        do {
            let data = try await repository.recover()
            profile = data.profile; examples = data.examples
            isLoaded = true; canRecover = false; error = nil
            saveStatus = "Saved on this device"
            feedbackMessage = "A new profile is ready. The unreadable profile was preserved in a separate local file."
        } catch { self.error = "The profile could not be recovered. Your saved file has been kept. Check available storage and try again." }
    }
    func prefer(_ preferred: MontagePlan, over other: MontagePlan, project: MontageProject, reason: TasteFeedbackReason) {
        guard isLoaded, project.plans.contains(where: { $0.id == preferred.id }),
              project.plans.contains(where: { $0.id == other.id }),
              abs(preferred.duration - other.duration) < 0.01 else { return }
        if profile.learn(preferred: preferred, over: other, moments: project.moments, reason: reason) {
            feedbackMessage = "Preference recorded for \(preferred.intent.title). Make new edits to use it."
            persist()
        } else { feedbackMessage = "This comparison is already recorded, or the edits do not differ enough to learn from." }
    }
    func prefer(_ preferred: CandidateMoment, over other: CandidateMoment, intent: EditIntent) {
        guard isLoaded else { return }
        if profile.learn(preferred: preferred, over: other, intent: intent) {
            feedbackMessage = "Moment preference recorded for future \(intent.title) edits."
            persist()
        } else { feedbackMessage = "There is no new preference to record from these moments." }
    }

    func approve(_ plan: MontagePlan, project: MontageProject) {
        guard isLoaded else { return }
        let existingIndex = examples.firstIndex { $0.projectID == project.id && $0.plan.id == plan.id }
        let exampleID = existingIndex.map { examples[$0].id } ?? UUID()
        let example = ApprovedEditExample(id: exampleID, projectID: project.id, projectName: project.name,
            savedAt: Date(), plan: plan, assets: project.assets, moments: project.moments, music: project.music,
            rejectedMomentIDs: project.rejectedMomentIDs, rejectedSourceIDs: project.rejectedSourceIDs)
        if let index = existingIndex { examples[index] = example }
        else {
            guard examples.count < 100 else { error = "Your library holds 100 approved edits. Remove an older example before adding another."; return }
            examples.insert(example, at: 0)
        }
        feedbackMessage = "Approved edit saved with its exact source ranges. Use comparisons or the preference controls to teach your style."
        persist()
    }
    func removeExample(_ id: UUID) { examples.removeAll { $0.id == id }; persist() }

    func referenceURL(_ reference: ReelReference) -> URL { referenceLibrary.mediaURL(for: reference) }
    func thumbnailURL(_ reference: ReelReference) -> URL? { referenceLibrary.thumbnailURL(for: reference) }

    func importReferences(_ urls: [URL]) {
        guard !isImporting else { return }
        isImporting = true; error = nil
        importTask = Task { [self] in
            defer { isImporting = false; importTask = nil }
            do {
                for url in urls {
                    try Task.checkCancellation()
                    guard references.count < 100 else { throw MontageError.invalidMedia("Your library holds 100 reference reels. Remove an older reel before adding another.") }
                    let reference = try await referenceLibrary.importVideo(at: url)
                    references.insert(reference, at: 0)
                }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    func importPhoto(_ item: PhotosPickerItem) {
        guard !isImporting else { return }
        isImporting = true; error = nil
        importTask = Task { [self] in
            defer { isImporting = false; importTask = nil }
            do {
                guard references.count < 100 else { throw MontageError.invalidMedia("Your reference library is full. Remove an older reel first.") }
                guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                    throw MontageError.invalidMedia("This reel could not be downloaded from Photos. Try again when it is available on this device.")
                }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                try Task.checkCancellation()
                let reference = try await referenceLibrary.importVideo(at: movie.url)
                references.insert(reference, at: 0)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancelImport() { importTask?.cancel() }
    @discardableResult func updateReference(_ reference: ReelReference) async -> Bool {
        error = nil
        do {
            try await referenceLibrary.update(reference)
            if let index = references.firstIndex(where: { $0.id == reference.id }) { references[index] = reference }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func removeReference(_ reference: ReelReference) async -> Bool {
        error = nil
        do {
            try await referenceLibrary.remove(reference)
            references.removeAll { $0.id == reference.id }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func persist() {
        guard isLoaded else { return }
        let snapshot = TasteLibraryData(profile: profile, examples: examples)
        saveSequence += 1
        let sequence = saveSequence
        let prior = saveTask
        saveStatus = "Saving…"
        saveTask = Task { [self] in
            await prior?.value
            do {
                try await repository.save(snapshot)
                if sequence == saveSequence { saveStatus = "Saved on this device" }
            } catch {
                if sequence == saveSequence { saveStatus = "Could not save"; self.error = "Your style changes could not be saved. Check available storage and try again." }
            }
        }
    }
}
