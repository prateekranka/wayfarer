import SwiftUI

/// Shared visual roles. Asset colors include separate light and dark appearances.
enum Theme {
    static let background = Color("Ground")
    static let card = Color("Raised")
    static let ink = Color("Ink")
    static let secondary = Color("SecondaryInk")
    static let rule = Color("Rule")
    static let accent = Color("Accent")
    static let actionFill = Color("ActionFill")
    static let onAccent = Color("OnAccent")
    static let title = Font.system(.largeTitle, design: .default, weight: .bold).width(.expanded)
    static let section = Font.system(.title2, design: .default, weight: .bold)
    static let margin: CGFloat = 24
    static let mediaRadius: CGFloat = 12
}

enum CountLabel {
    static func make(_ count: Int, singular: String, plural: String? = nil) -> String {
        let noun = count == 1 ? singular : (plural ?? "\(singular)s")
        return "\(count) \(noun)"
    }
}

struct PrimaryButton: View {
    let title: String
    var symbol: String = "arrow.right"
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(title).font(.headline).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: symbol).font(.headline)
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(PrimaryActionStyle()).disabled(disabled)
    }
}

private struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.onAccent)
            .background(Theme.actionFill, in: RoundedRectangle(cornerRadius: 28))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: configuration.isPressed)
    }
}

struct SectionTitle: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.section).foregroundStyle(Theme.ink)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(Theme.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusPill: View {
    let title: String
    var symbol: String = "checkmark"
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold))
            .foregroundStyle(Theme.secondary)
            .padding(.vertical, 6)
    }
}

/// A set of three frames echoes the three finished edits without stock imagery.
struct EditFramesArtwork: View {
    var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width / 350, geometry.size.height / 300)
            ZStack {
                Rectangle().fill(Theme.actionFill).frame(width: 78 * unit, height: 164 * unit)
                    .rotationEffect(.degrees(-15)).offset(x: -76 * unit, y: 18 * unit)
                Rectangle().fill(Color(red: 0.72, green: 0.70, blue: 0.66)).frame(width: 80 * unit, height: 199 * unit)
                    .rotationEffect(.degrees(8)).offset(y: -3 * unit)
                Rectangle().fill(Color(red: 0.94, green: 0.92, blue: 0.88)).frame(width: 72 * unit, height: 160 * unit)
                    .rotationEffect(.degrees(22)).offset(x: 77 * unit, y: 18 * unit)
                Image(systemName: "play.fill").font(.system(size: 44 * unit)).foregroundStyle(Color(red: 0.15, green: 0.145, blue: 0.13))
                    .offset(x: 7 * unit, y: -2 * unit)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityHidden(true)
    }
}
