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

class IOSPdfView: NSObject, FlutterPlatformView, UIGestureRecognizerDelegate {
    private var _view: UIView
    private var pdfView: PDFView
    private var methodChannel: FlutterMethodChannel
    private var currentTool: String = "none"

    private var currentPath: UIBezierPath?
    private var currentAnnotation: PDFAnnotation?
    
    private var drawColor: UIColor = .red
    private var highlightColor: UIColor = UIColor.yellow.withAlphaComponent(0.5)
    private var underlineColor: UIColor = .blue

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
        setupMenuController()
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
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if let data = self.pdfView.document?.dataRepresentation() {
                    let resultData = FlutterStandardTypedData(bytes: data)
                    DispatchQueue.main.async {
                        result(resultData)
                    }
                } else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "SAVE_ERROR", message: "Could not save PDF", details: nil))
                    }
                }
            }
        case "addTextAnnotation":
            if let args = call.arguments as? [String: Any],
               let text = args["text"] as? String,
               let x = args["x"] as? Double,
               let y = args["y"] as? Double {
                let colorInt = args["color"] as? Int
                addTextAnnotation(text: text, at: CGPoint(x: x, y: y), color: colorInt != nil ? UIColor(argb: colorInt!) : nil)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Text, x, and y are required", details: nil))
            }
        case "jumpToPage":
            if let args = call.arguments as? [String: Any],
               let pageIndex = args["page"] as? Int,
               let document = pdfView.document,
               pageIndex < document.pageCount {
                if let page = document.page(at: pageIndex) {
                    pdfView.go(to: page)
                }
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_PAGE", message: "Invalid page index", details: nil))
            }
        case "getTotalPages":
            result(pdfView.document?.pageCount ?? 0)
        case "updateConfig":
            if let args = call.arguments as? [String: Any] {
                if let draw = args["drawColor"] as? Int { drawColor = UIColor(argb: draw) }
                if let highlight = args["highlightColor"] as? Int { highlightColor = UIColor(argb: highlight) }
                if let underline = args["underlineColor"] as? Int { underlineColor = UIColor(argb: underline) }
                result(nil)
            }
        case "setScrollLocked":
            if let args = call.arguments as? [String: Any],
               let locked = args["locked"] as? Bool {
                setScrollLocked(locked)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Locked state is required", details: nil))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func setScrollLocked(_ locked: Bool) {
        // Find the UIScrollview inside PDFView
        for subview in pdfView.subviews {
            if let scrollView = subview as? UIScrollView {
                scrollView.isScrollEnabled = !locked
                return
            }
        }
    }

    private func setupGestureRecognizers() {
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        pdfView.addGestureRecognizer(panGesture)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        pdfView.addGestureRecognizer(tapGesture)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if currentTool == "draw" {
            return false // Don't scroll while drawing
        }
        return true
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
            annotation.color = drawColor
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
        let location = gesture.location(in: pdfView)
        
        if currentTool == "text" {
            // Report tap to Flutter for text input
            methodChannel.invokeMethod("onPdfTapped", arguments: ["x": location.x, "y": location.y])
            return
        }
        
        guard currentTool == "highlight" || currentTool == "underline" else { return }
        
        guard let page = pdfView.page(for: location, nearest: true) else { return }
        let pagePoint = pdfView.convert(location, to: page)
        
        // Try to find text selection at point
        if let selection = page.selectionForLine(at: pagePoint) {
            let annotationType: PDFAnnotationSubtype = currentTool == "highlight" ? .highlight : .underline
            let annotation = PDFAnnotation(bounds: selection.bounds(for: page), forType: annotationType, withProperties: nil)
            annotation.color = currentTool == "highlight" ? highlightColor : underlineColor
            
            page.addAnnotation(annotation)
        }
    }

    private func setupMenuController() {
        let highlightItem = UIMenuItem(title: "Highlight", action: #selector(menuHighlight(_:)))
        let underlineItem = UIMenuItem(title: "Underline", action: #selector(menuUnderline(_:)))
        UIMenuController.shared.menuItems = [highlightItem, underlineItem]
    }

    @objc func menuHighlight(_ sender: Any) {
        if let selection = pdfView.currentSelection, let page = selection.pages.first {
            let annotation = PDFAnnotation(bounds: selection.bounds(for: page), forType: .highlight, withProperties: nil)
            annotation.color = highlightColor
            page.addAnnotation(annotation)
        }
    }

    @objc func menuUnderline(_ sender: Any) {
        if let selection = pdfView.currentSelection, let page = selection.pages.first {
            let annotation = PDFAnnotation(bounds: selection.bounds(for: page), forType: .underline, withProperties: nil)
            annotation.color = underlineColor
            page.addAnnotation(annotation)
        }
    }

    private func addTextAnnotation(text: String, at point: CGPoint, color: UIColor?) {
        // Convert screen point to page coordinates
        guard let page = pdfView.page(for: point, nearest: true) else { return }
        let pagePoint = pdfView.convert(point, to: page)
        
        let bounds = CGRect(x: pagePoint.x, y: pagePoint.y, width: 200, height: 50)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = UIFont.systemFont(ofSize: 14)
        annotation.fontColor = color ?? .black
        annotation.color = .clear
        
        page.addAnnotation(annotation)
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

extension UIColor {
    convenience init(argb: Int) {
        self.init(
            red: CGFloat((argb >> 16) & 0xFF) / 255.0,
            green: CGFloat((argb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(argb & 0xFF) / 255.0,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255.0
        )
    }
}
