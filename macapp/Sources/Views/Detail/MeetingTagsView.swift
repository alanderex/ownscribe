import SwiftUI

/// The meeting's tags under its title: × removes one, "+ Tag" adds one and suggests
/// the library's tags while typing. Each change runs `ownscribe tag`, and the chips
/// follow once the library is listed again.
struct MeetingTagsView: View {
    @Environment(Library.self) private var library
    let row: LibraryRow
    /// Why the tags cannot change now (a job works on the meeting); nil when they can.
    let readOnlyReason: String?

    @State private var isAdding = false
    @State private var typed = ""
    @State private var isSaving = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WrappingHStack(spacing: 6, lineSpacing: 6) {
                ForEach(row.tags, id: \.self) { tag in
                    TagChip(name: tag, remove: canEdit ? { change(remove: [tag]) } : nil)
                }
                Button {
                    typed = ""
                    isAdding = true
                } label: {
                    Label("Tag", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!canEdit)
                .help(readOnlyReason ?? "Add a tag")
                .popover(isPresented: $isAdding, arrowEdge: .bottom) { addPopover }
                if isSaving {
                    ProgressView().controlSize(.small)
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onChange(of: row.path) { problem = nil }
    }

    private var canEdit: Bool { readOnlyReason == nil && !isSaving }

    private var addPopover: some View {
        let suggestions = TagSuggestions.suggest(typed, from: library.tags, excluding: row.tags)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Tag", text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { add(typed) }
            if !suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) { add(name) }
                                .buttonStyle(.borderless)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            Text("Return adds what you typed; a tag the library has keeps its spelling.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private func add(_ text: String) {
        let tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        isAdding = false
        change(add: [tag])
    }

    private func change(add: [String] = [], remove: [String] = []) {
        isSaving = true
        problem = nil
        Task {
            problem = await library.editTags(of: row, add: add, remove: remove)
            isSaving = false
        }
    }
}

private struct TagChip: View {
    let name: String
    /// nil while the tags cannot change.
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove tag \(name)")
                .help("Remove “\(name)”")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tag \(name)")
    }
}

/// Lays its children out left to right, starting a new row when the next one does
/// not fit.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthWithIt = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if widthWithIt > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = widthWithIt
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
