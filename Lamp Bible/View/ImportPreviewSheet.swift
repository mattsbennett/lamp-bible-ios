//
//  ImportPreviewSheet.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-18.
//

import SwiftUI

/// Sheet showing a preview of a .lamp file before importing
struct ImportPreviewSheet: View {
    let preview: LampFilePreview
    var devotionalModules: [Module] = []
    var defaultModuleId: String = "devotionals"
    let onImport: (String) -> Void  // Takes selected module ID
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedModuleId: String = ""

    /// Whether this is a devotional import that needs module selection
    private var isDevotionalImport: Bool {
        preview.type == .devotional || preview.type == .devotionalBundle || preview.type == .devotionalModule
    }

    /// Available modules for the picker (filters to devotional type)
    private var availableModules: [Module] {
        devotionalModules.filter { $0.type == .devotional }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header with icon and type
                    HStack(spacing: 16) {
                        Image(systemName: preview.type.iconName)
                            .font(.system(size: 40))
                            .foregroundColor(.accentColor)
                            .frame(width: 60, height: 60)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(12)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(preview.type.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)

                            Text(preview.title)
                                .font(.title2)
                                .fontWeight(.bold)

                            if let subtitle = preview.subtitle {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)

                    // Metadata
                    if hasMetadata {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Details")
                                .font(.headline)

                            if let author = preview.author {
                                metadataRow(label: "Author", value: author, icon: "person")
                            }

                            if let date = preview.date {
                                metadataRow(label: "Date", value: date, icon: "calendar")
                            }

                            if let category = preview.category {
                                metadataRow(label: "Category", value: category.displayName, icon: "folder")
                            }

                            if let tags = preview.tags, !tags.isEmpty {
                                HStack(alignment: .top) {
                                    Image(systemName: "tag")
                                        .foregroundColor(.secondary)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Tags")
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        FlowLayout(spacing: 6) {
                                            ForEach(tags, id: \.self) { tag in
                                                Text(tag)
                                                    .font(.caption)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.accentColor.opacity(0.1))
                                                    .foregroundColor(.accentColor)
                                                    .cornerRadius(6)
                                            }
                                        }
                                    }
                                }
                            }

                            if let exportDate = preview.exportDateFormatted {
                                metadataRow(label: "Shared", value: exportDate, icon: "clock")
                            }
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                    }

                    // Content preview for single devotional
                    if let devotional = preview.devotional {
                        contentPreview(devotional)
                    }

                    // Module contents preview
                    if let moduleFile = preview.moduleFile {
                        moduleContentsPreview(moduleFile)
                    }

                    // Module selector for devotional imports
                    if isDevotionalImport && !availableModules.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Import to")
                                .font(.headline)

                            Picker("Devotional Module", selection: $selectedModuleId) {
                                ForEach(availableModules, id: \.id) { module in
                                    Text(module.name).tag(module.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                    }

                    Spacer(minLength: 80)
                }
                .padding()
            }
            .navigationTitle("Import Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onImport(selectedModuleId)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                // Initialize selected module to default or first available
                if selectedModuleId.isEmpty {
                    if availableModules.contains(where: { $0.id == defaultModuleId }) {
                        selectedModuleId = defaultModuleId
                    } else if let first = availableModules.first {
                        selectedModuleId = first.id
                    } else {
                        selectedModuleId = defaultModuleId
                    }
                }
            }
        }
    }

    private var hasMetadata: Bool {
        preview.author != nil ||
        preview.date != nil ||
        preview.category != nil ||
        (preview.tags != nil && !preview.tags!.isEmpty) ||
        preview.exportDate != nil
    }

    private func metadataRow(label: String, value: String, icon: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.subheadline)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func contentPreview(_ devotional: Devotional) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.headline)

            // Show summary or first paragraph
            if let summary = devotional.summary {
                switch summary {
                case .plain(let text):
                    Text(text)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(5)
                case .annotated(let annotated):
                    Text(annotated.text)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(5)
                }
            } else {
                // Get first paragraph from content
                if let firstParagraph = getFirstParagraph(devotional) {
                    Text(firstParagraph)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(5)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func getFirstParagraph(_ devotional: Devotional) -> String? {
        switch devotional.content {
        case .blocks(let blocks):
            for block in blocks {
                if block.type == .paragraph, let content = block.content {
                    return content.text
                }
            }
        case .structured(let structured):
            if let intro = structured.introduction?.first,
               intro.type == .paragraph,
               let content = intro.content {
                return content.text
            }
        }
        return nil
    }

    @ViewBuilder
    private func moduleContentsPreview(_ moduleFile: DevotionalModuleFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contents")
                .font(.headline)

            ForEach(Array(moduleFile.entries.prefix(5).enumerated()), id: \.offset) { index, entry in
                HStack {
                    Text("\(index + 1).")
                        .foregroundColor(.secondary)
                        .frame(width: 24)
                    Text(entry.meta.title)
                        .lineLimit(1)
                    Spacer()
                    if let date = entry.meta.date {
                        Text(date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if moduleFile.entries.count > 5 {
                Text("+ \(moduleFile.entries.count - 5) more...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 28)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// Note: FlowLayout is defined in ToolPanelView.swift

#Preview {
    ImportPreviewSheet(
        preview: LampFilePreview(
            type: .devotional,
            devotional: Devotional(
                meta: DevotionalMeta(
                    id: "test",
                    title: "Walking by Faith",
                    subtitle: "A morning reflection",
                    author: "John Smith",
                    date: "2025-01-18",
                    tags: ["faith", "prayer", "morning"],
                    category: .devotional
                ),
                content: .blocks([
                    DevotionalContentBlock(
                        type: .paragraph,
                        content: DevotionalAnnotatedText(text: "This is a sample devotional about walking by faith in our daily lives. The journey of faith is not always easy, but it is always worthwhile.")
                    )
                ])
            ),
            exportDate: Date()
        ),
        onImport: { _ in },
        onCancel: {}
    )
}
