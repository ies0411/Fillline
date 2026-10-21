import SwiftUI

/// The menu bar label. It shows only real values: providers without data are omitted,
/// and last-known values carry a `~` until a fresh poll succeeds.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let content = model.menuBarContent

        HStack(spacing: 4) {
            if content.showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
            }

            if content.isEmpty {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .regular))
            } else {
                ForEach(Array(content.segments.enumerated()), id: \.element.id) { index, segment in
                    if index > 0 {
                        Text("·")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    HStack(spacing: 2) {
                        if let symbolName = segment.symbolName {
                            Image(systemName: symbolName)
                                .font(.system(size: 9, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        Text(segment.text)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(content.accessibilityLabel))
        .task { model.start() }
    }
}
