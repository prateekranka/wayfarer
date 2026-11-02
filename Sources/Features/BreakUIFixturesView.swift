#if DEBUG
import MontageCore
import SwiftUI

/// Opt-in native fixtures. The consumer app never sees this in Release builds.
/// Models enter through the existing AppStore boundary; no layout is faked.
struct BreakUIFixturesView<Content: View>: View {
    @Environment(AppStore.self) private var store
    private let content: Content
    @State private var original: [MontageProject] = []
    @State private var mode: Mode = .demo
    @State private var narrow = false
    @State private var largeText = false
    @State private var rightToLeft = false

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    private enum Mode: String, CaseIterable, Identifiable {
        case demo = "Demo data", worst = "Worst case", empty = "Empty", one = "One", huge = "1,000"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: narrow ? 320 : .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.dynamicTypeSize, largeText ? .accessibility5 : .large)
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
            VStack(spacing: 5) {
                Picker("Demo data / Worst case", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("break-ui-data")
                HStack(spacing: 14) {
                    Toggle("320 pt", isOn: $narrow).accessibilityIdentifier("break-ui-narrow")
                    Toggle("XXXL", isOn: $largeText).accessibilityIdentifier("break-ui-large-text")
                    Toggle("RTL", isOn: $rightToLeft).accessibilityIdentifier("break-ui-rtl")
                }.font(.caption).toggleStyle(.button)
            }.padding(8).background(.regularMaterial)
                .environment(\.dynamicTypeSize, .large)
        }
        .transaction { $0.animation = nil }
        .onAppear { if store.isLibraryLoaded { original = store.projects } }
        .onChange(of: store.isLibraryLoaded) { _, loaded in if loaded { original = store.projects } }
        .onChange(of: mode) { _, selection in store.projects = fixtures(for: selection) }
        .onDisappear { store.projects = original }
    }

    private func fixtures(for selection: Mode) -> [MontageProject] {
        switch selection {
        case .demo: return original
        case .empty: return []
        case .one: return [singleClipProject(named: "J")]
        case .worst:
            var long = singleClipProject(named: "Đà Nẵng, Hội An & the Hải Vân coastal road — our family’s unforgettable summer journey 🌅")
            long.createdAt = Date(timeIntervalSince1970: 1_672_443_000)
            long.assets[0].thumbnailFileName = "missing-thumbnail.jpg"
            var many = MontageProject(name: "IMG_20250914_183022_HDR_portrait_edited_edited.mp4")
            many.stage = .setup; many.targetDuration = 180
            many.assets = (0..<300).map { index in
                SourceAsset(fileName: "IMG_20250914_183022_HDR_portrait_edited_edited-\(index).mp4",
                            duration: 6, width: index.isMultiple(of: 2) ? 4000 : 200,
                            height: index.isMultiple(of: 2) ? 200 : 4000,
                            fingerprint: "break-ui-\(index)")
            }
            let arabic = singleClipProject(named: "نور الهدى عبد الرحمن — رحلة العائلة إلى البحر")
            let short = singleClipProject(named: "Jo")
            return [long, many, arabic, short]
        case .huge:
            return (0..<1000).map { index in
                var project = singleClipProject(named: index == 0 ? "A thousand journeys" : "Coastal walk · \(index + 1)")
                project.createdAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 86_400)
                project.assets[0].thumbnailFileName = nil
                return project
            }
        }
    }

    private func singleClipProject(named name: String) -> MontageProject {
        var project = MontageProject(name: name)
        project.stage = .setup
        project.targetDuration = 15
        let assetID = UUID()
        let asset = SourceAsset(id: assetID, fileName: "IMG_20250914_183022_HDR_portrait_edited_edited.mp4",
                                duration: 6, width: 3840, height: 2160, fingerprint: "break-ui-single-clip")
        var features = MomentFeatures()
        features.quality = 0.85
        features.motion = 0.35
        features.people = 0.55
        let moment = CandidateMoment(sourceAssetID: assetID, sourceStartTime: 0, sourceEndTime: 3,
                                     features: features, semanticTags: ["people", "coast"],
                                     confidence: 0.9, clusterID: 0)
        project.assets = [asset]
        project.moments = [moment]
        project.analyzedAssetIDs = [assetID]
        return project
    }
}
#endif
