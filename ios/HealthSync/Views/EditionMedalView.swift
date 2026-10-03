import SwiftUI

/// Home's main art while a `SpecialEdition` is showing: the medal and, under it, the goal. A tap turns the medal
/// around and opens the picker for the expected finish time; Done (or another tap on the medal) saves it.
struct EditionMedalView: View {
    let edition: SpecialEdition
    /// True while the picker is open; Home hides the number and sync status meanwhile.
    @Binding var editing: Bool
    @EnvironmentObject var model: AppModel
    @State private var hours = 4
    @State private var minutes = 30

    private static let editingScale: CGFloat = 0.62

    private var savedSeconds: Int { model.goalSeconds ?? edition.defaultGoalSeconds }
    private var shownSeconds: Int { editing ? edition.goalSeconds(hours: hours, minutes: minutes) : savedSeconds }
    private var scale: CGFloat { editing ? Self.editingScale : 1 }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                VStack(spacing: 0) {
                    MedalView(edition: edition, timeText: SpecialEdition.timeText(seconds: shownSeconds), showingBack: editing)
                        .scaleEffect(scale, anchor: .top)
                        .frame(height: 290 * scale, alignment: .top)
                    shadow
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(editing ? "Save your finish time" : "\(edition.raceName) medal")
            .accessibilityHint(editing ? "" : "Opens the expected finish time")
            .accessibilityIdentifier("editionMedal")

            if editing {
                picker
                    .padding(.top, 16)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else {
                Text(model.goalSeconds == nil ? edition.caption : "GOAL \(SpecialEdition.timeText(seconds: savedSeconds))")
                    .tracking(4.5)
                    .smallText(.semibold)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 14)
                    .accessibilityIdentifier("editionCaption")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var shadow: some View {
        Ellipse()
            .fill(Theme.ink.opacity(0.12))
            .frame(width: 150 * scale, height: 14)
            .blur(radius: 5)
            .padding(.top, 4)
            .accessibilityHidden(true)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Expected finish time")
                .headlineText()
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Your AI can use it to help you prepare for race day.")
                .smallText()
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)
                .padding(.bottom, 8)
            HStack(spacing: 8) {
                Picker("Hours", selection: $hours) {
                    ForEach(Array(edition.hours), id: \.self) { Text("\($0) hours").tag($0) }
                }
                .accessibilityIdentifier("goalHours")
                Picker("Minutes", selection: $minutes) {
                    ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) }
                }
                .accessibilityIdentifier("goalMinutes")
            }
            .pickerStyle(.wheel)
            .frame(height: 150)
            .clipped()
            Button("Done", action: toggle)
                .buttonStyle(StepActionStyle(filled: false))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .accessibilityIdentifier("editionDone")
        }
    }

    private func toggle() {
        if editing {
            model.saveGoal(seconds: edition.goalSeconds(hours: hours, minutes: minutes))
        } else {
            let s = savedSeconds
            hours = min(max(s / 3600, edition.hours.lowerBound), edition.hours.upperBound)
            minutes = s / 60 % 60
        }
        withAnimation(.easeInOut(duration: 0.6)) { editing.toggle() }
    }
}
