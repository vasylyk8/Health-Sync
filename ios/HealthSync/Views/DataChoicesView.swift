import SwiftUI

/// Which groups of Apple Health data KROK reads and shares with the connected assistants.
/// Workouts, activity, sleep and recovery are always on; the other groups start on and can be switched off here.
struct DataChoicesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: Copy.Choices.title) { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Copy.Choices.header)
                        .smallText()
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                    ForEach(model.optionalCategories) { category in
                        Toggle(isOn: binding(category.id)) {
                            Text(category.label)
                                .bodyText()
                                .foregroundStyle(Theme.ink)
                        }
                        .tint(Theme.ink)
                        .disabled(model.busy)
                        .frame(minHeight: 52)
                        .accessibilityIdentifier("category.\(category.id)")
                        Divider().overlay(Theme.track)
                    }
                    Text(Copy.Choices.footer)
                        .smallText()
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, Theme.margin)
        .background(Theme.background.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.sheetRadius)
        .presentationBackground(Theme.background)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.isEnabled(id) }, set: { on in Task { await model.setCategory(id, on: on) } })
    }
}
