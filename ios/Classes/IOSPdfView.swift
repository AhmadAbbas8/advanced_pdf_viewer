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

// MARK: - IOSPdfView

class IOSPdfView: NSObject, FlutterPlatformView, UIGestureRecognizerDelegate {

    private struct AnnotationReference {
        let annotation: PDFAnnotation
        let pageIndex: Int
    }

    private var _view: UIView
    private var pdfView: SafePDFView
    private var overlayView: UIView!
    private var methodChannel: FlutterMethodChannel

    private var currentTool: String = "none" { didSet { updateOverlayInteraction() } }
    private var isTempFile: Bool = false
    private var currentPath: UIBezierPath?
    private var currentAnnotation: PDFAnnotation?
    private var undoStack: [AnnotationReference] = []
    private var redoStack: [AnnotationReference] = []
    private var drawColor: UIColor = .red
    private var highlightColor: UIColor = UIColor.yellow.withAlphaComponent(0.5)
    private var underlineColor: UIColor = .blue
    private var enablePageNumber: Bool = false
    private var currentPage: Int = 0

    // Search state
    private var searchResults: [PDFSelection] = []
    private var currentSearchIndex: Int = -1
    // All highlight annotations added during search (for cleanup)
    private var searchHighlightAnnotations: [PDFAnnotation] = []
    // Track which annotation corresponds to which result index
    private var searchResultAnnotations: [Int: PDFAnnotation] = [:]

    // Colors for search highlights
    private let searchAllColor   = UIColor.yellow.withAlphaComponent(0.45)
    private let searchCurrentColor = UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.7) // orange

    init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?, binaryMessenger messenger: FlutterBinaryMessenger) {
        _view = UIView(frame: frame)
        pdfView = SafePDFView(frame: frame)
        methodChannel = FlutterMethodChannel(name: "advanced_pdf_viewer_\(viewId)", binaryMessenger: messenger)
        super.init()
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.autoScales = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.minScaleFactor = 0.5
        pdfView.maxScaleFactor = 5.0
        _view.addSubview(pdfView)
        overlayView = UIView(frame: frame)
        overlayView.backgroundColor = .clear
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.isUserInteractionEnabled = false
        _view.addSubview(overlayView)
        if let d = args as? [String: Any] {
            if let t = d["isTempFile"] as? Bool { isTempFile = t }
            if let p = d["path"] as? String { loadPdf(path: p) }
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
    @objc private func pageChanged(_ notification: Notification) {
        guard let doc = pdfView.document, let pg = pdfView.currentPage else { return }
        let idx = doc.index(for: pg)
        if idx != currentPage { currentPage = idx; methodChannel.invokeMethod("onPageChanged", arguments: currentPage) }
    }
    func view() -> UIView { return _view }

    private func loadPdf(path: String) {
        let url = URL(fileURLWithPath: path)
        if isTempFile {
            do {
                let data = try Data(contentsOf: url)
                if let doc = NumberedPDFDocument(data: data) { pdfView.document = doc; pdfView.scaleFactor = 0.5; updatePageNumbersState() }
                try FileManager.default.removeItem(at: url)
            } catch { print("Error loading temp PDF: \(error)") }
        } else {
            if let doc = NumberedPDFDocument(url: url) { pdfView.document = doc; pdfView.scaleFactor = 0.5; updatePageNumbersState() }
        }
    }
    private func updatePageNumbersState() {
        guard let doc = pdfView.document else { return }
        for i in 0..<doc.pageCount { if let pg = doc.page(at: i) as? NumberedPDFPage { pg.showNumber = enablePageNumber } }
        pdfView.layoutDocumentView()
    }

    // MARK: - Method Channel

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setDrawingMode":
            if let args = call.arguments as? [String: Any], let tool = args["tool"] as? String { self.currentTool = tool; result(nil) }
            else { result(FlutterError(code: "INVALID_ARGUMENTS", message: "Tool is required", details: nil)) }
        case "clearAnnotations":
            clearAnnotations(); result(nil)
        case "savePdf":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if let data = self.pdfView.document?.dataRepresentation() {
                    DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
                } else {
                    DispatchQueue.main.async { result(FlutterError(code: "SAVE_ERROR", message: "Could not save PDF", details: nil)) }
                }
            }
        case "addTextAnnotation":
            if let args = call.arguments as? [String: Any],
               let text = args["text"] as? String, let x = args["x"] as? Double, let y = args["y"] as? Double {
                addTextAnnotation(text: text, at: CGPoint(x: x, y: y), color: (args["color"] as? Int).map { UIColor(argb: $0) })
                result(nil)
            } else { result(FlutterError(code: "INVALID_ARGUMENTS", message: "Text, x, and y are required", details: nil)) }
        case "jumpToPage":
            if let args = call.arguments as? [String: Any], var idx = args["page"] as? Int, let doc = pdfView.document {
                idx = max(0, min(idx, doc.pageCount - 1))
                if let pg = doc.page(at: idx) { pdfView.go(to: pg) }
                result(nil)
            } else { result(FlutterError(code: "INVALID_PAGE", message: "Invalid page index", details: nil)) }
        case "getTotalPages":
            result(pdfView.document?.pageCount ?? 0)
        case "updateConfig":
            if let args = call.arguments as? [String: Any] {
                if let c = args["drawColor"] as? Int { drawColor = UIColor(argb: c) }
                if let c = args["highlightColor"] as? Int { highlightColor = UIColor(argb: c) }
                if let c = args["underlineColor"] as? Int { underlineColor = UIColor(argb: c) }
                if let v = args["enablePageNumber"] as? Bool { enablePageNumber = v; updatePageNumbersState() }
                result(nil)
            }
        case "setScrollLocked":
            if let args = call.arguments as? [String: Any], let locked = args["locked"] as? Bool { setScrollLocked(locked); result(nil) }
            else { result(FlutterError(code: "INVALID_ARGUMENTS", message: "Locked state is required", details: nil)) }
        case "zoomIn":
            pdfView.scaleFactor = min(pdfView.scaleFactor + 0.2, pdfView.maxScaleFactor); result(nil)
        case "zoomOut":
            pdfView.scaleFactor = max(pdfView.scaleFactor - 0.2, pdfView.minScaleFactor); result(nil)
        case "undo":
            if let ref = undoStack.popLast(), let doc = pdfView.document, let pg = doc.page(at: ref.pageIndex) { pg.removeAnnotation(ref.annotation); redoStack.append(ref) }
            result(nil)
        case "redo":
            if let ref = redoStack.popLast(), let doc = pdfView.document, let pg = doc.page(at: ref.pageIndex) { pg.addAnnotation(ref.annotation); undoStack.append(ref) }
            result(nil)
        case "setZoom":
            if let args = call.arguments as? [String: Any], let scale = args["scale"] as? Double {
                pdfView.scaleFactor = CGFloat(max(Double(pdfView.minScaleFactor), min(scale, Double(pdfView.maxScaleFactor)))); result(nil)
            } else { result(FlutterError(code: "INVALID_ARGUMENTS", message: "Scale is required", details: nil)) }
        case "getCurrentPage":
            result(currentPage)
        case "searchText":
            if let args = call.arguments as? [String: Any], let query = args["query"] as? String { searchText(query); result(nil) }
            else { result(FlutterError(code: "INVALID_ARGUMENTS", message: "Query is required", details: nil)) }
        case "nextSearchResult":
            nextSearchResult(); result(nil)
        case "previousSearchResult":
            previousSearchResult(); result(nil)
        case "clearSearch":
            clearSearch(); result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Scroll Lock

    private func setScrollLocked(_ locked: Bool) {
        for sv in pdfView.subviews { if let s = sv as? UIScrollView { s.isScrollEnabled = !locked; return } }
    }

    // MARK: - Gestures

    private func setupGestureRecognizers() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))); pan.delegate = self
        overlayView.addGestureRecognizer(pan)
        overlayView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }
    private func updateOverlayInteraction() {
        overlayView.isUserInteractionEnabled = currentTool != "none"
        pdfView.disableInteraction = currentTool != "none"
        if currentTool != "none" { _view.bringSubviewToFront(overlayView) }
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { currentTool == "none" }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        if currentTool == "draw" { handleDrawPan(gesture) }
        else if currentTool == "highlight" || currentTool == "underline" { handleSelectionPan(gesture) }
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
            currentPath?.addLine(to: pt); if let p = currentPath { currentAnnotation?.add(p) }
        case .ended, .cancelled:
            if let ann = currentAnnotation, let p = ann.page, let doc = pdfView.document {
                undoStack.append(AnnotationReference(annotation: ann, pageIndex: doc.index(for: p))); redoStack.removeAll()
            }
            currentPath = nil; currentAnnotation = nil
        default: break
        }
    }

    // MARK: - Selection

    private var selectionStartPoint: CGPoint?
    private var lastSelectionUpdateTime: TimeInterval = 0
    private let selectionUpdateInterval: TimeInterval = 0.016

    private func pageHasText(_ page: PDFPage) -> Bool {
        guard let t = ObjCExceptionHandler.safelyGetPageString(page) else { return false }
        return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
        let loc = gesture.location(in: pdfView)
        guard let pg = pdfView.page(for: loc, nearest: true), pageHasText(pg) else { return }
        let pt = pdfView.convert(loc, to: pg)
        switch gesture.state {
        case .began:
            selectionStartPoint = pt; lastSelectionUpdateTime = Date().timeIntervalSince1970
        case .changed:
            let now = Date().timeIntervalSince1970
            if now - lastSelectionUpdateTime > selectionUpdateInterval, let start = selectionStartPoint {
                DispatchQueue.main.async { [weak self] in
                    if let sel = ObjCExceptionHandler.safelyCreateSelection(from: start, to: pt, on: pg),
                       let s = sel.string, !s.isEmpty { self?.pdfView.currentSelection = sel }
                }
                lastSelectionUpdateTime = now
            }
        case .ended, .cancelled:
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let start = self.selectionStartPoint,
                   let sel = ObjCExceptionHandler.safelyCreateSelection(from: start, to: pt, on: pg),
                   let s = sel.string, !s.isEmpty {
                    self.pdfView.currentSelection = sel; self.addAnnotationsForSelection(sel)
                }
                self.pdfView.currentSelection = nil; self.selectionStartPoint = nil
            }
        default: break
        }
    }
    private func addAnnotationsForSelection(_ selection: PDFSelection) {
        let type: PDFAnnotationSubtype = currentTool == "highlight" ? .highlight : .underline
        let color = currentTool == "highlight" ? highlightColor : underlineColor
        guard !selection.pages.isEmpty, let text = selection.string, !text.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for pg in selection.pages {
                let b = selection.bounds(for: pg)
                guard !b.isEmpty, !b.isNull, b.width > 0, b.height > 0, b.width < 5000, b.height < 5000,
                      !b.origin.x.isNaN, !b.origin.y.isNaN, !b.size.width.isNaN, !b.size.height.isNaN else { continue }
                DispatchQueue.main.async {
                    let ann = PDFAnnotation(bounds: b.standardized, forType: type, withProperties: nil)
                    ann.color = color; pg.addAnnotation(ann)
                    if let doc = self.pdfView.document {
                        self.undoStack.append(AnnotationReference(annotation: ann, pageIndex: doc.index(for: pg)))
                        self.redoStack.removeAll()
                    }
                }
            }
        }
    }
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let loc = gesture.location(in: pdfView)
        if currentTool == "text" { methodChannel.invokeMethod("onPdfTapped", arguments: ["x": loc.x, "y": loc.y]); return }
        guard currentTool == "highlight" || currentTool == "underline" else { return }
        guard let pg = pdfView.page(for: loc, nearest: true), pageHasText(pg) else { return }
        let pt = pdfView.convert(loc, to: pg)
        if let sel = ObjCExceptionHandler.safelyGetSelectionForLine(at: pt, on: pg), let s = sel.string, !s.isEmpty { addAnnotationsForSelection(sel) }
    }
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
            if let doc = pdfView.document { undoStack.append(AnnotationReference(annotation: ann, pageIndex: doc.index(for: pg))); redoStack.removeAll() }
        }
    }
    @objc func menuUnderline(_ sender: Any) {
        if let sel = pdfView.currentSelection, let pg = sel.pages.first {
            let ann = PDFAnnotation(bounds: sel.bounds(for: pg), forType: .underline, withProperties: nil)
            ann.color = underlineColor; pg.addAnnotation(ann)
            if let doc = pdfView.document { undoStack.append(AnnotationReference(annotation: ann, pageIndex: doc.index(for: pg))); redoStack.removeAll() }
        }
    }
    private func addTextAnnotation(text: String, at point: CGPoint, color: UIColor?) {
        guard let pg = pdfView.page(for: point, nearest: true) else { return }
        let pt = pdfView.convert(point, to: pg)
        let ann = PDFAnnotation(bounds: CGRect(x: pt.x, y: pt.y, width: 200, height: 50), forType: .freeText, withProperties: nil)
        ann.contents = text; ann.font = UIFont.systemFont(ofSize: 14)
        ann.fontColor = color ?? .black; ann.color = .clear; pg.addAnnotation(ann)
    }
    private func clearAnnotations() {
        guard let doc = pdfView.document else { return }
        for i in 0..<doc.pageCount { if let pg = doc.page(at: i) { for ann in pg.annotations { pg.removeAnnotation(ann) } } }
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
            var results: [PDFSelection]
            if isArabic {
                results = self.arabicSearch(query: q, in: document)
            } else {
                results = document.findString(q, withOptions: [.caseInsensitive])
            }
            // Sort: page order, then top-to-bottom
            results.sort { a, b in
                guard let pa = a.pages.first, let pb = b.pages.first else { return false }
                let ia = document.index(for: pa), ib = document.index(for: pb)
                if ia != ib { return ia < ib }
                let ba = a.bounds(for: pa), bb = b.bounds(for: pb)
                if abs(ba.origin.y - bb.origin.y) > 3 { return ba.origin.y > bb.origin.y }
                return ba.origin.x > bb.origin.x // RTL: rightmost first
            }
            DispatchQueue.main.async {
                self.searchResults = results
                self.currentSearchIndex = results.isEmpty ? -1 : 0
                // Add highlight annotations for ALL results
                self.addAllSearchHighlights()
                if !results.isEmpty { self.navigateToResult(at: 0) }
                self.notifySearchResults()
            }
        }
    }

    // MARK: - Search Highlight Annotations

    /// Adds yellow highlight annotations for every search result on their respective pages.
    /// The current result gets an orange annotation on top.
    private func addAllSearchHighlights() {
        guard let document = pdfView.document else { return }
        removeAllSearchHighlights()

        for (index, selection) in searchResults.enumerated() {
            guard let page = selection.pages.first else { continue }
            let bounds = selection.bounds(for: page)
            guard isValidBounds(bounds) else { continue }

            let isCurrent = (index == currentSearchIndex)
            let color = isCurrent ? searchCurrentColor : searchAllColor

            let ann = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            ann.color = color
            // Tag the annotation so we can find it later
            ann.setValue(index, forAnnotationKey: PDFAnnotationKey(rawValue: "/SearchResultIndex"))
            page.addAnnotation(ann)
            searchHighlightAnnotations.append(ann)
            searchResultAnnotations[index] = ann
        }
    }

    /// Updates only the color of the current vs previous result annotation.
    private func updateCurrentHighlightColor(previous: Int, current: Int) {
        guard let document = pdfView.document else { return }

        // Reset previous to yellow
        if previous >= 0, previous < searchResults.count,
           let ann = searchResultAnnotations[previous],
           let pg = ann.page {
            pg.removeAnnotation(ann)
            let sel = searchResults[previous]
            let bounds = sel.bounds(for: pg)
            guard isValidBounds(bounds) else { return }
            let newAnn = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            newAnn.color = searchAllColor
            pg.addAnnotation(newAnn)
            searchHighlightAnnotations.removeAll { $0 === ann }
            searchHighlightAnnotations.append(newAnn)
            searchResultAnnotations[previous] = newAnn
        }

        // Set current to orange
        if current >= 0, current < searchResults.count,
           let ann = searchResultAnnotations[current],
           let pg = ann.page {
            pg.removeAnnotation(ann)
            let sel = searchResults[current]
            let bounds = sel.bounds(for: pg)
            guard isValidBounds(bounds) else { return }
            let newAnn = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            newAnn.color = searchCurrentColor
            pg.addAnnotation(newAnn)
            searchHighlightAnnotations.removeAll { $0 === ann }
            searchHighlightAnnotations.append(newAnn)
            searchResultAnnotations[current] = newAnn
        }

        _ = document // suppress warning
    }

    /// Removes all search highlight annotations from every page.
    private func removeAllSearchHighlights() {
        for ann in searchHighlightAnnotations { ann.page?.removeAnnotation(ann) }
        searchHighlightAnnotations.removeAll()
        searchResultAnnotations.removeAll()
    }

    private func isValidBounds(_ b: CGRect) -> Bool {
        return !b.isEmpty && !b.isNull && b.width > 0 && b.height > 0 &&
               b.width < 5000 && b.height < 5000 &&
               !b.origin.x.isNaN && !b.origin.y.isNaN &&
               !b.size.width.isNaN && !b.size.height.isNaN
    }

    // MARK: - Navigation

    private func navigateToResult(at index: Int) {
        guard index >= 0, index < searchResults.count else { return }
        let sel = searchResults[index]
        // Don't set currentSelection — we use annotations instead
        pdfView.go(to: sel)
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
        searchResults = []
        currentSearchIndex = -1
        pdfView.currentSelection = nil
        notifySearchResults()
    }

    private func notifySearchResults() {
        methodChannel.invokeMethod("onSearchResultsChanged", arguments: [
            "current": currentSearchIndex + 1,
            "total": searchResults.count
        ])
    }

    // MARK: - Arabic Search Core

    /// Per-page manual Arabic search.
    ///
    /// Why we can't use PDFKit.findString() for Arabic:
    ///   PDFKit compares strings raw. Arabic PDFs store text in various forms:
    ///   A) Unicode logical order  "بسم"   (modern PDFs)
    ///   B) Presentation forms     "ﺑﺴﻢ"   (older/shaped PDFs, logical order)
    ///   C) Presentation forms reversed "ﻢﺴﺑ" (most Quran PDFs — visual order)
    ///   D) Unicode reversed       "مسب"   (some Quran PDFs)
    ///
    /// Solution: normalize both query and page text to canonical form,
    /// search in normalized space, map match positions back to original text,
    /// then use PDFPage.selection(for:) to get the PDFSelection.
    ///
    /// Key fix for "wrong position": only search with reversed variants on pages
    /// where the forward variant finds nothing. This prevents a reversed-variant
    /// match from producing a conflicting position alongside a forward match
    /// on the same page, which caused the wrong-position highlight.
    private func arabicSearch(query: String, in document: PDFDocument) -> [PDFSelection] {
        let queryNorm = ArabicNormalizer.normalize(query)
        guard !queryNorm.isEmpty else { return [] }

        let queryRev      = String(queryNorm.reversed())
        let queryRevWords = ArabicNormalizer.reverseWords(queryNorm)

        var results: [PDFSelection] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            // Use page.string directly — this is exactly what PDFPage.selection(for:) indexes into.
            // ObjCExceptionHandler wraps it to avoid crashes on image-only pages.
            guard let rawText = ObjCExceptionHandler.safelyGetPageString(page),
                  !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // Build normalization map for this page
            let mapping = ArabicNormalizer.buildNormalizationMap(for: rawText)
            let pageNorm = mapping.normalizedText

            // Step 1: Try forward (logical-order) search first
            let forwardMatches = findAllOccurrences(of: queryNorm, in: pageNorm)
            var pageResults: [PDFSelection] = []

            for normRange in forwardMatches {
                if let sel = makeSelection(page: page, normRange: normRange, mapping: mapping, rawText: rawText) {
                    pageResults.append(sel)
                }
            }

            if !pageResults.isEmpty {
                // Forward search found results — use them, don't try reversed variants
                // This is the fix for "wrong position": reversed variants can produce
                // conflicting/duplicate results that map to wrong positions
                results.append(contentsOf: pageResults)
                continue
            }

            // Step 2: No forward matches — try reversed variants (visual-order PDFs)
            var reversedMatches: [NSRange] = []

            let revMatches = findAllOccurrences(of: queryRev, in: pageNorm)
            reversedMatches.append(contentsOf: revMatches)

            if queryRevWords != queryRev && queryRevWords != queryNorm {
                let rwMatches = findAllOccurrences(of: queryRevWords, in: pageNorm)
                reversedMatches.append(contentsOf: rwMatches)
            }

            for normRange in reversedMatches {
                if let sel = makeSelection(page: page, normRange: normRange, mapping: mapping, rawText: rawText) {
                    pageResults.append(sel)
                }
            }

            results.append(contentsOf: pageResults)
        }

        return deduplicateResults(results, in: document)
    }

    /// Creates a PDFSelection from a match range in normalized text.
    private func makeSelection(page: PDFPage, normRange: NSRange,
                                mapping: ArabicNormalizer.NormalizationMap,
                                rawText: String) -> PDFSelection? {
        guard let origRange = ArabicNormalizer.mapNormalizedRange(normRange, mapping: mapping) else { return nil }

        // Convert scalar-index NSRange to UTF-16 NSRange for PDFPage.selection(for:)
        let utf16Range = scalarRangeToUTF16Range(origRange, in: rawText)
        guard utf16Range.length > 0 else { return nil }

        let selection = page.selection(for: utf16Range)
        guard let sel = selection else { return nil }
        let bounds = sel.bounds(for: page)
        guard isValidBounds(bounds) else { return nil }
        return sel
    }

    /// Converts an NSRange in terms of Unicode scalar indices to UTF-16 code unit indices.
    /// For Arabic (all BMP), scalars == UTF-16 units, but this is correct in general.
    private func scalarRangeToUTF16Range(_ scalarRange: NSRange, in text: String) -> NSRange {
        let scalars = Array(text.unicodeScalars)
        guard scalarRange.location < scalars.count else { return NSRange(location: NSNotFound, length: 0) }
        let end = min(scalarRange.location + scalarRange.length, scalars.count)

        // Build UTF-16 offset for start
        var utf16Start = 0
        for i in 0..<scalarRange.location {
            utf16Start += scalars[i].utf16.count
        }

        // Build UTF-16 length
        var utf16Len = 0
        for i in scalarRange.location..<end {
            utf16Len += scalars[i].utf16.count
        }

        return NSRange(location: utf16Start, length: utf16Len)
    }

    private func findAllOccurrences(of pattern: String, in text: String) -> [NSRange] {
        guard !pattern.isEmpty, !text.isEmpty else { return [] }
        var ranges: [NSRange] = []
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while search.location < ns.length {
            let found = ns.range(of: pattern, options: [.caseInsensitive], range: search)
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
        self.init(red: CGFloat((argb >> 16) & 0xFF) / 255.0,
                  green: CGFloat((argb >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(argb & 0xFF) / 255.0,
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
        let str = NSAttributedString(string: label, attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black])
        str.draw(at: CGPoint(x: (b.width - str.size().width) / 2, y: b.height - 20))
        context.restoreGState(); UIGraphicsPopContext()
    }
}

// MARK: - ArabicNormalizer

/// Normalizes Arabic text to a canonical form for reliable search comparison.
///
/// Handles all common Arabic PDF encoding types:
///   - Unicode logical order (modern PDFs)
///   - Presentation Forms B (FE70–FEFF), logical or visual order
///   - Quran-specific extended characters (U+06CC Farsi Yeh, U+06C1 Heh Goal, etc.)
///   - Diacritics / tashkeel / Quranic annotation marks
///   - Lam-alef ligatures
struct ArabicNormalizer {

    // MARK: - Arabic Scalar Detection

    static func isArabicScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x0600 && v <= 0x06FF) ||
               (v >= 0x0750 && v <= 0x077F) ||
               (v >= 0x08A0 && v <= 0x08FF) ||
               (v >= 0xFB50 && v <= 0xFDFF) ||
               (v >= 0xFE70 && v <= 0xFEFF)
    }
    static func isArabic(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return isArabicScalar(s)
    }

    // MARK: - Normalization Map

    /// Holds both the normalized string and the scalar-index mapping back to the original.
    struct NormalizationMap {
        let normalizedText: String
        /// normToOrig[i] = scalar index in original string for normalized char i
        let normToOrig: [Int]
    }

    // MARK: - Character Tables

    /// Presentation Forms B (FE70–FEFF) → base Unicode
    static let presentationToBase: [UInt32: UInt32] = {
        let entries: [(UInt32, [UInt32])] = [
            (0x0627, [0xFE8D, 0xFE8E]),
            (0x0628, [0xFE8F, 0xFE90, 0xFE91, 0xFE92]),
            (0x062A, [0xFE95, 0xFE96, 0xFE97, 0xFE98]),
            (0x062B, [0xFE99, 0xFE9A, 0xFE9B, 0xFE9C]),
            (0x062C, [0xFE9D, 0xFE9E, 0xFE9F, 0xFEA0]),
            (0x062D, [0xFEA1, 0xFEA2, 0xFEA3, 0xFEA4]),
            (0x062E, [0xFEA5, 0xFEA6, 0xFEA7, 0xFEA8]),
            (0x062F, [0xFEA9, 0xFEAA]),
            (0x0630, [0xFEAB, 0xFEAC]),
            (0x0631, [0xFEAD, 0xFEAE]),
            (0x0632, [0xFEAF, 0xFEB0]),
            (0x0633, [0xFEB1, 0xFEB2, 0xFEB3, 0xFEB4]),
            (0x0634, [0xFEB5, 0xFEB6, 0xFEB7, 0xFEB8]),
            (0x0635, [0xFEB9, 0xFEBA, 0xFEBB, 0xFEBC]),
            (0x0636, [0xFEBD, 0xFEBE, 0xFEBF, 0xFEC0]),
            (0x0637, [0xFEC1, 0xFEC2, 0xFEC3, 0xFEC4]),
            (0x0638, [0xFEC5, 0xFEC6, 0xFEC7, 0xFEC8]),
            (0x0639, [0xFEC9, 0xFECA, 0xFECB, 0xFECC]),
            (0x063A, [0xFECD, 0xFECE, 0xFECF, 0xFED0]),
            (0x0641, [0xFED1, 0xFED2, 0xFED3, 0xFED4]),
            (0x0642, [0xFED5, 0xFED6, 0xFED7, 0xFED8]),
            (0x0643, [0xFED9, 0xFEDA, 0xFEDB, 0xFEDC]),
            (0x0644, [0xFEDD, 0xFEDE, 0xFEDF, 0xFEE0]),
            (0x0645, [0xFEE1, 0xFEE2, 0xFEE3, 0xFEE4]),
            (0x0646, [0xFEE5, 0xFEE6, 0xFEE7, 0xFEE8]),
            (0x0647, [0xFEE9, 0xFEEA, 0xFEEB, 0xFEEC]),
            (0x0648, [0xFEED, 0xFEEE]),
            (0x064A, [0xFEF1, 0xFEF2, 0xFEF3, 0xFEF4]),
            (0x0626, [0xFE89, 0xFE8A, 0xFE8B, 0xFE8C]),
            (0x0622, [0xFE81, 0xFE82]),
            (0x0623, [0xFE83, 0xFE84]),
            (0x0625, [0xFE87, 0xFE88]),
            (0x0624, [0xFE85, 0xFE86]),
            (0x0649, [0xFEEF, 0xFEF0]),
            (0x0629, [0xFE93, 0xFE94]),
        ]
        var map = [UInt32: UInt32]()
        for (base, forms) in entries { for f in forms { map[f] = base } }
        return map
    }()

    /// Lam-alef ligatures — one codepoint expands to two characters
    static let lamAlefLigatures: [UInt32: (UInt32, UInt32)] = [
        0xFEF5: (0x0644, 0x0622), 0xFEF6: (0x0644, 0x0622),  // lam + alef madda
        0xFEF7: (0x0644, 0x0623), 0xFEF8: (0x0644, 0x0623),  // lam + alef hamza above
        0xFEF9: (0x0644, 0x0625), 0xFEFA: (0x0644, 0x0625),  // lam + alef hamza below
        0xFEFB: (0x0644, 0x0627), 0xFEFC: (0x0644, 0x0627),  // lam + bare alef
    ]

    /// Diacritic and non-letter codepoints to strip
    static let stripSet: Set<UInt32> = {
        var s = Set<UInt32>()
        for v in UInt32(0x064B)...UInt32(0x065F) { s.insert(v) } // harakat
        s.insert(0x0670) // superscript alef
        for v in UInt32(0x06D6)...UInt32(0x06DC) { s.insert(v) } // Quranic
        for v in UInt32(0x06DF)...UInt32(0x06E4) { s.insert(v) }
        s.insert(0x06E7); s.insert(0x06E8)
        for v in UInt32(0x06EA)...UInt32(0x06ED) { s.insert(v) }
        for v in UInt32(0x0610)...UInt32(0x061A) { s.insert(v) } // extended marks
        s.insert(0x0640) // tatweel/kashida
        s.insert(0x200C) // zero-width non-joiner
        s.insert(0x200D) // zero-width joiner
        s.insert(0x200F) // right-to-left mark
        s.insert(0x200E) // left-to-right mark
        s.insert(0xFEFF) // BOM / zero-width no-break space
        return s
    }()

    // MARK: - Build Normalization Map

    /// Normalizes `text` and builds the scalar-index mapping simultaneously.
    /// This is the single source of truth — both the normalized string and the
    /// index map are produced in one pass, so they are guaranteed to be consistent.
    static func buildNormalizationMap(for text: String) -> NormalizationMap {
        var normChars  = [Unicode.Scalar]()
        var normToOrig = [Int]()
        normChars.reserveCapacity(text.unicodeScalars.count)
        normToOrig.reserveCapacity(text.unicodeScalars.count)

        let scalars = Array(text.unicodeScalars)

        for (i, scalar) in scalars.enumerated() {
            let v = scalar.value

            // 1. Strip diacritics, tatweel, invisible marks
            if stripSet.contains(v) { continue }

            // 2. Expand lam-alef ligatures (1 orig → 2 norm chars)
            if let (lam, alef) = lamAlefLigatures[v] {
                if let ls = Unicode.Scalar(lam), let as_ = Unicode.Scalar(alef) {
                    normChars.append(ls); normToOrig.append(i)
                    normChars.append(as_); normToOrig.append(i)
                }
                continue
            }

            // 3. Unshape presentation forms → base Unicode
            if let base = presentationToBase[v], let bs = Unicode.Scalar(base) {
                normChars.append(bs); normToOrig.append(i)
                continue
            }

            // 4. Keep as-is (will be unified in step 5)
            normChars.append(scalar); normToOrig.append(i)
        }

        // 5. Build normalized string and apply letter unification
        var normStr = String(String.UnicodeScalarView(normChars))

        // Apply unification replacements and rebuild the map to stay consistent.
        // We do this as a second pass using a replacement table, updating normToOrig in sync.
        normStr = applyUnification(normStr, normToOrig: &normToOrig)

        return NormalizationMap(normalizedText: normStr, normToOrig: normToOrig)
    }

    /// Applies letter unification (alef variants, teh marbuta, etc.) to an already-unshaped string.
    /// Updates normToOrig in sync (unification is 1:1 so indices don't change).
    private static func applyUnification(_ text: String, normToOrig: inout [Int]) -> String {
        // All replacements are 1:1 (single char → single char), so normToOrig stays valid
        return text
            .replacingOccurrences(of: "\u{0622}", with: "\u{0627}") // آ → ا
            .replacingOccurrences(of: "\u{0623}", with: "\u{0627}") // أ → ا
            .replacingOccurrences(of: "\u{0625}", with: "\u{0627}") // إ → ا
            .replacingOccurrences(of: "\u{0671}", with: "\u{0627}") // ٱ → ا
            .replacingOccurrences(of: "\u{0672}", with: "\u{0627}")
            .replacingOccurrences(of: "\u{0673}", with: "\u{0627}")
            .replacingOccurrences(of: "\u{0629}", with: "\u{0647}") // ة → ه
            .replacingOccurrences(of: "\u{06C1}", with: "\u{0647}") // ہ → ه (Heh Goal, used in some Quran fonts)
            .replacingOccurrences(of: "\u{0649}", with: "\u{064A}") // ى → ي
            .replacingOccurrences(of: "\u{06CC}", with: "\u{064A}") // ی → ي (Farsi Yeh, critical for many Quran PDFs)
            .replacingOccurrences(of: "\u{06D2}", with: "\u{064A}") // ے → ي
            .replacingOccurrences(of: "\u{0624}", with: "\u{0648}") // ؤ → و
            .replacingOccurrences(of: "\u{0626}", with: "\u{064A}") // ئ → ي
    }

    // MARK: - Normalize (convenience, no map)

    static func normalize(_ text: String) -> String {
        var dummy = [Int]()
        return applyUnification(
            buildNormalizationMap(for: text).normalizedText,
            normToOrig: &dummy
        )
        // Simpler: just use the map result
    }

    // MARK: - Reverse Words

    static func reverseWords(_ text: String) -> String {
        text.components(separatedBy: .whitespaces).reversed().joined(separator: " ")
    }

    // MARK: - Map Normalized Range → Original Range

    /// Maps a match range in normalized text back to a scalar-index range in the original text.
    /// Uses the NormalizationMap produced by buildNormalizationMap().
    static func mapNormalizedRange(_ normRange: NSRange, mapping: NormalizationMap) -> NSRange? {
        let normToOrig = mapping.normToOrig
        guard normRange.location >= 0,
              normRange.length > 0,
              normRange.location < normToOrig.count,
              normRange.location + normRange.length <= normToOrig.count else { return nil }

        let origStart = normToOrig[normRange.location]
        let normEnd   = normRange.location + normRange.length - 1
        guard normEnd < normToOrig.count else { return nil }
        let origEnd   = normToOrig[normEnd]

        // origEnd may equal origStart (lam-alef: both norm chars share 1 orig scalar)
        let length = origEnd - origStart + 1
        guard length > 0 else { return nil }
        return NSRange(location: origStart, length: length)
    }
}

// MARK: - Legacy ArabicShaper stub (keeps existing code that calls it from compiling)

struct ArabicShaper {
    static func isArabic(_ c: Character) -> Bool { ArabicNormalizer.isArabic(c) }
    static func normalizeString(_ text: String) -> String { ArabicNormalizer.normalize(text) }
    static func buildRegex(for query: String) -> String { return query }
    static func buildStandardRegex(for query: String) -> String { return query }
}