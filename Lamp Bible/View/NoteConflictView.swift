//
//  NoteConflictView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-09.
//

import SwiftUI
import UIKit

/// View for resolving note sync conflicts
struct NoteConflictView: View {
    @ObservedObject var syncManager = ModuleSyncManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if syncManager.pendingConflicts.isEmpty {
                ContentUnavailableView(
                    "No Conflicts",
                    systemImage: "checkmark.circle",
                    description: Text("All notes are in sync")
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
                        Text("The same notes were edited on multiple devices. Choose which version to keep for each conflict.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Bulk actions
                    Section {
                        Button {
                            syncManager.resolveAllConflicts(resolution: .keepLocal)
                        } label: {
                            Label("Keep All Local", systemImage: "iphone")
                        }

                        Button {
                            syncManager.resolveAllConflicts(resolution: .keepCloud)
                        } label: {
                            Label("Keep All From Cloud", systemImage: "icloud")
                        }
                    } header: {
                        Text("Resolve All (\(syncManager.pendingConflicts.count) conflicts)")
                    }

                    // Individual conflicts
                    Section {
                        ForEach(syncManager.pendingConflicts) { conflict in
                            ConflictRowView(conflict: conflict)
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

/// Row view for a single conflict
struct ConflictRowView: View {
    let conflict: NoteConflict
    @State private var showingDetail = false

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(conflict.locationDescription)
                    .font(.headline)
                    .foregroundColor(.primary)

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
            ConflictDetailView(conflict: conflict)
        }
    }
}

/// Detail view showing both versions of a conflict
struct ConflictDetailView: View {
    let conflict: NoteConflict
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var syncManager = ModuleSyncManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Location header
                    Text(conflict.locationDescription)
                        .font(.title2)
                        .fontWeight(.bold)
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

                        Text(conflict.localEntry.content)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)

                        Button {
                            syncManager.resolveConflict(conflict, resolution: .keepLocal)
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

                        Text(conflict.cloudEntry.content)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)

                        Button {
                            syncManager.resolveConflict(conflict, resolution: .keepCloud)
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
                            syncManager.resolveConflict(conflict, resolution: .keepBoth)
                            dismiss()
                        } label: {
                            Label("Keep Both Versions", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Text("The cloud version will be added as a separate note marked \"[From other device]\"")
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

#Preview {
    NoteConflictView()
}
