import LampCore
import SwiftUI
import Vision
import VisionKit

struct PresentationPairingScanner: UIViewControllerRepresentable {
    /// Reads a pairing code out of a QR's payload: the slide remote's by
    /// default, or the chat remote's, whose QR says what it is for.
    var parse: (String) -> String? = LampPresentationRemotePairing.code(fromQRPayload:)
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parse: parse, onCode: onCode, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator

        do {
            try scanner.startScanning()
        } catch {
            let onFailure = onFailure
            DispatchQueue.main.async {
                onFailure("The camera scanner could not start. Enter the pairing code instead.")
            }
        }
        return scanner
    }

    func updateUIViewController(
        _ uiViewController: DataScannerViewController,
        context: Context
    ) {}

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let parse: (String) -> String?
        private let onCode: (String) -> Void
        private let onFailure: (String) -> Void
        private var didFinish = false

        init(
            parse: @escaping (String) -> String?,
            onCode: @escaping (String) -> Void,
            onFailure: @escaping (String) -> Void
        ) {
            self.parse = parse
            self.onCode = onCode
            self.onFailure = onFailure
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didFinish else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let payload = barcode.payloadStringValue,
                      let code = parse(payload) else {
                    continue
                }
                didFinish = true
                dataScanner.stopScanning()
                onCode(code)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            guard !didFinish else { return }
            didFinish = true
            onFailure("The camera scanner became unavailable. Enter the pairing code instead.")
        }
    }
}
