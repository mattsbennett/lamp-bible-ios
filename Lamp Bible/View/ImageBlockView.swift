//
//  ImageBlockView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import SwiftUI

/// Displays an image block within a devotional
struct ImageBlockView: View {
    let block: DevotionalContentBlock
    let mediaRef: DevotionalMediaReference?
    let imageURL: URL?
    let alignment: ImageAlignment
    let onTap: (() -> Void)?

    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadError = false

    var body: some View {
        VStack(alignment: horizontalAlignment, spacing: 8) {
            imageContent
                .frame(maxWidth: maxWidth, alignment: frameAlignment)

            if let caption = block.caption {
                DevotionalAnnotatedTextView(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: maxWidth, alignment: frameAlignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .onAppear {
            loadImage()
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if isLoading {
            ProgressView()
                .frame(height: 200)
                .frame(maxWidth: maxWidth)
        } else if loadError {
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Failed to load image")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(height: 200)
            .frame(maxWidth: maxWidth)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(8)
        } else if let image = loadedImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth)
                .cornerRadius(8)
                .onTapGesture {
                    onTap?()
                }
                .accessibilityLabel(mediaRef?.alt ?? "Image")
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch alignment {
        case .left:
            return .leading
        case .center, .full:
            return .center
        case .right:
            return .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .left:
            return .leading
        case .center, .full:
            return .center
        case .right:
            return .trailing
        }
    }

    private var maxWidth: CGFloat? {
        switch alignment {
        case .full:
            return .infinity
        case .left, .right:
            return 250
        case .center:
            return 400
        }
    }

    private func loadImage() {
        guard let url = imageURL else {
            isLoading = false
            loadError = true
            return
        }

        // Load image on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            if let image = UIImage(contentsOfFile: url.path) {
                DispatchQueue.main.async {
                    self.loadedImage = image
                    self.isLoading = false
                }
            } else {
                DispatchQueue.main.async {
                    self.loadError = true
                    self.isLoading = false
                }
            }
        }
    }
}

/// Full-screen image viewer
struct FullScreenImageView: View {
    let image: UIImage
    let caption: DevotionalAnnotatedText?
    @Binding var isPresented: Bool

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = lastScale * value
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale < 1.0 {
                                    withAnimation {
                                        scale = 1.0
                                        lastScale = 1.0
                                    }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if scale > 1.0 {
                                scale = 1.0
                                lastScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }

                if let caption = caption {
                    DevotionalAnnotatedTextView(caption)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding()
                }
            }

            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                Spacer()
            }
        }
        .statusBar(hidden: true)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        ImageBlockView(
            block: DevotionalContentBlock(type: .image, mediaId: "test"),
            mediaRef: DevotionalMediaReference(
                id: "test",
                type: .image,
                filename: "test.jpg",
                mimeType: "image/jpeg"
            ),
            imageURL: nil,
            alignment: .center,
            onTap: nil
        )
    }
    .padding()
}
