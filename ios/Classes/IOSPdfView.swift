import Flutter
import UIKit
import PDFKit

// MARK: - SafePDFView

class SafePDFView: PDFView {
    var disableInteraction: Bool = false {
        didSet {
            isUserInteractionEnabled = !disableInteraction
            if disableInteraction { self.resignFirstResponder(); self.clearSelection() }
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if disableInteraction { return nil }
        return super.hitTest(point, with: event)
    }
    override var canBecomeFirstResponder: Bool { return !disableInteraction }
    override func buildMenu(with builder: UIMenuBuilder) {
        if #available(iOS 13.0, *) {
            builder.remove(menu: .lookup); builder.remove(menu: .share)
            builder.remove(menu: .replace); builder.remove(menu: .standardEdit)
        }
        super.buildMenu(with: builder)
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let s = NSStringFromSelector(action)
        let blocked = ["copy:","paste:","cut:","selectAll:","_define:","_translate:","_share:",
                       "_accessibilitySpeak:","_accessibilitySpeakLanguageSelection:",
                       "_promptForReplace:","_transliterateChinese:","lookup:","searchWeb:","share:"]
        if blocked.contains(s) { return false }
        if s.contains("Share") || s.contains("Define") || s.contains("Translate") ||
            s.contains("Search") || s.contains("Lookup") { return false }
        return super.canPerformAction(action, withSender: sender)
    }
}

// MARK: - Factory

class IOSPdfViewFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger
    init(messenger: FlutterBinaryMessenger) { self.messenger = messenger; super.init() }
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return IOSPdfView(frame: frame, viewIdentifier: viewId, arguments: args, binaryMessenger: messenger)
    }
    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

// MARK: - SelectionHandleView
// Circular drag handle that appears at the start/end of a selection, matching native iOS style.

private class SelectionHandleView: UIView {
    enum HandleSide { case start, end }
    let side: HandleSide
    private let circle = UIView()
    private let stem   = UIView()

    var pagePt:  CGPoint = .zero
    weak var pdfPage: PDFPage?

    init(side: HandleSide, color: UIColor) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        isUserInteractionEnabled = true
        backgroundColor = .clear

        let r: CGFloat     = 10
        let stemW: CGFloat = 2
        let stemH: CGFloat = 10

        circle.backgroundColor    = color
        circle.layer.cornerRadius = r
        stem.backgroundColor      = color

        addSubview(stem)
        addSubview(circle)

        circle.frame = CGRect(x: 0, y: stemH, width: r * 2, height: r * 2)
        stem.frame   = CGRect(x: r - stemW / 2, y: 0, width: stemW, height: stemH)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setColor(_ color: UIColor) {
        circle.backgroundColor = color
        stem.backgroundColor   = color
    }

    func animateAppear() {
        alpha     = 0
        transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
        UIView.animate(withDuration: 0.22, delay: 0,
                       usingSpringWithDamping: 0.58, initialSpringVelocity: 0.8,
                       options: .curveEaseOut) {
            self.alpha     = 1
            self.transform = .identity
        }
    }

    func animateDisappear(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.15, animations: {
            self.alpha     = 0
            self.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        }) { _ in
            self.removeFromSuperview()
            self.transform = .identity
            completion?()
        }
    }
}

// MARK: - SelectionPreviewLayer
// Smooth animated CAShapeLayer that shows a live selection highlight on the overlay view.

private class SelectionPreviewLayer: CAShapeLayer {
    override init() {
        super.init()
        fillColor   = UIColor.systemBlue.withAlphaComponent(0.20).cgColor
        strokeColor = UIColor.systemBlue.withAlphaComponent(0.40).cgColor
        lineWidth   = 1.0
        lineCap     = .round
        lineJoin    = .round
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func update(rects: [CGRect], animated: Bool) {
        let path = UIBezierPath()
        for r in rects where r.width > 0 && r.height > 0 {
            path.append(UIBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), cornerRadius: 2))
        }
        if animated {
            let anim            = CABasicAnimation(keyPath: "path")
            anim.fromValue      = self.path
            anim.toValue        = path.cgPath
            anim.duration       = 0.07
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            anim.isRemovedOnCompletion = false
            add(anim, forKey: "pathAnim")
        }
        self.path = path.cgPath
    }

    func clearAnimated() {
        let anim            = CABasicAnimation(keyPath: "opacity")
        anim.fromValue      = 1
        anim.toValue        = 0
        anim.duration       = 0.18
        anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        anim.fillMode       = .forwards
        anim.isRemovedOnCompletion = false
        add(anim, forKey: "fadeOut")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            self?.path    = nil
            self?.opacity = 1
            self?.removeAnimation(forKey: "fadeOut")
        }
    }
}

// MARK: - IOSPdfView

class IOSPdfView: NSObject, FlutterPlatformView, UIGestureRecognizerDelegate {

    private struct AnnotationReference {
        let annotation: PDFAnnotation
        let pageIndex:  Int
    }

    private var _view:         UIView
    private var pdfView:       SafePDFView
    private var overlayView:   UIView!
    private var methodChannel: FlutterMethodChannel

    private var currentTool:     String  = "none" { didSet { updateOverlayInteraction() } }
    private var isTempFile:      Bool    = false
    private var currentPath:     UIBezierPath?
    private var currentAnnotation: PDFAnnotation?
    private var undoStack:       [AnnotationReference] = []
    private var redoStack:       [AnnotationReference] = []
    private var drawColor:       UIColor = .red
    private var highlightColor:  UIColor = UIColor.yellow.withAlphaComponent(0.5)
    private var underlineColor:  UIColor = .blue
    private var enablePageNumber: Bool   = false
    private var currentPage:     Int     = 0

    // Search
    private var searchResults:              [PDFSelection]        = []
    private var currentSearchIndex:         Int                   = -1
    private var searchHighlightAnnotations: [PDFAnnotation]       = []
    private var searchResultAnnotations:    [Int: PDFAnnotation]  = [:]
    private let searchAllColor     = UIColor.yellow.withAlphaComponent(0.45)
    private let searchCurrentColor = UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.7)

    // Selection state
    private var selectionStartPoint:    CGPoint?          // page-space start of drag
    private var lastSelectionUpdateTime: TimeInterval = 0
    private let selectionUpdateInterval: TimeInterval = 0.016
    private var isWordSnapMode:   Bool             = false
    private var selectionAnchorWord: PDFSelection?
    private var isDragging:       Bool             = false
    private let dragThreshold:    CGFloat          = 6.0
    private var currentLiveSelection: PDFSelection?
    private var selectionPage:    PDFPage?
    private var isRTLSelection:   Bool             = false

    // Handles
    private var startHandle:  SelectionHandleView?
    private var endHandle:    SelectionHandleView?
    private var activeHandle: SelectionHandleView?
    private var handleDragOppositePoint: CGPoint = .zero
    private var previewLayer: SelectionPreviewLayer!

    // Gesture refs
    private var panGesture:       UIPanGestureRecognizer!
    private var tapGesture:       UITapGestureRecognizer!
    private var doubleTapGesture: UITapGestureRecognizer!
    private var longPressGesture: UILongPressGestureRecognizer!

    // MARK: - Init

    init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?,
         binaryMessenger messenger: FlutterBinaryMessenger) {
        _view         = UIView(frame: frame)
        pdfView       = SafePDFView(frame: frame)
        methodChannel = FlutterMethodChannel(name: "advanced_pdf_viewer_\(viewId)", binaryMessenger: messenger)
        super.init()

        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.autoScales       = false
        pdfView.displayMode      = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.minScaleFactor   = 0.5
        pdfView.maxScaleFactor   = 5.0
        _view.addSubview(pdfView)

        overlayView = UIView(frame: frame)
        overlayView.backgroundColor          = .clear
        overlayView.autoresizingMask         = [.flexibleWidth, .flexibleHeight]
        overlayView.isUserInteractionEnabled = false
        _view.addSubview(overlayView)

        previewLayer       = SelectionPreviewLayer()
        previewLayer.frame = frame
        overlayView.layer.addSublayer(previewLayer)

        if let d = args as? [String: Any] {
            if let t = d["isTempFile"] as? Bool { isTempFile = t }
            if let p = d["path"]       as? String { loadPdf(path: p) }
        }

        methodChannel.setMethodCallHandler(handle)
        setupGestureRecognizers()
        setupMenuController()
        setupPageChangeObserver()
    }

    private func setupPageChangeObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: pdfView)
    }
    @objc private func pageChanged(_ n: Notification) {
        guard let doc = pdfView.document, let pg = pdfView.currentPage else { return }
        let idx = doc.index(for: pg)
        if idx != currentPage {
            currentPage = idx
            methodChannel.invokeMethod("onPageChanged", arguments: currentPage)
        }
    }
    func view() -> UIView { return _view }

    // MARK: - Load PDF

    private func loadPdf(path: String) {
        let url = URL(fileURLWithPath: path)
        if isTempFile {
            do {
                let data = try Data(contentsOf: url)
                if let doc = NumberedPDFDocument(data: data) {
                    pdfView.document = doc; pdfView.scaleFactor = 0.5; updatePageNumbersState()
                }
                try FileManager.default.removeItem(at: url)
            } catch { print("Error loading temp PDF: \(error)") }
        } else {
            if let doc = NumberedPDFDocument(url: url) {
                pdfView.document = doc; pdfView.scaleFactor = 0.5; updatePageNumbersState()
            }
        }
    }

    private func updatePageNumbersState() {
        guard let doc = pdfView.document else { return }
        for i in 0..<doc.pageCount {
            if let pg = doc.page(at: i) as? NumberedPDFPage { pg.showNumber = enablePageNumber }
        }
        pdfView.layoutDocumentView()
    }

    // MARK: - Method Channel

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setDrawingMode":
            if let args = call.arguments as? [String: Any], let tool = args["tool"] as? String {
                if tool == "none" { cancelLiveSelection() }
                currentTool = tool; result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Tool is required", details: nil))
            }
        case "clearAnnotations":
            clearAnnotations(); result(nil)
        case "savePdf":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if let data = self.pdfView.document?.dataRepresentation() {
                    DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
                } else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "SAVE_ERROR", message: "Could not save PDF", details: nil))
                    }
                }
            }
        case "addTextAnnotation":
            if let args = call.arguments as? [String: Any],
               let text = args["text"] as? String,
               let x = args["x"] as? Double, let y = args["y"] as? Double {
                addTextAnnotation(text: text, at: CGPoint(x: x, y: y),
                                  color: (args["color"] as? Int).map { UIColor(argb: $0) })
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Text, x, and y are required", details: nil))
            }
        case "jumpToPage":
            if let args = call.arguments as? [String: Any],
               var idx = args["page"] as? Int, let doc = pdfView.document {
                idx = max(0, min(idx, doc.pageCount - 1))
                if let pg = doc.page(at: idx) { pdfView.go(to: pg) }
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_PAGE", message: "Invalid page index", details: nil))
            }
        case "getTotalPages":
            result(pdfView.document?.pageCount ?? 0)
        case "updateConfig":
            if let args = call.arguments as? [String: Any] {
                if let c = args["drawColor"]      as? Int  { drawColor      = UIColor(argb: c) }
                if let c = args["highlightColor"] as? Int  { highlightColor = UIColor(argb: c); updateHandleColors() }
                if let c = args["underlineColor"] as? Int  { underlineColor = UIColor(argb: c); updateHandleColors() }
                if let v = args["enablePageNumber"] as? Bool { enablePageNumber = v; updatePageNumbersState() }
                result(nil)
            }
        case "setScrollLocked":
            if let args = call.arguments as? [String: Any], let locked = args["locked"] as? Bool {
                setScrollLocked(locked); result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Locked state is required", details: nil))
            }
        case "zoomIn":
            pdfView.scaleFactor = min(pdfView.scaleFactor + 0.2, pdfView.maxScaleFactor); result(nil)
        case "zoomOut":
            pdfView.scaleFactor = max(pdfView.scaleFactor - 0.2, pdfView.minScaleFactor); result(nil)
        case "undo":
            if let ref = undoStack.popLast(), let doc = pdfView.document,
               let pg = doc.page(at: ref.pageIndex) {
                pg.removeAnnotation(ref.annotation); redoStack.append(ref)
            }
            result(nil)
        case "redo":
            if let ref = redoStack.popLast(), let doc = pdfView.document,
               let pg = doc.page(at: ref.pageIndex) {
                pg.addAnnotation(ref.annotation); undoStack.append(ref)
            }
            result(nil)
        case "setZoom":
            if let args = call.arguments as? [String: Any], let scale = args["scale"] as? Double {
                pdfView.scaleFactor = CGFloat(max(Double(pdfView.minScaleFactor),
                                                  min(scale, Double(pdfView.maxScaleFactor))))
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Scale is required", details: nil))
            }
        case "getCurrentPage":
            result(currentPage)
        case "searchText":
            if let args = call.arguments as? [String: Any], let query = args["query"] as? String {
                searchText(query); result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Query is required", details: nil))
            }
        case "nextSearchResult":    nextSearchResult(); result(nil)
        case "previousSearchResult": previousSearchResult(); result(nil)
        case "clearSearch":         clearSearch(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Scroll Lock

    private func setScrollLocked(_ locked: Bool) {
        for sv in pdfView.subviews {
            if let s = sv as? UIScrollView { s.isScrollEnabled = !locked; return }
        }
    }

    // MARK: - Gestures

    private func setupGestureRecognizers() {
        // Pan — drawing and swipe-to-select
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate                = self
        panGesture.minimumNumberOfTouches  = 1
        panGesture.maximumNumberOfTouches  = 1
        overlayView.addGestureRecognizer(panGesture)

        // Double tap — sentence selection
        doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        overlayView.addGestureRecognizer(doubleTapGesture)

        // Single tap — word annotation (only fires when double-tap fails)
        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.numberOfTapsRequired = 1
        tapGesture.require(toFail: doubleTapGesture)
        overlayView.addGestureRecognizer(tapGesture)

        // Long press — anchor word + drag to extend
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.32
        longPressGesture.delegate             = self
        overlayView.addGestureRecognizer(longPressGesture)

        // Pan starts only if tap fails (prevents single-tap cancelling pan accidentally)
        panGesture.require(toFail: tapGesture)
    }

    private func updateOverlayInteraction() {
        let active = currentTool != "none"
        overlayView.isUserInteractionEnabled = active
        pdfView.disableInteraction           = active
        if active { _view.bringSubviewToFront(overlayView) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = overlayView.bounds
        CATransaction.commit()

        if !active { cancelLiveSelection() }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
        // Allow long-press + pan simultaneously for hold-then-drag
        if (g is UILongPressGestureRecognizer && o is UIPanGestureRecognizer) ||
           (g is UIPanGestureRecognizer && o is UILongPressGestureRecognizer) { return true }
        return currentTool == "none"
    }

    // MARK: - Pan

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        if currentTool == "draw" {
            handleDrawPan(gesture)
        } else if (currentTool == "highlight" || currentTool == "underline") && !isWordSnapMode {
            handleSelectionPan(gesture)
        }
    }

    // MARK: - Long Press → anchor word + drag

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard currentTool == "highlight" || currentTool == "underline" else { return }
        let loc = gesture.location(in: pdfView)

        switch gesture.state {
        case .began:
            isWordSnapMode = true
            isDragging     = false
            guard let pg = pdfView.page(for: loc, nearest: true), pageHasText(pg) else { return }
            let pt = pdfView.convert(loc, to: pg)
            selectionPage       = pg
            selectionStartPoint = pt
            selectionAnchorWord = wordSelection(at: pt, on: pg)
            if let sel = selectionAnchorWord {
                isRTLSelection = detectRTL(sel, on: pg)
                updateLiveSelection(sel, on: pg, animated: false)
                triggerHaptic(style: .medium)
            }

        case .changed:
            guard let pg = selectionPage ?? pdfView.page(for: loc, nearest: true),
                  pageHasText(pg),
                  let startPt = selectionStartPoint else { return }
            let pt   = pdfView.convert(loc, to: pg)
            let dist = hypot(pt.x - startPt.x, pt.y - startPt.y)
            guard dist > dragThreshold else { return }
            isDragging = true

            let now = Date().timeIntervalSince1970
            guard now - lastSelectionUpdateTime > selectionUpdateInterval else { return }
            lastSelectionUpdateTime = now

            if let sel = wordSnappedSelection(from: startPt, to: pt, on: pg) {
                currentLiveSelection = sel
                isRTLSelection       = detectRTL(sel, on: pg)
                updateLiveSelection(sel, on: pg, animated: true)
            }

        case .ended, .cancelled:
            let pg = selectionPage ?? pdfView.page(for: loc, nearest: true)
            defer { resetSelectionGestureState() }
            guard let pg = pg, pageHasText(pg), let startPt = selectionStartPoint else {
                cancelLiveSelection(); return
            }
            let pt = pdfView.convert(loc, to: pg)

            let finalSel: PDFSelection?
            if isDragging {
                finalSel = wordSnappedSelection(from: startPt, to: pt, on: pg)
            } else {
                finalSel = selectionAnchorWord
            }

            guard let sel = finalSel, let s = sel.string, !s.isEmpty else {
                cancelLiveSelection(); return
            }
            currentLiveSelection = sel
            updateLiveSelection(sel, on: pg, animated: false)
            showHandles(for: sel, on: pg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
                self?.commitAndClearLiveSelection()
            }

        default: break
        }
    }

    // MARK: - Double Tap → sentence selection

    @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard currentTool == "highlight" || currentTool == "underline" else { return }
        let loc = gesture.location(in: pdfView)
        guard let pg = pdfView.page(for: loc, nearest: true), pageHasText(pg) else { return }
        let pt = pdfView.convert(loc, to: pg)

        guard let sel = sentenceSelection(at: pt, on: pg),
              let s = sel.string, !s.isEmpty else { return }

        triggerHaptic(style: .rigid)
        selectionPage        = pg
        currentLiveSelection = sel
        isRTLSelection       = detectRTL(sel, on: pg)
        updateLiveSelection(sel, on: pg, animated: true)
        showHandles(for: sel, on: pg)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { [weak self] in
            self?.commitAndClearLiveSelection()
        }
    }

    // MARK: - Tap → single word

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let loc = gesture.location(in: pdfView)
        if currentTool == "text" {
            methodChannel.invokeMethod("onPdfTapped", arguments: ["x": loc.x, "y": loc.y])
            return
        }
        guard currentTool == "highlight" || currentTool == "underline" else { return }
        guard let pg = pdfView.page(for: loc, nearest: true), pageHasText(pg) else { return }
        let pt = pdfView.convert(loc, to: pg)

        guard let wordSel = wordSelection(at: pt, on: pg),
              let s = wordSel.string, !s.isEmpty else { return }

        triggerHaptic(style: .light)
        selectionPage        = pg
        currentLiveSelection = wordSel
        isRTLSelection       = detectRTL(wordSel, on: pg)
        updateLiveSelection(wordSel, on: pg, animated: true)
        showHandles(for: wordSel, on: pg)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            self?.commitAndClearLiveSelection()
        }
    }

    // MARK: - Swipe Pan Select

    private func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
        let loc = gesture.location(in: pdfView)
        guard let pg = pdfView.page(for: loc, nearest: true), pageHasText(pg) else { return }
        let pt = pdfView.convert(loc, to: pg)

        switch gesture.state {
        case .began:
            selectionStartPoint     = pt
            selectionPage           = pg
            lastSelectionUpdateTime = Date().timeIntervalSince1970
            isDragging              = false

        case .changed:
            guard let startPt = selectionStartPoint else { return }
            guard hypot(pt.x - startPt.x, pt.y - startPt.y) > dragThreshold else { return }
            isDragging = true
            let now = Date().timeIntervalSince1970
            guard now - lastSelectionUpdateTime > selectionUpdateInterval else { return }
            lastSelectionUpdateTime = now

            if let sel = wordSnappedSelection(from: startPt, to: pt, on: pg) {
                currentLiveSelection = sel
                isRTLSelection       = detectRTL(sel, on: pg)
                updateLiveSelection(sel, on: pg, animated: true)
            }

        case .ended, .cancelled:
            defer { resetSelectionGestureState() }
            guard isDragging, let startPt = selectionStartPoint else { cancelLiveSelection(); return }
            guard let sel = wordSnappedSelection(from: startPt, to: pt, on: pg),
                  let s = sel.string, !s.isEmpty else { cancelLiveSelection(); return }
            currentLiveSelection = sel
            updateLiveSelection(sel, on: pg, animated: false)
            showHandles(for: sel, on: pg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
                self?.commitAndClearLiveSelection()
            }

        default: break
        }
    }

    // MARK: - Draw

    private func handleDrawPan(_ gesture: UIPanGestureRecognizer) {
        let loc = gesture.location(in: pdfView)
        guard let pg = pdfView.page(for: loc, nearest: true) else { return }
        let pt = pdfView.convert(loc, to: pg)
        switch gesture.state {
        case .began:
            currentPath = UIBezierPath(); currentPath?.move(to: pt)
            let ann = PDFAnnotation(bounds: pg.bounds(for: .mediaBox), forType: .ink, withProperties: nil)
            ann.color = drawColor; ann.border = PDFBorder(); ann.border?.lineWidth = 3
            currentAnnotation = ann; pg.addAnnotation(ann)
        case .changed:
            currentPath?.addLine(to: pt)
            if let p = currentPath { currentAnnotation?.add(p) }
        case .ended, .cancelled:
            if let ann = currentAnnotation, let p = ann.page, let doc = pdfView.document {
                undoStack.append(AnnotationReference(annotation: ann, pageIndex: doc.index(for: p)))
                redoStack.removeAll()
            }
            currentPath = nil; currentAnnotation = nil
        default: break
        }
    }

    // MARK: - Live Selection Preview

    private func updateLiveSelection(_ selection: PDFSelection, on page: PDFPage, animated: Bool) {
        pdfView.currentSelection = selection

        var screenRects: [CGRect] = []
        for pg in selection.pages {
            let b = selection.bounds(for: pg)
            if isValidBounds(b) {
                let r = pdfView.convert(b, from: pg)
                screenRects.append(overlayView.convert(r, from: pdfView))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        previewLayer.frame = overlayView.bounds
        previewLayer.update(rects: screenRects, animated: animated)
        CATransaction.commit()
    }

    // MARK: - Selection Handles

    private func handleColor() -> UIColor {
        return (currentTool == "highlight" ? highlightColor : underlineColor)
            .withAlphaComponent(1.0)
    }

    private func showHandles(for selection: PDFSelection, on page: PDFPage) {
        removeHandles()
        guard let firstPage = selection.pages.first,
              let lastPage  = selection.pages.last else { return }

        let color = handleColor()
        let sH = SelectionHandleView(side: .start, color: color)
        let eH = SelectionHandleView(side: .end,   color: color)

        let sB = selection.bounds(for: firstPage)
        let eB = selection.bounds(for: lastPage)

        // RTL: start anchor is right edge of first word; LTR: left edge
        let startPagePt = isRTLSelection
            ? CGPoint(x: sB.maxX, y: sB.minY)
            : CGPoint(x: sB.minX, y: sB.minY)
        let endPagePt = isRTLSelection
            ? CGPoint(x: eB.minX, y: eB.maxY)
            : CGPoint(x: eB.maxX, y: eB.maxY)

        sH.pagePt = startPagePt; sH.pdfPage = firstPage
        eH.pagePt = endPagePt;   eH.pdfPage = lastPage

        positionHandle(sH, pagePt: startPagePt, page: firstPage)
        positionHandle(eH, pagePt: endPagePt,   page: lastPage)

        overlayView.addSubview(sH)
        overlayView.addSubview(eH)
        sH.animateAppear()
        eH.animateAppear()

        // Attach pan gestures directly on each handle view
        let sPan = UIPanGestureRecognizer(target: self, action: #selector(handleHandlePan(_:)))
        sPan.delegate = self
        sH.addGestureRecognizer(sPan)

        let ePan = UIPanGestureRecognizer(target: self, action: #selector(handleHandlePan(_:)))
        ePan.delegate = self
        eH.addGestureRecognizer(ePan)

        startHandle = sH
        endHandle   = eH
    }

    private func positionHandle(_ handle: SelectionHandleView, pagePt: CGPoint, page: PDFPage) {
        let screenPt  = pdfView.convert(pagePt, from: page)
        let overlayPt = overlayView.convert(screenPt, from: pdfView)
        let r: CGFloat    = 10
        let stemH: CGFloat = 10
        let x = overlayPt.x - r
        let y = handle.side == .start
            ? overlayPt.y - stemH - r * 2   // handle floats above the line start
            : overlayPt.y                   // handle hangs below the line end
        handle.frame.origin = CGPoint(x: x, y: y)
    }

    private func repositionHandles(for selection: PDFSelection) {
        guard let firstPage = selection.pages.first,
              let lastPage  = selection.pages.last,
              let sH = startHandle, let eH = endHandle else { return }

        let sB = selection.bounds(for: firstPage)
        let eB = selection.bounds(for: lastPage)

        let startPagePt = isRTLSelection
            ? CGPoint(x: sB.maxX, y: sB.minY) : CGPoint(x: sB.minX, y: sB.minY)
        let endPagePt = isRTLSelection
            ? CGPoint(x: eB.minX, y: eB.maxY) : CGPoint(x: eB.maxX, y: eB.maxY)

        sH.pagePt = startPagePt; sH.pdfPage = firstPage
        eH.pagePt = endPagePt;   eH.pdfPage = lastPage

        UIView.animate(withDuration: 0.06) {
            self.positionHandle(sH, pagePt: startPagePt, page: firstPage)
            self.positionHandle(eH, pagePt: endPagePt,   page: lastPage)
        }
    }

    @objc private func handleHandlePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? SelectionHandleView,
              let _      = handle.pdfPage else { return }

        switch gesture.state {
        case .began:
            activeHandle = handle
            triggerHaptic(style: .light)
            // Capture the *opposite* handle's page-space point as fixed anchor
            handleDragOppositePoint = handle.side == .start
                ? (endHandle?.pagePt   ?? .zero)
                : (startHandle?.pagePt ?? .zero)

        case .changed:
            let locInOverlay = gesture.location(in: overlayView)
            let locInPdf     = pdfView.convert(locInOverlay, from: overlayView)
            guard let pg = pdfView.page(for: locInPdf, nearest: true), pageHasText(pg) else { return }
            let pagePt = pdfView.convert(locInPdf, to: pg)

            guard let dragWord  = pg.selectionForWord(at: pagePt) else { return }
            let dragBounds = dragWord.bounds(for: pg)
            let oppPt      = handleDragOppositePoint
            let refPage    = selectionPage ?? pg

            // Derive from/to for the expanded selection, accounting for RTL
            let fromPt: CGPoint
            let toPt:   CGPoint
            if handle.side == .start {
                fromPt = isRTLSelection
                    ? CGPoint(x: dragBounds.maxX, y: dragBounds.midY)
                    : CGPoint(x: dragBounds.minX, y: dragBounds.midY)
                toPt   = oppPt
            } else {
                fromPt = oppPt
                toPt   = isRTLSelection
                    ? CGPoint(x: dragBounds.minX, y: dragBounds.midY)
                    : CGPoint(x: dragBounds.maxX, y: dragBounds.midY)
            }

            if let newSel = wordSnappedSelection(from: fromPt, to: toPt, on: refPage),
               let s = newSel.string, !s.isEmpty {
                currentLiveSelection = newSel
                isRTLSelection       = detectRTL(newSel, on: refPage)
                updateLiveSelection(newSel, on: refPage, animated: false)
                repositionHandles(for: newSel)
            }

        case .ended, .cancelled:
            activeHandle = nil
            if let sel = currentLiveSelection, let s = sel.string, !s.isEmpty {
                commitAnnotation(sel)
            }
            previewLayer.clearAnimated()
            removeHandles()
            pdfView.currentSelection = nil
            currentLiveSelection     = nil

        default: break
        }
    }

    private func updateHandleColors() {
        let c = handleColor()
        startHandle?.setColor(c)
        endHandle?.setColor(c)
    }

    private func removeHandles() {
        startHandle?.animateDisappear(); startHandle = nil
        endHandle?.animateDisappear();   endHandle   = nil
    }

    // MARK: - Commit / Cancel Selection

    private func commitAndClearLiveSelection() {
        guard let sel = currentLiveSelection else { cancelLiveSelection(); return }
        commitAnnotation(sel)
        previewLayer.clearAnimated()
        removeHandles()
        pdfView.currentSelection = nil
        currentLiveSelection     = nil
        selectionPage            = nil
    }

    private func cancelLiveSelection() {
        previewLayer.clearAnimated()
        removeHandles()
        pdfView.currentSelection = nil
        currentLiveSelection     = nil
        selectionPage            = nil
    }

    private func resetSelectionGestureState() {
        isWordSnapMode      = false
        isDragging          = false
        selectionAnchorWord = nil
        selectionStartPoint = nil
    }

    // MARK: - Annotation Commit

    private func commitAnnotation(_ selection: PDFSelection) {
        let type  = currentTool == "highlight"
            ? PDFAnnotationSubtype.highlight
            : PDFAnnotationSubtype.underline
        let color = currentTool == "highlight" ? highlightColor : underlineColor
        guard !selection.pages.isEmpty, let text = selection.string, !text.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for pg in selection.pages {
                let b = selection.bounds(for: pg)
                guard self.isValidBounds(b) else { continue }
                DispatchQueue.main.async {
                    let ann = PDFAnnotation(bounds: b.standardized, forType: type, withProperties: nil)
                    ann.color = color
                    pg.addAnnotation(ann)
                    if let doc = self.pdfView.document {
                        self.undoStack.append(AnnotationReference(annotation: ann,
                                                                   pageIndex: doc.index(for: pg)))
                        self.redoStack.removeAll()
                    }
                }
            }
        }
    }

    // MARK: - Word / Sentence / Snapped Selection

    private func pageHasText(_ page: PDFPage) -> Bool {
        guard let t = ObjCExceptionHandler.safelyGetPageString(page) else { return false }
        return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns the word under a page-space point.
    private func wordSelection(at point: CGPoint, on page: PDFPage) -> PDFSelection? {
        if let sel = page.selectionForWord(at: point),
           let s = sel.string,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return sel }
        return ObjCExceptionHandler.safelyGetSelectionForLine(at: point, on: page)
    }

    /// Returns the sentence containing a page-space point by scanning the page string
    /// outward from the nearest word to the closest sentence-ending punctuation.
    private func sentenceSelection(at point: CGPoint, on page: PDFPage) -> PDFSelection? {
        guard let rawText = ObjCExceptionHandler.safelyGetPageString(page),
              !rawText.isEmpty else { return nil }
        guard let wordSel = page.selectionForWord(at: point),
              let wordStr = wordSel.string, !wordStr.isEmpty else { return nil }

        let ns = rawText as NSString
        let wordRange = ns.range(of: wordStr, options: .caseInsensitive)
        guard wordRange.location != NSNotFound else { return wordSel }

        let terminators = CharacterSet(charactersIn: ".!?؟。\n")

        // Walk backward to sentence start
        var sentStart = wordRange.location
        if sentStart > 0 {
            var i = Int(sentStart) - 1
            while i >= 0 {
                let ch = ns.substring(with: NSRange(location: i, length: 1))
                if ch.unicodeScalars.contains(where: { terminators.contains($0) }) {
                    sentStart = i + 1
                    // skip leading whitespace
                    while sentStart < ns.length {
                        let ws = ns.substring(with: NSRange(location: sentStart, length: 1))
                        if ws == " " || ws == "\t" { sentStart += 1 } else { break }
                    }
                    break
                }
                i -= 1
                if i < 0 { sentStart = 0 }
            }
        }

        // Walk forward to sentence end
        var sentEnd = wordRange.location + wordRange.length
        while sentEnd < ns.length {
            let ch = ns.substring(with: NSRange(location: sentEnd, length: 1))
            sentEnd += 1
            if ch.unicodeScalars.contains(where: { terminators.contains($0) }) { break }
        }

        let fullRange = NSRange(location: sentStart, length: sentEnd - sentStart)
        guard fullRange.length > 0 else { return wordSel }
        return page.selection(for: fullRange)
    }

    /// Word-boundary-snapped selection from `start` to `end` (page-space).
    private func wordSnappedSelection(from start: CGPoint, to end: CGPoint, on page: PDFPage) -> PDFSelection? {
        guard let startWord = page.selectionForWord(at: start) else {
            return ObjCExceptionHandler.safelyCreateSelection(from: start, to: end, on: page)
        }
        guard let endWord = page.selectionForWord(at: end) else { return startWord }

        let sB = startWord.bounds(for: page)
        let eB = endWord.bounds(for: page)
        let fromPt = CGPoint(x: sB.minX, y: sB.midY)
        let toPt   = CGPoint(x: eB.maxX, y: eB.midY)

        if let expanded = ObjCExceptionHandler.safelyCreateSelection(from: fromPt, to: toPt, on: page),
           let s = expanded.string,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return expanded }
        return startWord
    }

    // MARK: - RTL Detection

    /// Returns true if the selection is right-to-left (Arabic, Hebrew, etc.)
    private func detectRTL(_ selection: PDFSelection, on page: PDFPage) -> Bool {
        guard let text = selection.string, !text.isEmpty else { return false }
        for scalar in text.unicodeScalars {
            if scalar.value == 0x20 || scalar.value == 0x09 { continue }
            return ArabicNormalizer.isArabicScalar(scalar) ||
                   (scalar.value >= 0x0590 && scalar.value <= 0x05FF) // Hebrew
        }
        return false
    }

    // MARK: - Haptic

    private func triggerHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: - Bounds Validation

    private func isValidBounds(_ b: CGRect) -> Bool {
        return !b.isEmpty && !b.isNull && b.width > 0 && b.height > 0 &&
               b.width < 5000 && b.height < 5000 &&
               !b.origin.x.isNaN && !b.origin.y.isNaN &&
               !b.size.width.isNaN && !b.size.height.isNaN
    }

    // MARK: - Menu Controller

    private func setupMenuController() {
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: "Highlight", action: #selector(menuHighlight(_:))),
            UIMenuItem(title: "Underline", action: #selector(menuUnderline(_:)))
        ]
    }
    @objc func menuHighlight(_ sender: Any) {
        if let sel = pdfView.currentSelection, let pg = sel.pages.first {
            let ann = PDFAnnotation(bounds: sel.bounds(for: pg), forType: .highlight, withProperties: nil)
            ann.color = highlightColor; pg.addAnnotation(ann)
            if let doc = pdfView.document {
                undoStack.append(AnnotationReference(annotation: ann, pageIndex: doc.index(for: pg)))
                redoStack.removeAll()
            }
        }
    }
    @objc func menuUnderline(_ sender: Any) {
        if let sel = pdfView.currentSelection, let pg = sel.pages.first {
            let ann = PDFAnnotation(bounds: sel.bounds(for: pg), forType: .underline, withProperties: nil)
            ann.color = underlineColor; pg.addAnnotation(ann)
            if let doc = pdfView.document {
                undoStack.append(AnnotationReference(annotation: ann, pageIndex: doc.index(for: pg)))
                redoStack.removeAll()
            }
        }
    }

    private func addTextAnnotation(text: String, at point: CGPoint, color: UIColor?) {
        guard let pg = pdfView.page(for: point, nearest: true) else { return }
        let pt = pdfView.convert(point, to: pg)
        let ann = PDFAnnotation(bounds: CGRect(x: pt.x, y: pt.y, width: 200, height: 50),
                                forType: .freeText, withProperties: nil)
        ann.contents  = text
        ann.font      = UIFont.systemFont(ofSize: 14)
        ann.fontColor = color ?? .black
        ann.color     = .clear
        pg.addAnnotation(ann)
    }

    private func clearAnnotations() {
        guard let doc = pdfView.document else { return }
        for i in 0..<doc.pageCount {
            if let pg = doc.page(at: i) { for ann in pg.annotations { pg.removeAnnotation(ann) } }
        }
    }

    // MARK: - Search

    private func searchText(_ query: String) {
        guard let document = pdfView.document else { return }
        clearSearch()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let isArabic = q.unicodeScalars.contains(where: { ArabicNormalizer.isArabicScalar($0) })

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var results: [PDFSelection] = isArabic
                ? self.arabicSearch(query: q, in: document)
                : document.findString(q, withOptions: [.caseInsensitive])

            results.sort { a, b in
                guard let pa = a.pages.first, let pb = b.pages.first else { return false }
                let ia = document.index(for: pa), ib = document.index(for: pb)
                if ia != ib { return ia < ib }
                let ba = a.bounds(for: pa), bb = b.bounds(for: pb)
                if abs(ba.origin.y - bb.origin.y) > 3 { return ba.origin.y > bb.origin.y }
                return ba.origin.x > bb.origin.x
            }
            DispatchQueue.main.async {
                self.searchResults      = results
                self.currentSearchIndex = results.isEmpty ? -1 : 0
                self.addAllSearchHighlights()
                if !results.isEmpty { self.navigateToResult(at: 0) }
                self.notifySearchResults()
            }
        }
    }

    private func addAllSearchHighlights() {
        guard let document = pdfView.document else { return }
        removeAllSearchHighlights()
        for (index, selection) in searchResults.enumerated() {
            guard let page = selection.pages.first else { continue }
            let bounds = selection.bounds(for: page)
            guard isValidBounds(bounds) else { continue }
            let color = index == currentSearchIndex ? searchCurrentColor : searchAllColor
            let ann = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            ann.color = color
            ann.setValue(index, forAnnotationKey: PDFAnnotationKey(rawValue: "/SearchResultIndex"))
            page.addAnnotation(ann)
            searchHighlightAnnotations.append(ann)
            searchResultAnnotations[index] = ann
        }
        _ = document
    }

    private func updateCurrentHighlightColor(previous: Int, current: Int) {
        func swap(index: Int, to color: UIColor) {
            guard index >= 0, index < searchResults.count,
                  let ann = searchResultAnnotations[index], let pg = ann.page else { return }
            pg.removeAnnotation(ann)
            let bounds = searchResults[index].bounds(for: pg)
            guard isValidBounds(bounds) else { return }
            let newAnn = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            newAnn.color = color
            pg.addAnnotation(newAnn)
            searchHighlightAnnotations.removeAll { $0 === ann }
            searchHighlightAnnotations.append(newAnn)
            searchResultAnnotations[index] = newAnn
        }
        swap(index: previous, to: searchAllColor)
        swap(index: current,  to: searchCurrentColor)
    }

    private func removeAllSearchHighlights() {
        for ann in searchHighlightAnnotations { ann.page?.removeAnnotation(ann) }
        searchHighlightAnnotations.removeAll()
        searchResultAnnotations.removeAll()
    }

    private func navigateToResult(at index: Int) {
        guard index >= 0, index < searchResults.count else { return }
        pdfView.go(to: searchResults[index])
    }

    private func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        let prev = currentSearchIndex
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
        updateCurrentHighlightColor(previous: prev, current: currentSearchIndex)
        navigateToResult(at: currentSearchIndex)
        notifySearchResults()
    }

    private func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        let prev = currentSearchIndex
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        updateCurrentHighlightColor(previous: prev, current: currentSearchIndex)
        navigateToResult(at: currentSearchIndex)
        notifySearchResults()
    }

    private func clearSearch() {
        removeAllSearchHighlights()
        searchResults = []; currentSearchIndex = -1
        pdfView.currentSelection = nil
        notifySearchResults()
    }

    private func notifySearchResults() {
        methodChannel.invokeMethod("onSearchResultsChanged", arguments: [
            "current": currentSearchIndex + 1,
            "total":   searchResults.count
        ])
    }

    // MARK: - Arabic Search Core

    private func arabicSearch(query: String, in document: PDFDocument) -> [PDFSelection] {
        let queryNorm     = ArabicNormalizer.normalize(query)
        guard !queryNorm.isEmpty else { return [] }
        let queryRev      = String(queryNorm.reversed())
        let queryRevWords = ArabicNormalizer.reverseWords(queryNorm)
        var results: [PDFSelection] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            guard let rawText = ObjCExceptionHandler.safelyGetPageString(page),
                  !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let mapping  = ArabicNormalizer.buildNormalizationMap(for: rawText)
            let pageNorm = mapping.normalizedText

            let forwardMatches = findAllOccurrences(of: queryNorm, in: pageNorm)
            var pageResults: [PDFSelection] = []
            for nr in forwardMatches {
                if let s = makeSelection(page: page, normRange: nr, mapping: mapping, rawText: rawText) {
                    pageResults.append(s)
                }
            }
            if !pageResults.isEmpty { results.append(contentsOf: pageResults); continue }

            var revMatches = findAllOccurrences(of: queryRev, in: pageNorm)
            if queryRevWords != queryRev && queryRevWords != queryNorm {
                revMatches.append(contentsOf: findAllOccurrences(of: queryRevWords, in: pageNorm))
            }
            for nr in revMatches {
                if let s = makeSelection(page: page, normRange: nr, mapping: mapping, rawText: rawText) {
                    pageResults.append(s)
                }
            }
            results.append(contentsOf: pageResults)
        }
        return deduplicateResults(results, in: document)
    }

    private func makeSelection(page: PDFPage, normRange: NSRange,
                                mapping: ArabicNormalizer.NormalizationMap,
                                rawText: String) -> PDFSelection? {
        guard let origRange = ArabicNormalizer.mapNormalizedRange(normRange, mapping: mapping) else { return nil }
        let utf16Range = scalarRangeToUTF16Range(origRange, in: rawText)
        guard utf16Range.length > 0,
              let sel = page.selection(for: utf16Range),
              isValidBounds(sel.bounds(for: page)) else { return nil }
        return sel
    }

    private func scalarRangeToUTF16Range(_ r: NSRange, in text: String) -> NSRange {
        let scalars = Array(text.unicodeScalars)
        guard r.location < scalars.count else { return NSRange(location: NSNotFound, length: 0) }
        let end = min(r.location + r.length, scalars.count)
        var s = 0; for i in 0..<r.location { s += scalars[i].utf16.count }
        var l = 0; for i in r.location..<end  { l += scalars[i].utf16.count }
        return NSRange(location: s, length: l)
    }

    private func findAllOccurrences(of pattern: String, in text: String) -> [NSRange] {
        guard !pattern.isEmpty, !text.isEmpty else { return [] }
        var ranges: [NSRange] = []
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while search.location < ns.length {
            let found = ns.range(of: pattern, options: .caseInsensitive, range: search)
            if found.location == NSNotFound { break }
            ranges.append(found)
            let next = found.location + max(found.length, 1)
            search = NSRange(location: next, length: ns.length - next)
        }
        return ranges
    }

    private func deduplicateResults(_ results: [PDFSelection], in document: PDFDocument) -> [PDFSelection] {
        var unique: [PDFSelection] = []
        for r in results {
            guard let pg = r.pages.first else { continue }
            let b = r.bounds(for: pg); let pi = document.index(for: pg)
            let dup = unique.contains { e in
                guard let ep = e.pages.first, document.index(for: ep) == pi else { return false }
                let eb = e.bounds(for: ep)
                return abs(eb.origin.x - b.origin.x) < 4 && abs(eb.origin.y - b.origin.y) < 4
            }
            if !dup { unique.append(r) }
        }
        return unique
    }
}

// MARK: - UIColor Extension

extension UIColor {
    convenience init(argb: Int) {
        self.init(red:   CGFloat((argb >> 16) & 0xFF) / 255.0,
                  green: CGFloat((argb >>  8) & 0xFF) / 255.0,
                  blue:  CGFloat( argb        & 0xFF) / 255.0,
                  alpha: CGFloat((argb >> 24) & 0xFF) / 255.0)
    }
}

// MARK: - Numbered PDF

class NumberedPDFDocument: PDFDocument {
    override var pageClass: AnyClass { return NumberedPDFPage.self }
}
class NumberedPDFPage: PDFPage {
    var showNumber: Bool = false
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        guard showNumber else { return }
        UIGraphicsPushContext(context); context.saveGState()
        let b = self.bounds(for: box)
        context.translateBy(x: 0, y: b.size.height); context.scaleBy(x: 1, y: -1)
        let label = self.label ?? String((self.document?.index(for: self) ?? 0) + 1)
        let str = NSAttributedString(string: label, attributes: [
            .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black
        ])
        str.draw(at: CGPoint(x: (b.width - str.size().width) / 2, y: b.height - 20))
        context.restoreGState(); UIGraphicsPopContext()
    }
}

// MARK: - ArabicNormalizer

struct ArabicNormalizer {

    static func isArabicScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x0600 && v <= 0x06FF) || (v >= 0x0750 && v <= 0x077F) ||
               (v >= 0x08A0 && v <= 0x08FF) || (v >= 0xFB50 && v <= 0xFDFF) ||
               (v >= 0xFE70 && v <= 0xFEFF)
    }
    static func isArabic(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return isArabicScalar(s)
    }

    struct NormalizationMap {
        let normalizedText: String
        let normToOrig: [Int]
    }

    static let presentationToBase: [UInt32: UInt32] = {
        let entries: [(UInt32, [UInt32])] = [
            (0x0627,[0xFE8D,0xFE8E]),(0x0628,[0xFE8F,0xFE90,0xFE91,0xFE92]),
            (0x062A,[0xFE95,0xFE96,0xFE97,0xFE98]),(0x062B,[0xFE99,0xFE9A,0xFE9B,0xFE9C]),
            (0x062C,[0xFE9D,0xFE9E,0xFE9F,0xFEA0]),(0x062D,[0xFEA1,0xFEA2,0xFEA3,0xFEA4]),
            (0x062E,[0xFEA5,0xFEA6,0xFEA7,0xFEA8]),(0x062F,[0xFEA9,0xFEAA]),
            (0x0630,[0xFEAB,0xFEAC]),(0x0631,[0xFEAD,0xFEAE]),(0x0632,[0xFEAF,0xFEB0]),
            (0x0633,[0xFEB1,0xFEB2,0xFEB3,0xFEB4]),(0x0634,[0xFEB5,0xFEB6,0xFEB7,0xFEB8]),
            (0x0635,[0xFEB9,0xFEBA,0xFEBB,0xFEBC]),(0x0636,[0xFEBD,0xFEBE,0xFEBF,0xFEC0]),
            (0x0637,[0xFEC1,0xFEC2,0xFEC3,0xFEC4]),(0x0638,[0xFEC5,0xFEC6,0xFEC7,0xFEC8]),
            (0x0639,[0xFEC9,0xFECA,0xFECB,0xFECC]),(0x063A,[0xFECD,0xFECE,0xFECF,0xFED0]),
            (0x0641,[0xFED1,0xFED2,0xFED3,0xFED4]),(0x0642,[0xFED5,0xFED6,0xFED7,0xFED8]),
            (0x0643,[0xFED9,0xFEDA,0xFEDB,0xFEDC]),(0x0644,[0xFEDD,0xFEDE,0xFEDF,0xFEE0]),
            (0x0645,[0xFEE1,0xFEE2,0xFEE3,0xFEE4]),(0x0646,[0xFEE5,0xFEE6,0xFEE7,0xFEE8]),
            (0x0647,[0xFEE9,0xFEEA,0xFEEB,0xFEEC]),(0x0648,[0xFEED,0xFEEE]),
            (0x064A,[0xFEF1,0xFEF2,0xFEF3,0xFEF4]),(0x0626,[0xFE89,0xFE8A,0xFE8B,0xFE8C]),
            (0x0622,[0xFE81,0xFE82]),(0x0623,[0xFE83,0xFE84]),(0x0625,[0xFE87,0xFE88]),
            (0x0624,[0xFE85,0xFE86]),(0x0649,[0xFEEF,0xFEF0]),(0x0629,[0xFE93,0xFE94]),
        ]
        var map = [UInt32: UInt32]()
        for (base, forms) in entries { for f in forms { map[f] = base } }
        return map
    }()

    static let lamAlefLigatures: [UInt32: (UInt32, UInt32)] = [
        0xFEF5:(0x0644,0x0622),0xFEF6:(0x0644,0x0622),0xFEF7:(0x0644,0x0623),0xFEF8:(0x0644,0x0623),
        0xFEF9:(0x0644,0x0625),0xFEFA:(0x0644,0x0625),0xFEFB:(0x0644,0x0627),0xFEFC:(0x0644,0x0627),
    ]

    static let stripSet: Set<UInt32> = {
        var s = Set<UInt32>()
        for v in UInt32(0x064B)...UInt32(0x065F) { s.insert(v) }
        s.insert(0x0670)
        for v in UInt32(0x06D6)...UInt32(0x06DC) { s.insert(v) }
        for v in UInt32(0x06DF)...UInt32(0x06E4) { s.insert(v) }
        s.insert(0x06E7); s.insert(0x06E8)
        for v in UInt32(0x06EA)...UInt32(0x06ED) { s.insert(v) }
        for v in UInt32(0x0610)...UInt32(0x061A) { s.insert(v) }
        s.insert(0x0640); s.insert(0x200C); s.insert(0x200D)
        s.insert(0x200F); s.insert(0x200E); s.insert(0xFEFF)
        return s
    }()

    static func buildNormalizationMap(for text: String) -> NormalizationMap {
        var normChars  = [Unicode.Scalar]()
        var normToOrig = [Int]()
        normChars.reserveCapacity(text.unicodeScalars.count)
        normToOrig.reserveCapacity(text.unicodeScalars.count)
        let scalars = Array(text.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            let v = scalar.value
            if stripSet.contains(v) { continue }
            if let (lam, alef) = lamAlefLigatures[v] {
                if let ls = Unicode.Scalar(lam), let as_ = Unicode.Scalar(alef) {
                    normChars.append(ls); normToOrig.append(i)
                    normChars.append(as_); normToOrig.append(i)
                }
                continue
            }
            if let base = presentationToBase[v], let bs = Unicode.Scalar(base) {
                normChars.append(bs); normToOrig.append(i); continue
            }
            normChars.append(scalar); normToOrig.append(i)
        }
        var normStr = String(String.UnicodeScalarView(normChars))
        normStr = applyUnification(normStr, normToOrig: &normToOrig)
        return NormalizationMap(normalizedText: normStr, normToOrig: normToOrig)
    }

    private static func applyUnification(_ text: String, normToOrig: inout [Int]) -> String {
        return text
            .replacingOccurrences(of: "\u{0622}", with: "\u{0627}")
            .replacingOccurrences(of: "\u{0623}", with: "\u{0627}")
            .replacingOccurrences(of: "\u{0625}", with: "\u{0627}")
            .replacingOccurrences(of: "\u{0671}", with: "\u{0627}")
            .replacingOccurrences(of: "\u{0672}", with: "\u{0627}")
            .replacingOccurrences(of: "\u{0673}", with: "\u{0627}")
            .replacingOccurrences(of: "\u{0629}", with: "\u{0647}")
            .replacingOccurrences(of: "\u{06C1}", with: "\u{0647}")
            .replacingOccurrences(of: "\u{0649}", with: "\u{064A}")
            .replacingOccurrences(of: "\u{06CC}", with: "\u{064A}")
            .replacingOccurrences(of: "\u{06D2}", with: "\u{064A}")
            .replacingOccurrences(of: "\u{0624}", with: "\u{0648}")
            .replacingOccurrences(of: "\u{0626}", with: "\u{064A}")
    }

    static func normalize(_ text: String) -> String {
        var dummy = [Int]()
        return applyUnification(buildNormalizationMap(for: text).normalizedText, normToOrig: &dummy)
    }

    static func reverseWords(_ text: String) -> String {
        text.components(separatedBy: .whitespaces).reversed().joined(separator: " ")
    }

    static func mapNormalizedRange(_ normRange: NSRange, mapping: NormalizationMap) -> NSRange? {
        let n2o = mapping.normToOrig
        guard normRange.location >= 0, normRange.length > 0,
              normRange.location < n2o.count,
              normRange.location + normRange.length <= n2o.count else { return nil }
        let origStart = n2o[normRange.location]
        let normEnd   = normRange.location + normRange.length - 1
        guard normEnd < n2o.count else { return nil }
        let origEnd = n2o[normEnd]
        let length  = origEnd - origStart + 1
        guard length > 0 else { return nil }
        return NSRange(location: origStart, length: length)
    }
}

// MARK: - Legacy ArabicShaper stub

struct ArabicShaper {
    static func isArabic(_ c: Character) -> Bool { ArabicNormalizer.isArabic(c) }
    static func normalizeString(_ text: String) -> String { ArabicNormalizer.normalize(text) }
    static func buildRegex(for query: String) -> String { return query }
    static func buildStandardRegex(for query: String) -> String { return query }
}