//
//  ImagePickerSheet.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import SwiftUI
import PhotosUI
import UIKit

/// Sheet for selecting or capturing images for devotionals
struct ImagePickerSheet: View {
    @Binding var isPresented: Bool
    let onImageSelected: (UIImage) -> Void

    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isLoadingImage = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Use PhotosPicker directly as a view instead of modifier
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showCamera = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                    }

                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Import from Files", systemImage: "folder")
                    }
                }

                if isLoadingImage {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading image...")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            print("[ImagePickerSheet] selectedPhotoItem changed: \(newItem != nil ? "has item" : "nil")")
            if let item = newItem {
                loadImage(from: item)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker { image in
                print("[ImagePickerSheet] Camera captured image: \(image.size)")
                onImageSelected(image)
                isPresented = false
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    private func loadImage(from item: PhotosPickerItem) {
        print("[ImagePickerSheet] loadImage called")
        isLoadingImage = true
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    print("[ImagePickerSheet] Got data, size: \(data.count) bytes")
                    if let image = UIImage(data: data) {
                        print("[ImagePickerSheet] Image created, size: \(image.size)")
                        await MainActor.run {
                            isLoadingImage = false
                            print("[ImagePickerSheet] Calling onImageSelected callback")
                            onImageSelected(image)
                            // Small delay to ensure callback completes before dismissing
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isPresented = false
                            }
                        }
                    } else {
                        print("[ImagePickerSheet] Failed to create UIImage from data")
                        await MainActor.run { isLoadingImage = false }
                    }
                } else {
                    print("[ImagePickerSheet] Failed to load data from PhotosPickerItem")
                    await MainActor.run { isLoadingImage = false }
                }
            } catch {
                print("[ImagePickerSheet] Error loading image: \(error)")
                await MainActor.run { isLoadingImage = false }
            }
            // Clear selection to allow selecting same image again
            await MainActor.run {
                selectedPhotoItem = nil
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            print("[ImagePickerSheet] File import: \(url.lastPathComponent)")

            // Need to access security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                print("[ImagePickerSheet] Failed to access security-scoped resource")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                print("[ImagePickerSheet] File imported successfully, size: \(image.size)")
                onImageSelected(image)
                isPresented = false
            } else {
                print("[ImagePickerSheet] Failed to load image from file")
            }

        case .failure(let error):
            print("[ImagePickerSheet] File import error: \(error.localizedDescription)")
        }
    }
}

/// UIKit wrapper for camera image capture
struct CameraImagePicker: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraImagePicker

        init(_ parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImageCaptured(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Image Alignment Picker

/// Picker for selecting image alignment in edit mode
struct ImageAlignmentPicker: View {
    @Binding var alignment: ImageAlignment

    var body: some View {
        Picker("Alignment", selection: $alignment) {
            Image(systemName: "text.alignleft")
                .tag(ImageAlignment.left)
            Image(systemName: "text.aligncenter")
                .tag(ImageAlignment.center)
            Image(systemName: "text.alignright")
                .tag(ImageAlignment.right)
            Image(systemName: "arrow.left.and.right")
                .tag(ImageAlignment.full)
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Preview

#Preview {
    ImagePickerSheet(isPresented: .constant(true)) { _ in }
}
