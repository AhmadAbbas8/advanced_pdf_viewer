import Flutter
import UIKit
import PDFKit

class IOSPdfViewFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return IOSPdfView(
            frame: frame,
            viewIdentifier: viewId,
            arguments: args,
            binaryMessenger: messenger)
    }

    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
          return FlutterStandardMessageCodec.sharedInstance()
    }
}

class IOSPdfView: NSObject, FlutterPlatformView {
    private var _view: UIView
    private var pdfView: PDFView
    private var methodChannel: FlutterMethodChannel
    private var currentTool: String = "none"

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        _view = UIView(frame: frame)
        pdfView = PDFView(frame: frame)
        
        methodChannel = FlutterMethodChannel(name: "advanced_pdf_viewer_\(viewId)", binaryMessenger: messenger)
        
        super.init()
        
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        
        _view.addSubview(pdfView)
        
        if let argsDict = args as? [String: Any],
           let pdfPath = argsDict["path"] as? String {
            loadPdf(path: pdfPath)
        }
        
        methodChannel.setMethodCallHandler(handle)
        
        setupGestureRecognizers()
    }

    func view() -> UIView {
        return _view
    }

    private func loadPdf(path: String) {
        let url = URL(fileURLWithPath: path)
        if let document = PDFDocument(url: url) {
            pdfView.document = document
        }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setDrawingMode":
            if let args = call.arguments as? [String: Any],
               let tool = args["tool"] as? String {
                self.currentTool = tool
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Tool is required", details: nil))
            }
        case "clearAnnotations":
            clearAnnotations()
            result(nil)
        case "savePdf":
            if let data = pdfView.document?.dataRepresentation() {
                result(FlutterStandardTypedData(bytes: data))
            } else {
                result(FlutterError(code: "SAVE_ERROR", message: "Could not save PDF", details: nil))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func setupGestureRecognizers() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        pdfView.addGestureRecognizer(tapGesture)
        
        // For drawing, we might need a custom view over PDFView or use PDFAnnotation directly
        // For simplicity in this initial implementation, let's support basic highlights/underline via selection
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard currentTool != "none" else { return }
        
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: true) else { return }
        let pageLocation = pdfView.convert(location, to: page)
        
        if currentTool == "highlight" || currentTool == "underline" {
            // In a real app, we would look for text at this location
            // For now, let's add a sample annotation at the tap location
            let rect = CGRect(x: pageLocation.x - 50, y: pageLocation.y - 10, width: 100, height: 20)
            let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = currentTool == "highlight" ? .yellow.withAlphaComponent(0.5) : .blue
            page.addAnnotation(annotation)
        } else if currentTool == "draw" {
            let rect = CGRect(x: pageLocation.x - 5, y: pageLocation.y - 5, width: 10, height: 10)
            let annotation = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
            annotation.color = .red
            // Ink annotations usually require a path, this is a simplified version
            page.addAnnotation(annotation)
        }
    }

    private func clearAnnotations() {
        guard let document = pdfView.document else { return }
        for i in 0..<document.pageCount {
            if let page = document.page(at: i) {
                let annotations = page.annotations
                for annotation in annotations {
                    page.removeAnnotation(annotation)
                }
            }
        }
    }
}
