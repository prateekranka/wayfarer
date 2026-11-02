import Foundation
import MontageCore

actor ProjectRepository {
    private let root: URL
    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "Wayfarer/Projects", directoryHint: .isDirectory)
    }

    func directory(for id: UUID) throws -> URL {
        let url = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
        return url
    }

    func save(_ project: MontageProject) throws {
        try Task.checkCancellation()
        let url = try directory(for: project.id).appending(path: "project.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadAll() throws -> (projects: [MontageProject], unreadableCount: Int) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], 0) }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var projects: [MontageProject] = []
        var unreadableCount = 0
        for url in urls {
            let manifest = url.appending(path: "project.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            // A damaged project must not prevent all other projects from opening.
            do {
                var project = try JSONDecoder().decode(MontageProject.self, from: Data(contentsOf: manifest))
                guard project.schemaVersion == 1 else { unreadableCount += 1; continue }
                if project.analysisVersion != 2 {
                    project.moments = []; project.analyzedAssetIDs = []; project.plans = []
                    project.analysisVersion = 2; project.stage = .analyzing
                }
                if project.plannedSettings == nil, !project.plans.isEmpty {
                    project.plannedSettings = project.planningSettings
                }
                projects.append(project)
            } catch {
                unreadableCount += 1
            }
        }
        return (projects.sorted { $0.createdAt > $1.createdAt }, unreadableCount)
    }
}
