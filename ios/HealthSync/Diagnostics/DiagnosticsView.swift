import SwiftUI
import Charts

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var deep = false
    @State private var real = false
    @State private var retain = false
    @State private var custom = false
    @State private var configuration = ""
    @State private var configurationError = ""
    @State private var selected: DiagnosticRunReport?
    var body: some View {
        NavigationStack {
            List {
                if !model.suiteRunning {
                    Section {
                        Toggle("Deep investigation", isOn: $deep)
                        Toggle("Include isolated real upload", isOn: $real)
                        Toggle("Keep private replay on this phone", isOn: $retain)
                        Text("Every enabled metric, full history, record comparisons and saved reports. Keep KROK open and unlocked. Multiple full reads can take an hour or more, and the suite pauses up to 8 minutes before a case if the phone is hot. Apple’s cache cannot be reset.").font(.footnote)
                        Text("Real upload sends private test batches to an authenticated temporary server sandbox. It does not replace synced data. Replay stays on this phone.").font(.footnote)
                        Toggle("Custom experiment configuration", isOn: $custom)
                        if custom {
                            Text("Adjust the saved experiment matrix without another app build. Start with the baseline and keep a final baseline for comparison.").font(.footnote)
                            TextEditor(text: $configuration).font(.caption.monospaced()).frame(minHeight: 180)
                            Button("Load deep defaults") { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; configuration = (try? String(data: encoder.encode(DiagnosticVariant.plan(deep: true)), encoding: .utf8)) ?? "" }
                            if !configurationError.isEmpty { Text(configurationError).foregroundStyle(.red) }
                        }
                        Button("Start full diagnosis") {
                            if custom {
                                do { let variants = try JSONDecoder().decode([DiagnosticVariant].self, from: Data(configuration.utf8)); configurationError = ""; model.runDiagnosticSuite(deep: deep, real: real, retain: retain, variants: variants) }
                                catch { configurationError = "The experiment JSON could not be read. Load defaults and edit their values." }
                            } else { model.runDiagnosticSuite(deep: deep, real: real, retain: retain) }
                        }.accessibilityIdentifier("diagnostics.start")
                        Button("Record next normal sync") { model.recordNextSync(); model.showDiagnostics = false }.accessibilityIdentifier("diagnostics.record")
                    }
                } else {
                    Button("Pause and save completed tests") { model.stopDiagnosticSuite() }
                }
                if let report = model.suiteReport {
                    Section("Current report") { reportContent(report) }
                }
                Section("Saved reports") {
                    ForEach(model.suiteReports) { report in
                        Button { selected = report } label: { VStack(alignment: .leading) { Text(report.preset); Text("\(report.date.formatted()) · \(report.status) · \(report.cases.count) cases").font(.caption) } }
                    }
                }
            }
            .navigationTitle("Sync diagnostics")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.showDiagnostics = false }.disabled(model.suiteRunning) } }
            .onAppear { model.reloadDiagnosticReports() }
            .sheet(item: $selected) { report in NavigationStack { List { reportContent(report) }.navigationTitle("Saved diagnosis").toolbar { Button("Done") { selected = nil } } } }
        }
        .interactiveDismissDisabled(model.suiteRunning)
    }
    @ViewBuilder private func reportContent(_ report: DiagnosticRunReport) -> some View {
        if let gate = report.configuration["accuracyGate"] {
            Text("Accuracy: " + gate).font(.subheadline.bold()).accessibilityIdentifier("diagnostics.accuracy")
        }
        if let last = report.cases.last {
            let phases = last.snapshot.events.filter { $0.name.hasPrefix("phase.") }
            if !phases.isEmpty {
                Chart(Array(phases.enumerated()), id: \.offset) { _, event in
                    BarMark(xStart: .value("Start", event.start), xEnd: .value("End", event.end), y: .value("Phase", event.name))
                }.frame(height: 220).accessibilityLabel("Overlapping phase timeline, elapsed seconds")
                Text("Phase durations overlap. The timeline shows when each starts and finishes.").font(.footnote)
            }
        }
        Text(report.text).font(.caption.monospaced()).textSelection(.enabled).accessibilityIdentifier("diagnostics.report")
        if !model.suiteRunning {
            ShareLink("Share summary", item: report.text)
            ShareLink("Export JSON", item: DiagnosticReportStore().files(report.id)[1])
            ShareLink("Export metric CSV", item: DiagnosticReportStore().files(report.id)[2])
            if report.status == "paused" { Button("Resume remaining cases") { model.runDiagnosticSuite(deep: report.preset == "Deep investigation", real: false, retain: report.configuration["keepCaptures"] == "true", resume: report) } }
            Button("Delete report and private captures", role: .destructive) { model.deleteDiagnosticReport(report); selected = nil }
        }
    }
}
