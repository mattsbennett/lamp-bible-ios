//
//  AudioRecorderSheet.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import SwiftUI

/// Sheet for recording audio for devotionals
struct AudioRecorderSheet: View {
    @Binding var isPresented: Bool
    let onRecordingComplete: (URL) -> Void

    @StateObject private var recorder = AudioRecorder()
    @State private var showPermissionAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()

                // Live waveform during recording
                if recorder.isRecording {
                    LiveWaveformView(level: recorder.audioLevel, color: .red)
                        .frame(height: 60)
                        .padding(.horizontal)
                }

                // Time display
                Text(AudioRecorder.formatTime(recorder.recordingTime))
                    .font(.system(size: 56, weight: .light, design: .monospaced))
                    .foregroundColor(recorder.isRecording ? .red : .primary)

                // Status text
                if recorder.isRecording {
                    Text("Recording...")
                        .font(.headline)
                        .foregroundColor(.red)
                } else if recorder.recordingURL != nil {
                    Text("Recording complete")
                        .font(.headline)
                        .foregroundColor(.green)
                } else {
                    Text("Tap to start recording")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Record button
                Button {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        recorder.start()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(recorder.isRecording ? Color.red : Color.accentColor)
                            .frame(width: 80, height: 80)

                        if recorder.isRecording {
                            // Stop icon (square)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white)
                                .frame(width: 28, height: 28)
                        } else {
                            // Record icon (circle)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 64, height: 64)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 20)

                // Re-record button (when recording complete)
                if !recorder.isRecording && recorder.recordingURL != nil {
                    Button {
                        recorder.cancel()
                    } label: {
                        Label("Record Again", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Record Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.cancel()
                        isPresented = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if let url = recorder.recordingURL, !recorder.isRecording {
                        Button("Use") {
                            onRecordingComplete(url)
                            isPresented = false
                        }
                    }
                }
            }
        }
        .onChange(of: recorder.permissionDenied) { _, denied in
            if denied {
                showPermissionAlert = true
            }
        }
        .alert("Microphone Access Required", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {
                isPresented = false
            }
        } message: {
            Text("Please enable microphone access in Settings to record audio.")
        }
    }
}

/// Audio file import picker
struct AudioFilePicker: View {
    @Binding var isPresented: Bool
    let onAudioSelected: (URL) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        // Will trigger the fileImporter
                    } label: {
                        Label("Import Audio File", systemImage: "waveform")
                    }
                } footer: {
                    Text("Supported formats: M4A, MP3, WAV, AAC")
                }
            }
            .navigationTitle("Import Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
        .fileImporter(
            isPresented: .constant(true),
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Need to access security-scoped resource
            guard url.startAccessingSecurityScopedResource() else { return }

            // Copy to temp directory so we can access it later
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)

            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
                url.stopAccessingSecurityScopedResource()
                onAudioSelected(tempURL)
                isPresented = false
            } catch {
                print("[AudioFilePicker] Copy error: \(error.localizedDescription)")
                url.stopAccessingSecurityScopedResource()
            }

        case .failure(let error):
            print("[AudioFilePicker] Import error: \(error.localizedDescription)")
            isPresented = false
        }
    }
}

// MARK: - Preview

#Preview {
    AudioRecorderSheet(isPresented: .constant(true)) { _ in }
}
