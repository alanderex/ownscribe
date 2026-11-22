import SwiftUI

/// A failure the user has to see: setup, a missing permission, or a failed run.
/// Back dismisses it.
struct FailedView: View {
    @Environment(Engine.self) private var engine
    @Environment(Jobs.self) private var jobs
    let message: String
    let permission: Engine.PermissionFailure?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                permission != nil ? "Permission needed" : "Something went wrong",
                systemImage: permission != nil
                    ? "lock.shield" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let permission {
                    Button("Open Settings") { permission.openSettings() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Back") {
                    engine.setupFailure = nil
                    engine.permissionFailure = nil
                    jobs.dismissFailure()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
