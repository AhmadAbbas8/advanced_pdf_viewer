# Changelog

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
