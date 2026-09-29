import SwiftUI

/// Simplified drawings of what the user will see on the assistant's website. Drawn (not
/// screenshots) so they stay roughly right when the real pages change.
struct IllustrationView: View {
    let kind: AIProvider.Illustration
    let tint: Color

    var body: some View {
        Group {
            switch kind {
            case .copyLink:
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(tint)
                    Text("https://…/mcp/•••••••••").font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "doc.on.doc").foregroundStyle(tint)
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
            case .openSettings(let site, let path):
                browser(site: site) {
                    HStack(spacing: 6) {
                        ForEach(Array(path.enumerated()), id: \.offset) { i, item in
                            if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                            Text(item)
                                .font(.caption.weight(i == path.count - 1 ? .bold : .regular))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(i == path.count - 1 ? tint.opacity(0.15) : .clear, in: Capsule())
                        }
                    }
                }
            case .addConnector(let site, let button, let fields):
                browser(site: site) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(button)
                            .font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(tint, in: Capsule())
                        ForEach(fields, id: \.self) { field in
                            Text(field)
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    private func browser<Content: View>(site: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3) { _ in Circle().fill(.quaternary).frame(width: 7, height: 7) }
                Text(site).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .frame(maxWidth: .infinity)
            }
            content()
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}
