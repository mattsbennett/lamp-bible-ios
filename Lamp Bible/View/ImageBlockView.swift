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

            if let caption = block.caption, !caption.text.isEmpty {
                Text(caption.text)
                    .font(.subheadline.italic())
                    .foregroundColor(.secondary)
                    .frame(maxWidth: maxWidth, alignment: .leading)
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

/// Full-screen image viewer with zoom using UIKit ScrollView for reliable behavior
struct FullScreenImageView: View {
    let image: UIImage
    let caption: DevotionalAnnotatedText?
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                // Zoomable image using UIKit
                ZoomableImageScrollView(image: image)
                    .ignoresSafeArea()

                // Caption at bottom
                if let caption = caption, !caption.text.isEmpty {
                    VStack {
                        Spacer()
                        Text(caption.text)
                            .font(.subheadline.italic())
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(.ultraThinMaterial.opacity(0.8))
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
}

/// A zoomable scroll view for images using UIKit UIScrollView
struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5.0
        scrollView.minimumZoomScale = 1.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        scrollView.addSubview(imageView)

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        // Add double-tap gesture for zoom toggle
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Layout the image view to fit
        DispatchQueue.main.async {
            context.coordinator.layoutImageView()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        let image: UIImage
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        init(image: UIImage) {
            self.image = image
        }

        func layoutImageView() {
            guard let scrollView = scrollView, let imageView = imageView else { return }

            let scrollViewSize = scrollView.bounds.size
            guard scrollViewSize.width > 0 && scrollViewSize.height > 0 else { return }

            let imageSize = image.size
            guard imageSize.width > 0 && imageSize.height > 0 else { return }

            // Calculate the scale to fit image in scroll view
            let widthScale = scrollViewSize.width / imageSize.width
            let heightScale = scrollViewSize.height / imageSize.height
            let minScale = min(widthScale, heightScale)

            let scaledWidth = imageSize.width * minScale
            let scaledHeight = imageSize.height * minScale

            // Set image view frame centered in scroll view
            imageView.frame = CGRect(
                x: 0,
                y: 0,
                width: scaledWidth,
                height: scaledHeight
            )

            scrollView.contentSize = CGSize(width: scaledWidth, height: scaledHeight)

            // Center the image
            centerImageView()
        }

        func centerImageView() {
            guard let scrollView = scrollView, let imageView = imageView else { return }

            let scrollViewSize = scrollView.bounds.size
            let imageViewSize = imageView.frame.size

            let horizontalPadding = max(0, (scrollViewSize.width - imageViewSize.width) / 2)
            let verticalPadding = max(0, (scrollViewSize.height - imageViewSize.height) / 2)

            scrollView.contentInset = UIEdgeInsets(
                top: verticalPadding,
                left: horizontalPadding,
                bottom: verticalPadding,
                right: horizontalPadding
            )
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImageView()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = scrollView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // Zoom to 2.5x at the tapped point
                let location = gesture.location(in: imageView)
                let zoomScale: CGFloat = 2.5
                let width = scrollView.bounds.width / zoomScale
                let height = scrollView.bounds.height / zoomScale
                let zoomRect = CGRect(
                    x: location.x - width / 2,
                    y: location.y - height / 2,
                    width: width,
                    height: height
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
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
