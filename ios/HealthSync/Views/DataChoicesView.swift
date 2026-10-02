import SwiftUI

/// Settings: which groups of Apple Health data KROK reads and shares with the connected assistants.
/// Workouts, activity, sleep and recovery are always on; every other group is off until switched on here.
struct DataChoicesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.optionalCategories) { category in
                        Toggle(category.label, isOn: binding(category.id))
                            .disabled(model.busy)
                            .accessibilityIdentifier("category.\(category.id)")
                    }
                } header: {
                    Text("Share more with your assistant")
                } footer: {
                    Text("Each group is off until you switch it on, and Apple Health asks you separately. Switching a group off deletes its data from KROK's servers. Assistants describe your data and trends; they don't give medical advice.")
                }
            }
            .navigationTitle("Your data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.isEnabled(id) }, set: { on in Task { await model.setCategory(id, on: on) } })
    }
}
