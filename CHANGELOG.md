# Changelog

## 0.6.2
* **Android Crash Fix**: Fixed critical `OutOfMemoryError` and crashes when interacting with or saving large PDF files (>10MB).
* **Memory Optimization**: Implemented strict single-document memory strategy and aggressive resource cleanup for Android saves.
* **Performance**: Optimized text snapping and drawing on Android using background serialization to prevent UI lag.

## 0.6.1
* **Page Counter**: Added `enablePageNumber` to `PdfViewerConfig` to show page numbers on Android (below page) and iOS (on page footer).
* **iOS Security**: Disabled text selection actions (Copy, Paste, Look Up, Share, etc.) for better content security.
* **iOS UI**: Fixed reversed page numbering on iOS.

## 0.6.0

* **Fix Android Bug**: Fix Crashed on Android when render pdf
## 0.5.1

* **iOS Undo/Redo Fix**: Fixed undo/redo functionality on iOS for all annotation types (drawing, highlights, underlines) by implementing proper annotation reference management with page indices.
* **iOS Initial Zoom**: Fixed initial zoom level on iOS to properly set to 0.5 (50%) by disabling auto-scaling and setting zoom after document loads.

## 0.5.0

* **Secure PDF Loading**: Implemented `useCache: false` to support secure PDF loading where the file is downloaded to a temporary location and immediately deleted after opening, ensuring no persistent copy remains on the device.


## 0.4.0

* **Jump to Page**: Added `jumpToPage` method to `AdvancedPdfViewerController` for programmatic navigation to specific pages.
* **Save PDF**: Added `savePdf` method to `AdvancedPdfViewerController` for saving annotated PDFs to local storage. 
* **Highlight**: Added `highlightText` method to `AdvancedPdfViewerController` for highlighting text in the PDF.
* **Underline**: Added `underlineText` method to `AdvancedPdfViewerController` for underlining text in the PDF.
* **Text Note**: Added `addTextAnnotation` method to `AdvancedPdfViewerController` for adding text notes to the PDF.
* **Draw**: Added `drawOnPage` method to `AdvancedPdfViewerController` for drawing on the PDF.

## 0.3.0

* **Performance Optimization**: PDF saving now runs on background threads (Android & iOS) to prevent UI blocking.
* **Adaptive UI**: Toolbar icons are now platform-adaptive, providing a native look and feel on both iOS and Android.
* **Lifecycle Management**: Added `dispose()` method to `AdvancedPdfViewerController` for proper resource cleanup.
* **iOS Stability**: Fixed `MissingPluginException` for `setScrollLocked` and improved scroll-lock behavior on iOS.

## 0.1.0

* **Initial Release** with robust PDF viewing and annotation features.
* **Arabic Support**: Full Arabic character joining (shaping) and BiDi reordering for RTL text.
* **Advanced Annotations**: Support for Drawing (pen), Text Notes, Highlights, and Underlines.
* **Snap-to-Text**: Highlighting and Underlining automatically snaps to the nearest text line/word.
* **High Performance**: Virtualized page rendering (RecyclerView on Android) for smooth browsing of large PDF documents.
* **Customization**: Flexible `PdfViewerConfig` for colors, toolbar options, and full-screen modes.
* **Persistence**: Save annotated PDFs to local storage with font embedding for mixed language (Arabic/Latin) support.
