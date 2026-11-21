import SwiftUI

/// One text field per detected speaker label. Applying calls `rename-speakers`,
/// which rewrites the transcript (summaries don't use labels, so no re-run).
struct SpeakerNamingView: View {
    @Environment(Library.self) private var library
    let labels: [String]
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Name speakers", systemImage: "person.2.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(labels, id: \.self) { label in
                HStack {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    TextField("Name", text: binding(for: label))
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Apply") { library.applySpeakerNames(names) }
                    .buttonStyle(.borderedProminent)
                Button("Skip") { library.speakersNamed = true }
                    .buttonStyle(.bordered)
            }
            .font(.callout)
        }
    }

    private func binding(for label: String) -> Binding<String> {
        Binding(
            get: { names[label] ?? "" },
            set: { names[label] = $0 }
        )
    }
}
