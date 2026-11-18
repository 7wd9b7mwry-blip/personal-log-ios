import SwiftUI
import VisionKit

/// A package's barcode (UPC / EAN) from the camera (VisionKit's live scanner); the first one read is returned, nil
/// when cancelled or the device can't scan.
struct BarcodeScanner: UIViewControllerRepresentable {
    let done: (String?) -> Void

    static var available: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let done: (String?) -> Void
        private var sent = false
        init(_ done: @escaping (String?) -> Void) { self.done = done }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(b) in items {
                guard !sent, let code = b.payloadStringValue, code.allSatisfy(\.isNumber), code.count >= 8 else { continue }
                sent = true
                scanner.stopScanning()
                done(code)
            }
        }
    }
}
