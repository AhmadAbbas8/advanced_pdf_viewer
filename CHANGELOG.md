# Changelog

## 0.2.0

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
