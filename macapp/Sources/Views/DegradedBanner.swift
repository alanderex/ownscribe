import SwiftUI

/// Says that the app runs on an older CLI than it expects, and why.
struct DegradedBanner: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        switch engine.upgrade {
        case .none:
            EmptyView()
        case .pending:
            banner(
                "Update pending · waiting for running jobs",
                detail: "Recording works. Meeting details return after the update.",
                retry: false
            )
        case .failed(let reason):
            banner("Update failed", detail: reason, retry: true)
        }
    }

    private func banner(_ title: String, detail: String, retry: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: retry ? "exclamationmark.triangle.fill" : "clock")
                .foregroundStyle(retry ? .orange : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if retry {
                Button("Retry", action: engine.retryUpgrade)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
