//
//  NoteConflictViews.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import SwiftUI
import RealmSwift

// MARK: - Lock Conflict Alert View

struct LockConflictView: View {
    let lockedBy: String
    let lockedAt: Date
    let bookName: String
    let chapter: Int
    let onAction: (LockAction) -> Void

    private var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lockedAt, relativeTo: Date())
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Note In Use")
                .font(.title2)
                .fontWeight(.semibold)

            Text("\(bookName) \(chapter) is being edited on another device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Text("Last edited \(timeAgo)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(spacing: 12) {
                Button {
                    onAction(.viewReadOnly)
                } label: {
                    Label("View Read-Only", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onAction(.editAnyway)
                } label: {
                    Label("Edit Anyway", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    onAction(.cancel)
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top)
        }
        .padding(24)
    }
}

// MARK: - Conflict Resolution View

struct ConflictResolutionView: View {
    let conflict: NoteConflict
    let bookName: String
    let onResolve: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedVersionId: String?
    @State private var previewContent: String?
    @State private var isLoadingPreview: Bool = false
    @State private var showingPreview: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)

                    Text("Note Conflict")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Two versions of \(bookName) \(conflict.chapter) exist.\nChoose which to keep:")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .padding()

                Divider()

                // Version list
                ScrollView {
                    VStack(spacing: 12) {
                        // Current version
                        VersionCard(
                            title: "This Device",
                            version: conflict.currentVersion,
                            isSelected: selectedVersionId == conflict.currentVersion.id,
                            onSelect: { selectedVersionId = conflict.currentVersion.id },
                            onPreview: { await loadPreview(for: conflict.currentVersion) }
                        )

                        // Conflict versions
                        ForEach(conflict.conflictVersions) { version in
                            VersionCard(
                                title: "Other Version",
                                version: version,
                                isSelected: selectedVersionId == version.id,
                                onSelect: { selectedVersionId = version.id },
                                onPreview: { await loadPreview(for: version) }
                            )
                        }
                    }
                    .padding()
                }

                Divider()

                // Actions
                VStack(spacing: 12) {
                    Button {
                        if let versionId = selectedVersionId {
                            onResolve(versionId)
                        }
                    } label: {
                        Text("Keep Selected")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedVersionId == nil)

                    Button("Cancel", role: .cancel) {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingPreview) {
                PreviewSheet(content: previewContent ?? "", isLoading: isLoadingPreview)
            }
        }
    }

    private func loadPreview(for version: NoteVersion) async {
        isLoadingPreview = true
        showingPreview = true

        do {
            previewContent = try await version.content()
        } catch {
            previewContent = "Failed to load preview: \(error.localizedDescription)"
        }

        isLoadingPreview = false
    }
}

struct VersionCard: View {
    let title: String
    let version: NoteVersion
    let isSelected: Bool
    let onSelect: () -> Void
    let onPreview: () async -> Void

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: version.modified)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? .accentColor : .secondary)

                        Text(title)
                            .fontWeight(.medium)
                    }

                    Text("Modified: \(formattedDate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if version.contentLength > 0 {
                        Text("Size: \(version.contentLength) bytes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button {
                    Task { await onPreview() }
                } label: {
                    Text("Preview")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

struct PreviewSheet: View {
    let content: String
    let isLoading: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading preview...")
                } else {
                    ScrollView {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Lock Conflict") {
    LockConflictView(
        lockedBy: "ABC123",
        lockedAt: Date().addingTimeInterval(-120),
        bookName: "John",
        chapter: 3,
        onAction: { _ in }
    )
}

#Preview("Conflict Resolution") {
    ConflictResolutionView(
        conflict: NoteConflict(
            id: "43-3",
            book: 43,
            chapter: 3,
            currentVersion: NoteVersion(
                id: "current",
                modified: Date(),
                contentLength: 847,
                isCurrentVersion: true,
                content: { "Sample content from this device..." }
            ),
            conflictVersions: [
                NoteVersion(
                    id: "other",
                    modified: Date().addingTimeInterval(-300),
                    contentLength: 623,
                    isCurrentVersion: false,
                    content: { "Sample content from other device..." }
                )
            ]
        ),
        bookName: "John",
        onResolve: { _ in },
        onCancel: {}
    )
}
