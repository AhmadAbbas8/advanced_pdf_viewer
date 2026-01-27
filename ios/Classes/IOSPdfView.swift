import Flutter
import UIKit
import PDFKit

class SafePDFView: PDFView {
    var disableInteraction: Bool = false {
        didSet {
            // Standard userInteractionEnabled toggle
            isUserInteractionEnabled = !disableInteraction
            
            // Critical: Resign first responder to detach from system text input managers
            if disableInteraction {
                self.resignFirstResponder()
                self.clearSelection()
            }
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Absolute block of all touches
        if disableInteraction {
            return nil
        }
        return super.hitTest(point, with: event)
    }
    
    // Prevent becoming first responder (text input target) when disabled
    override var canBecomeFirstResponder: Bool {
        return !disableInteraction
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        if #available(iOS 13.0, *) {
            builder.remove(menu: .lookup)
            builder.remove(menu: .share)
            // Remove other potentially interfering menus
            builder.remove(menu: .replace) 
            builder.remove(menu: .standardEdit) 
        }
        super.buildMenu(with: builder)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let actionString = NSStringFromSelector(action)
        
        // Define exact selectors to block
        let blockedSelectors = [
            "copy:", "paste:", "cut:", "selectAll:", 
            "_define:", "_translate:", "_share:", "_accessibilitySpeak:", "_accessibilitySpeakLanguageSelection:", 
            "_promptForReplace:", "_transliterateChinese:", "lookup:", "searchWeb:", "share:"
        ]
        
        if blockedSelectors.contains(actionString) {
            return false
        }
        
        // Block broad categories by string matching
        if actionString.contains("Share") || 
           actionString.contains("Define") || 
           actionString.contains("Translate") || 
           actionString.contains("Search") ||
           actionString.contains("Lookup") {
            return false
        }
        
        return super.canPerformAction(action, withSender: sender)
    }
}

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
    // Structure to store annotation with its page index for undo/redo
    private struct AnnotationReference {
        let annotation: PDFAnnotation
        let pageIndex: Int
    }
    
    private var _view: UIView
    private var pdfView: SafePDFView
    private var overlayView: UIView!
    private var methodChannel: FlutterMethodChannel
    
    // Observer property to toggle overlay interaction
    private var currentTool: String = "none" {
        didSet {
            updateOverlayInteraction()
        }
    }
    
    private var isTempFile: Bool = false

    private var currentPath: UIBezierPath?
    private var currentAnnotation: PDFAnnotation?
    
    private var undoStack: [AnnotationReference] = []
    private var redoStack: [AnnotationReference] = []
    
    private var drawColor: UIColor = .red
    private var highlightColor: UIColor = UIColor.yellow.withAlphaComponent(0.5)
    private var underlineColor: UIColor = .blue
    private var enablePageNumber: Bool = false
    
    // Page tracking
    private var currentPage: Int = 0

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        _view = UIView(frame: frame)
        pdfView = SafePDFView(frame: frame)
        
        methodChannel = FlutterMethodChannel(name: "advanced_pdf_viewer_\(viewId)", binaryMessenger: messenger)
        
        super.init()
        
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.autoScales = false  // Disable auto scaling to allow manual zoom control
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.minScaleFactor = 0.5
        pdfView.maxScaleFactor = 5.0
        
        pdfView.minScaleFactor = 0.5
        pdfView.maxScaleFactor = 5.0
        
        _view.addSubview(pdfView)
        
        // Initialize transparent overlay view
        overlayView = UIView(frame: frame)
        overlayView.backgroundColor = .clear
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.isUserInteractionEnabled = false // Disabled by default until tool is selected
        
        _view.addSubview(overlayView)
        
        if let argsDict = args as? [String: Any] {
           if let tempFile = argsDict["isTempFile"] as? Bool {
               isTempFile = tempFile
           }
           if let pdfPath = argsDict["path"] as? String {
               loadPdf(path: pdfPath)
           }
        }
        
        methodChannel.setMethodCallHandler(handle)
        
        setupGestureRecognizers()
        setupMenuController()
        setupPageChangeObserver()
    }
    
    private func setupPageChangeObserver() {
        // Observe page change notifications from PDFView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
    }
    
    @objc private func pageChanged(_ notification: Notification) {
        guard let document = pdfView.document,
              let currentPDFPage = pdfView.currentPage else { return }
        
        let pageIndex = document.index(for: currentPDFPage)
        if pageIndex != currentPage {
            currentPage = pageIndex
            // Notify Flutter of page change
            methodChannel.invokeMethod("onPageChanged", arguments: currentPage)
        }
    }

    func view() -> UIView {
        return _view
    }

    private func loadPdf(path: String) {
        let url = URL(fileURLWithPath: path)
        
        if isTempFile {
            do {
                let data = try Data(contentsOf: url)
                if let document = NumberedPDFDocument(data: data) {
                    pdfView.document = document
                    // Set initial zoom to 0.5 after document is loaded
                    pdfView.scaleFactor = 0.5
                    updatePageNumbersState()
                }
                try FileManager.default.removeItem(at: url)
            } catch {
                print("Error loading temp PDF: \(error)")
            }
        } else {
            if let document = NumberedPDFDocument(url: url) {
                pdfView.document = document
                // Set initial zoom to 0.5 after document is loaded
                pdfView.scaleFactor = 0.5
                updatePageNumbersState()
            }
        }
    }

    private func updatePageNumbersState() {
        guard let document = pdfView.document else { return }
        for i in 0..<document.pageCount {
            if let page = document.page(at: i) as? NumberedPDFPage {
                page.showNumber = enablePageNumber
            }
        }
        // Force redraw by toggling display mode slightly or just relying on next render
        // A layout change forces rewrite
        pdfView.layoutDocumentView()
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setDrawingMode":
            if let args = call.arguments as? [String: Any],
               let tool = args["tool"] as? String {
                // This triggers the didSet observer to update overlay interaction
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
               var pageIndex = args["page"] as? Int,
               let document = pdfView.document {
                
                // Clamp index to ensure it is valid
                pageIndex = max(0, min(pageIndex, document.pageCount - 1))
                
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
                if let pageNum = args["enablePageNumber"] as? Bool {
                    enablePageNumber = pageNum
                    updatePageNumbersState()
                }
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
        case "zoomIn":
            pdfView.scaleFactor = min(pdfView.scaleFactor + 0.2, pdfView.maxScaleFactor)
            result(nil)
        case "zoomOut":
            pdfView.scaleFactor = max(pdfView.scaleFactor - 0.2, pdfView.minScaleFactor)
            result(nil)
        case "undo":
            if let ref = undoStack.popLast(),
               let document = pdfView.document,
               let page = document.page(at: ref.pageIndex) {
                page.removeAnnotation(ref.annotation)
                redoStack.append(ref)
            }
            result(nil)
        case "redo":
            if let ref = redoStack.popLast(),
               let document = pdfView.document,
               let page = document.page(at: ref.pageIndex) {
                page.addAnnotation(ref.annotation)
                undoStack.append(ref)
            }
            result(nil)
        case "setZoom":
            if let args = call.arguments as? [String: Any],
               let scale = args["scale"] as? Double {
                pdfView.scaleFactor = CGFloat(max(pdfView.minScaleFactor, min(CGFloat(scale), pdfView.maxScaleFactor)))
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Scale is required", details: nil))
            }
        case "getCurrentPage":
            result(currentPage)
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
        // Attach gestures to overlayView instead of pdfView
        // This prevents the native PDFView from handling these touches when overlay is active
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        overlayView.addGestureRecognizer(panGesture)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        overlayView.addGestureRecognizer(tapGesture)
    }
    
    private func updateOverlayInteraction() {
        // Enable overlay interaction only when a tool is selected
        // This blocks touches from reaching the underlying PDFView
        overlayView.isUserInteractionEnabled = currentTool != "none"
        
        // Critical Fix: Explicitly disable PDFView interaction via custom hitTest override
        // This ensures NO touches reach it, preventing the native crash.
        pdfView.disableInteraction = currentTool != "none"
        
        if currentTool != "none" {
            _view.bringSubviewToFront(overlayView)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if currentTool != "none" {
            return false // Don't scroll while drawing or selecting
        }
        return true
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        if currentTool == "draw" {
            handleDrawPan(gesture)
        } else if currentTool == "highlight" || currentTool == "underline" {
            handleSelectionPan(gesture)
        }
    }

    private func handleDrawPan(_ gesture: UIPanGestureRecognizer) {
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
            if let annotation = currentAnnotation,
               let page = annotation.page,
               let document = pdfView.document {
                let pageIndex = document.index(for: page)
                undoStack.append(AnnotationReference(annotation: annotation, pageIndex: pageIndex))
                redoStack.removeAll()
            }
            currentPath = nil
            currentAnnotation = nil
            
        default:
            break
        }
    }

    private var selectionStartPoint: CGPoint?
    
    // Throttle UI updates for selection to improve smoothness and prevent crashes
    private var lastSelectionUpdateTime: TimeInterval = 0
    private let selectionUpdateInterval: TimeInterval = 0.016 // ~60fps cap
    
    private func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: pdfView)
        // Safety check for valid page
        guard let page = pdfView.page(for: location, nearest: true) else { return }
        let pagePoint = pdfView.convert(location, to: page)
        
        switch gesture.state {
        case .began:
            selectionStartPoint = pagePoint
            lastSelectionUpdateTime = Date().timeIntervalSince1970
            
        case .changed:
            let currentTime = Date().timeIntervalSince1970
            if currentTime - lastSelectionUpdateTime > selectionUpdateInterval {
                if let start = selectionStartPoint {
                    do {
                        DispatchQueue.main.async { [weak self] in
                            if let selection = page.selection(from: start, to: pagePoint),
                               let selectionString = selection.string, !selectionString.isEmpty {
                                self?.pdfView.currentSelection = selection
                            }
                        }
                    } catch {
                        print("Selection error during pan: \(error)")
                    }
                }
                lastSelectionUpdateTime = currentTime
            }
            
        case .ended, .cancelled:
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                do {
                    if let start = self.selectionStartPoint {
                        if let selection = page.selection(from: start, to: pagePoint),
                           let selectionString = selection.string, !selectionString.isEmpty {
                            self.pdfView.currentSelection = selection
                        }
                    }
                    
                    if let selection = self.pdfView.currentSelection {
                        self.addAnnotationsForSelection(selection)
                    }
                } catch {
                    print("Selection error at end: \(error)")
                }
                
                self.pdfView.currentSelection = nil
                self.selectionStartPoint = nil
            }
            
        default:
            break
        }
    }

    private func addAnnotationsForSelection(_ selection: PDFSelection) {
        let annotationType: PDFAnnotationSubtype = currentTool == "highlight" ? .highlight : .underline
        let color = currentTool == "highlight" ? highlightColor : underlineColor
        
        guard !selection.pages.isEmpty else { return }
        
        // Dispatch to background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                for page in selection.pages {
                    // Use the selection bounds directly instead of selectionsByLine
                    let bounds = selection.bounds(for: page)
                    
                    // Aggressive safety checks
                    guard !bounds.isEmpty, !bounds.isNull else {
                        continue
                    }
                    
                    // Check for NaN or infinite values
                    guard !bounds.origin.x.isNaN, !bounds.origin.y.isNaN,
                          !bounds.size.width.isNaN, !bounds.size.height.isNaN else {
                        continue
                    }
                    
                    guard !bounds.origin.x.isInfinite, !bounds.origin.y.isInfinite,
                          !bounds.size.width.isInfinite, !bounds.size.height.isInfinite else {
                        continue
                    }
                    
                    // Skip if bounds are negative or zero
                    guard bounds.width > 0, bounds.height > 0 else {
                        continue
                    }
                    
                    // Clamp bounds to reasonable values
                    guard bounds.width < 5000, bounds.height < 5000 else {
                        continue
                    }
                    
                    // Normalize the bounds
                    let normalizedBounds = bounds.standardized
                    
                    // Try-catch for annotation creation - on main thread
                    DispatchQueue.main.async {
                        do {
                            let annotation = PDFAnnotation(bounds: normalizedBounds, forType: annotationType, withProperties: nil)
                            annotation.color = color
                            page.addAnnotation(annotation)
                            
                            if let document = self.pdfView.document {
                                let pageIndex = document.index(for: page)
                                self.undoStack.append(AnnotationReference(annotation: annotation, pageIndex: pageIndex))
                                self.redoStack.removeAll()
                            }
                        } catch {
                            print("Failed to create annotation: \(error)")
                        }
                    }
                }
            } catch {
                print("Error in addAnnotationsForSelection: \(error)")
            }
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
           addAnnotationsForSelection(selection)
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
            
            // Add to undo stack for undo/redo functionality
            if let document = pdfView.document {
                let pageIndex = document.index(for: page)
                undoStack.append(AnnotationReference(annotation: annotation, pageIndex: pageIndex))
                redoStack.removeAll()
            }
        }
    }

    @objc func menuUnderline(_ sender: Any) {
        if let selection = pdfView.currentSelection, let page = selection.pages.first {
            let annotation = PDFAnnotation(bounds: selection.bounds(for: page), forType: .underline, withProperties: nil)
            annotation.color = underlineColor
            page.addAnnotation(annotation)
            
            // Add to undo stack for undo/redo functionality
            if let document = pdfView.document {
                let pageIndex = document.index(for: page)
                undoStack.append(AnnotationReference(annotation: annotation, pageIndex: pageIndex))
                redoStack.removeAll()
            }
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

class NumberedPDFDocument: PDFDocument {
    override var pageClass: AnyClass {
        return NumberedPDFPage.self
    }
}

class NumberedPDFPage: PDFPage {
    // Static config is risky for multiple views, but simple for now. 
    // Ideally we'd set this per page instance.
    var showNumber: Bool = false
    
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        
        if showNumber {
            UIGraphicsPushContext(context)
            context.saveGState()
            
            let pageBounds = self.bounds(for: box)
            
            // Flip the coordinate system to match UIKit's expectation
            context.translateBy(x: 0.0, y: pageBounds.size.height)
            context.scaleBy(x: 1.0, y: -1.0)
            
            // Setup text
            let text = "\(self.label ?? String(describing: (self.document?.index(for: self) ?? 0) + 1))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.black
            ]
            let attributedString = NSAttributedString(string: text, attributes: attributes)
            let textSize = attributedString.size()
            
            // Draw at bottom center
            // After flip, (0,0) is Top-Left. 
            // We want bottom, so y should be (height - padding)
            // But wait, if we flipped the whole page, we are drawing in "UIKit coordinates".
            // Top-left is 0,0. Bottom-left is 0, height.
            let x = (pageBounds.width - textSize.width) / 2
            let y = pageBounds.height - 20.0 // 20 points from bottom (top in flipped coords)
            
            // Draw
            attributedString.draw(at: CGPoint(x: x, y: y))
            
            context.restoreGState()
            UIGraphicsPopContext()
        }
    }
}