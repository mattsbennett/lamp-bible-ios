//
//  DevotionalConflictView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import SwiftUI
import UIKit

/// View for resolving devotional sync conflicts
struct DevotionalConflictView: View {
    @ObservedObject var syncManager = ModuleSyncManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if syncManager.pendingDevotionalConflicts.isEmpty {
                ContentUnavailableView(
                    "No Conflicts",
                    systemImage: "checkmark.circle",
                    description: Text("All devotionals are in sync")
                )
                .navigationTitle("Sync Conflicts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            } else {
                List {
                    Section {
                        Text("The same devotionals were edited on multiple devices. Choose which version to keep for each conflict.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Bulk actions
                    Section {
                        Button {
                            syncManager.resolveAllDevotionalConflicts(resolution: .keepLocal)
                        } label: {
                            Label("Keep All Local", systemImage: "iphone")
                        }

                        Button {
                            syncManager.resolveAllDevotionalConflicts(resolution: .keepCloud)
                        } label: {
                            Label("Keep All From Cloud", systemImage: "icloud")
                        }
                    } header: {
                        Text("Resolve All (\(syncManager.pendingDevotionalConflicts.count) conflicts)")
                    }

                    // Individual conflicts
                    Section {
                        ForEach(syncManager.pendingDevotionalConflicts) { conflict in
                            DevotionalConflictRowView(conflict: conflict)
                        }
                    } header: {
                        Text("Individual Conflicts")
                    }
                }
                .navigationTitle("Sync Conflicts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
}

/// Row view for a single devotional conflict
struct DevotionalConflictRowView: View {
    let conflict: DevotionalConflict
    @State private var showingDetail = false

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(conflict.localEntry.meta.title)
                    .font(.headline)
                    .foregroundColor(.primary)

                if let subtitle = conflict.localEntry.meta.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 16) {
                    if let localDate = conflict.localDate {
                        Label(localDate.formatted(date: .abbreviated, time: .shortened), systemImage: "iphone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let cloudDate = conflict.cloudDate {
                        Label(cloudDate.formatted(date: .abbreviated, time: .shortened), systemImage: "icloud")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showingDetail) {
            DevotionalConflictDetailView(conflict: conflict)
        }
    }
}

/// Detail view showing both versions of a devotional conflict
struct DevotionalConflictDetailView: View {
    let conflict: DevotionalConflict
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var syncManager = ModuleSyncManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Title header
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conflict.localEntry.meta.title)
                            .font(.title2)
                            .fontWeight(.bold)
                        if let subtitle = conflict.localEntry.meta.subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                    // Local version
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundColor(.blue)
                            Text("This Device")
                                .font(.headline)
                            Spacer()
                            if let date = conflict.localDate {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        DevotionalPreviewContent(devotional: conflict.localEntry)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)

                        Button {
                            syncManager.resolveDevotionalConflict(conflict, resolution: .keepLocal)
                            dismiss()
                        } label: {
                            Label("Keep This Version", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)

                    // Cloud version
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "icloud")
                                .foregroundColor(.cyan)
                            Text("Other Device")
                                .font(.headline)
                            Spacer()
                            if let date = conflict.cloudDate {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        DevotionalPreviewContent(devotional: conflict.cloudEntry)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)

                        Button {
                            syncManager.resolveDevotionalConflict(conflict, resolution: .keepCloud)
                            dismiss()
                        } label: {
                            Label("Keep This Version", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)

                    // Keep both option
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                            .padding(.vertical, 8)

                        Button {
                            syncManager.resolveDevotionalConflict(conflict, resolution: .keepBoth)
                            dismiss()
                        } label: {
                            Label("Keep Both Versions", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Text("The cloud version will be added as a separate devotional marked \"[From other device]\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Resolve Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Preview content for a devotional in conflict view
struct DevotionalPreviewContent: View {
    let devotional: Devotional

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Metadata
            HStack(spacing: 12) {
                if let date = devotional.meta.date {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let category = devotional.meta.category {
                    Text(category.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }
            }

            // Tags
            if let tags = devotional.meta.tags, !tags.isEmpty {
                HStack {
                    ForEach(tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(3)
                    }
                    if tags.count > 3 {
                        Text("+\(tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Summary preview
            if let summary = devotional.summary {
                switch summary {
                case .plain(let text):
                    Text(text)
                        .font(.body)
                        .lineLimit(3)
                case .annotated(let annotated):
                    Text(annotated.text)
                        .font(.body)
                        .lineLimit(3)
                }
            } else {
                // Show beginning of content if no summary
                Text(extractContentPreview(devotional.content))
                    .font(.body)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func extractContentPreview(_ content: DevotionalContent) -> String {
        switch content {
        case .blocks(let blocks):
            return extractTextFromBlocks(blocks)
        case .structured(let structured):
            if let intro = structured.introduction {
                return extractTextFromBlocks(intro)
            }
            if let sections = structured.sections, let first = sections.first {
                if let blocks = first.blocks {
                    return extractTextFromBlocks(blocks)
                }
            }
            return ""
        }
    }

    private func extractTextFromBlocks(_ blocks: [DevotionalContentBlock]) -> String {
        for block in blocks {
            if let content = block.content, !content.text.isEmpty {
                return content.text
            }
        }
        return ""
    }
}

#Preview {
    DevotionalConflictView()
}
