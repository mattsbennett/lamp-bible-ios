import SwiftUI

/// Reader for bundled and user-installed long-form book modules.
struct BookModuleView: View {
    let moduleId: String
    var initialSectionId: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var book: BookModule?
    @State private var sections: [BookSection] = []
    @State private var selectedSectionId: String?
    @State private var loadError: String?

    private var selectedSection: BookSection? {
        sections.first { $0.id == selectedSectionId }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Unable to Open Book",
                        systemImage: "book.closed",
                        description: Text(loadError)
                    )
                } else if let book, let section = selectedSection {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            BookSectionContentView(section: section)
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding()
                        .frame(maxWidth: .infinity)
                    }
                    .environment(\.layoutDirection, book.textDirection == "rtl" ? .rightToLeft : .leftToRight)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(book?.title ?? "Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !sections.isEmpty {
                        Menu {
                            ForEach(sections) { section in
                                Button {
                                    selectedSectionId = section.id
                                } label: {
                                    Label(
                                        section.title,
                                        systemImage: section.id == selectedSectionId ? "checkmark" : "doc.text"
                                    )
                                }
                            }
                        } label: {
                            Label("Contents", systemImage: "list.bullet")
                        }
                    }
                }
            }
        }
        .task(id: moduleId) {
            loadBook()
        }
    }

    private func loadBook() {
        do {
            if let userBook = try ModuleDatabase.shared.getBookModule(id: moduleId) {
                book = userBook
                sections = try ModuleDatabase.shared.getBookSections(moduleId: moduleId)
            } else if let bundledBook = try BundledModuleDatabase.shared.getBookModule(id: moduleId) {
                book = bundledBook
                sections = try BundledModuleDatabase.shared.getBookSections(moduleId: moduleId)
            } else {
                loadError = "The book module is no longer available."
                return
            }

            selectedSectionId = sections.contains { $0.id == initialSectionId }
                ? initialSectionId
                : sections.first?.id
            if sections.isEmpty {
                loadError = "This book does not contain any sections."
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct BookSectionContentView: View {
    let section: BookSection

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                if let number = section.number, !number.isEmpty {
                    Text(number.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(section.title)
                    .font(.largeTitle.bold())
                if let subtitle = section.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            if !section.keyScriptures.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(section.keyScriptures, id: \.self) { reference in
                            Text(reference.label ?? formatReference(reference))
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.secondary.opacity(0.14), in: Capsule())
                        }
                    }
                }
            }

            ForEach(Array(section.contentBlocks.enumerated()), id: \.offset) { _, block in
                BookContentBlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }

    private func formatReference(_ range: BookScriptureRange) -> String {
        func components(_ value: Int) -> (String, Int, Int) {
            let bookNumber = value / 1_000_000
            let chapter = (value % 1_000_000) / 1_000
            let verse = value % 1_000
            let name = (try? BundledModuleDatabase.shared.getBook(id: bookNumber))?.name ?? "Book \(bookNumber)"
            return (name, chapter, verse)
        }

        let start = components(range.sv)
        guard let endValue = range.ev, endValue != range.sv else {
            return "\(start.0) \(start.1):\(start.2)"
        }
        let end = components(endValue)
        if start.0 == end.0 && start.1 == end.1 {
            return "\(start.0) \(start.1):\(start.2)–\(end.2)"
        }
        return "\(start.0) \(start.1):\(start.2)–\(end.0) \(end.1):\(end.2)"
    }
}

private struct BookContentBlockView: View {
    let block: BookContentBlock

    @ViewBuilder
    var body: some View {
        switch block.type {
        case "heading":
            Text(block.content?.text ?? "")
                .font(headingFont)
                .fontWeight(.semibold)
                .padding(.top, 6)
        case "blockquote":
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                Text(block.content?.text ?? "")
                    .italic()
                    .foregroundStyle(.secondary)
            }
        case "list":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { index, item in
                    BookListItemView(
                        item: item,
                        marker: block.listType == "numbered" ? "\(index + 1)." : "•"
                    )
                }
            }
        case "thematic-break":
            Divider().padding(.vertical, 8)
        case "image":
            mediaPlaceholder(icon: "photo", label: "Image")
        case "audio":
            mediaPlaceholder(icon: "waveform", label: "Audio")
        default:
            Text(block.content?.text ?? "")
                .font(.body)
                .lineSpacing(5)
        }
    }

    private var headingFont: Font {
        switch block.level ?? 2 {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }

    private func mediaPlaceholder(icon: String, label: String) -> some View {
        VStack(spacing: 8) {
            Label(label, systemImage: icon)
                .font(.headline)
            if let caption = block.caption?.text, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct BookListItemView: View {
    let item: BookListItem
    let marker: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).frame(minWidth: 20, alignment: .trailing)
                Text(item.content.text).lineSpacing(4)
            }
            ForEach(Array((item.children ?? []).enumerated()), id: \.offset) { _, child in
                BookListItemView(item: child, marker: "•")
                    .padding(.leading, 24)
            }
        }
    }
}
