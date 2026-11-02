import MontageCore
import SwiftUI

struct SourceBrowserView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var category = "Best moments"
    private let categories = ["Best moments", "People", "Places", "Food", "Motion", "Low quality", "Unused"]
    private var moments: [CandidateMoment] {
        let used = Set(store.project?.plans.flatMap { $0.segments.map(\.momentID) } ?? [])
        return (store.project?.moments ?? []).filter {
            switch category {
            case "People": $0.features.people > 0.2 || $0.features.faces > 0.2
            case "Places": $0.features.scenery > 0.2 || $0.semanticTags.contains("architecture")
            case "Food": $0.features.food > 0.2
            case "Motion": $0.features.motion > 0.3
            case "Low quality": $0.features.quality < 0.4
            case "Unused": !used.contains($0.id)
            default: $0.features.quality >= 0.4
            }
        }.sorted { $0.features.quality > $1.features.quality }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Browse", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                Text(CountLabel.make(moments.count, singular: "moment")).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 15) {
                    ForEach(moments) { moment in
                        VStack(alignment: .leading, spacing: 7) {
                            ThumbnailView(url: moment.thumbnailFileName.flatMap { store.directory?.appending(path: $0) })
                                .frame(height: 165).clipShape(RoundedRectangle(cornerRadius: 15))
                            Text(moment.semanticTags.prefix(2).joined(separator: " · ").capitalized.isEmpty ? "From your trip" : moment.semanticTags.prefix(2).joined(separator: " · ").capitalized)
                                .font(.subheadline.weight(.medium))
                            Text("\(moment.duration, specifier: "%.1f") seconds").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(24)
        }.background(Theme.background).navigationTitle("Your source moments")
            .toolbar { Button("Done") { dismiss() } }
    }
}
