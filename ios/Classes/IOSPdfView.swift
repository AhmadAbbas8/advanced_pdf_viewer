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

    private var currentPath: UIBezierPath?
    private var currentAnnotation: PDFAnnotation?

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
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pdfView.addGestureRecognizer(panGesture)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        pdfView.addGestureRecognizer(tapGesture)
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard currentTool == "draw" else { return }
        
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: true) else { return }
        let pagePoint = pdfView.convert(location, to: page)
        
        switch gesture.state {
        case .began:
            currentPath = UIBezierPath()
            currentPath?.move(to: pagePoint)
            
            let annotation = PDFAnnotation(bounds: page.bounds(for: .mediaBox), forType: .ink, withProperties: nil)
            annotation.color = .red
            annotation.border = PDFBorder()
            annotation.border?.lineWidth = 3
            currentAnnotation = annotation
            page.addAnnotation(annotation)
            
        case .changed:
            currentPath?.addLine(to: pagePoint)
            if let path = currentPath {
                currentAnnotation?.add(path)
            }
            
        case .ended, .cancelled:
            currentPath = nil
            currentAnnotation = nil
            
        default:
            break
        }
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard currentTool == "highlight" || currentTool == "underline" else { return }
        
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: true) else { return }
        let pagePoint = pdfView.convert(location, to: page)
        
        // Try to find text selection at point
        if let selection = page.selection(at: pagePoint) {
            let annotationType: PDFAnnotationSubtype = currentTool == "highlight" ? .highlight : .underline
            let annotation = PDFAnnotation(bounds: selection.bounds(for: page), forType: annotationType, withProperties: nil)
            annotation.color = currentTool == "highlight" ? .yellow.withAlphaComponent(0.5) : .blue
            
            // Add quadrilateral points for better text alignment
            let lineSelections = selection.selectionsByLine()
            for lineSelection in lineSelections {
                // In a more advanced version, we'd add quadrilaterals here. 
                // PDFAnnotation for highlight automatically handles the selection bounds well.
            }
            
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
