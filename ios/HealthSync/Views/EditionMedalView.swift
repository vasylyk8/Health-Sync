import SwiftUI
import UIKit

/// Home's main art while a `SpecialEdition` is showing: the medal and, under it, the goal. A tap turns the medal
/// around and opens the picker for the expected finish time; Done (or another tap on the medal) saves it.
struct EditionMedalView: View {
    let edition: SpecialEdition
    /// True while the picker is open; Home hides the number and sync status meanwhile.
    @Binding var editing: Bool
    @EnvironmentObject var model: AppModel
    @State private var hours = 4
    @State private var minutes = 30
    @State private var copied = false

    private static let editingScale: CGFloat = 0.62
    /// The medal rests a little smaller than full size, to leave air for what sits under it.
    private static let restingScale: CGFloat = 0.88

    private var savedSeconds: Int { model.goalSeconds ?? edition.defaultGoalSeconds }
    private var shownSeconds: Int { editing ? edition.goalSeconds(hours: hours, minutes: minutes) : savedSeconds }
    private var scale: CGFloat { editing ? Self.editingScale : Self.restingScale }

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
                caption
                    .padding(.top, 14)
                    // Always as tall as the prompt, so nothing below moves when the goal is set.
                    .frame(minHeight: 14 + 76, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Before a goal: a send-off. After: the question to ask an assistant, as a bubble that copies itself.
    @ViewBuilder private var caption: some View {
        if model.goalSeconds == nil {
            Text(edition.caption)
                .tracking(4.5)
                .smallText(.semibold)
                .foregroundStyle(Theme.muted)
                .accessibilityIdentifier("editionCaption")
        } else {
            let question = edition.prompt(SpecialEdition.timeText(seconds: savedSeconds))
            VStack(spacing: 12) {
                Text(copied ? Copy.Home.copied : Copy.Home.askYourAI)
                    .tracking(4.5)
                    .smallText(.semibold)
                    .foregroundStyle(Theme.muted)
                Button {
                    UIPasteboard.general.string = question
                    Haptics.success()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(Self.emphasised(question, time: SpecialEdition.timeText(seconds: savedSeconds)))
                            .bodyText()
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15, weight: copied ? .bold : .regular))
                            .foregroundStyle(copied ? Theme.ink : Theme.muted)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 14)
                    .padding(.vertical, 12)
                    .background(
                        Theme.surface,
                        in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(question)
                .accessibilityHint("Copies the question, to paste into your AI")
                .accessibilityIdentifier("askPrompt")
            }
        }
    }

    /// The question with the time in semibold.
    private static func emphasised(_ question: String, time: String) -> AttributedString {
        var text = AttributedString(question)
        if let range = text.range(of: time) { text[range].inlinePresentationIntent = .stronglyEmphasized }
        return text
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
