# Changelog

## 0.11.0

- **Enhanced Search**: Significantly improved Arabic text search accuracy with advanced normalization, character form handling (ligatures, presentation forms), and sophisticated regex patterns.
- **Highlights & Annotations**: Refactored Android text annotations to use an overlay system for better control over positioning and resizing.
- **Annotation Precision**: Fixed text annotation commit positions to ensure saved coordinates precisely match the overlay position.

## 0.10.0

- **iOS Crash Fix**: Fixed critical iOS crash when highlighting or underlining image-based PDFs (scanned documents without text layers).
- **Exception Handling**: Implemented Objective-C exception handlers to safely catch and handle PDFKit exceptions that Swift cannot catch.
- **Stability**: Added proactive text content detection before attempting selection operations to prevent crashes at the Objective-C level.

## 0.9.0

- **Color Selection**: Added dynamic color selection for all drawing tools (Draw, Highlight, Underline, Text).
- **Interaction**: Support for double-clicking/tapping an active tool button to open the color selection dialog.
- **Color Picker**: New bottom sheet dialog with 6 default colors and a custom color palette (+ button).
- **Text Color Support**: Added `textColor` to `PdfViewerConfig` to customize the default color for text annotations.
- **Configuration**: New configuration options `enableColorSelection` and tool-specific default color lists.
- **Fix**: Resolved UI sync issue where the color picker did not reflect the currently active color.

## 0.8.0

- **Text Search**: Full-text search support on Android (PDFBox) and iOS (PDFKit) with native highlighting and navigation.
- **Search UI**: Integrated search bar in the toolbar with a loading indicator, real-time result counting, and auto-focus.
- **Search Navigation**: Smooth navigation between search results with "Next" and "Previous" actions.
- **Localization**: Full internationalization for the entire toolbar (Pan, Draw, Highlight, Underline, Search, etc.) in English and Arabic.
- **Android Engine**: Restructured native binding to resolve compilation errors and optimized memory usage for text extraction.
- **UI/UX Polish**: Improved toolbar adaptive styling and resolved multiple lint issues.

## 0.7.0

- **Bookmarks System**: Complete bookmark management (save, view, delete) with persistent storage implementation.
- **Internationalization (i18n)**: Full support for English and Arabic languages, including automatic RTL layout and translated UI strings.
- **Smart SnackBar**: New overlay-based toast notification system with custom "Slide Up" animations and guaranteed dismissal.
- **Page Tracking**: Added `onPageChanged` callback and `getCurrentPage()` method for real-time page position tracking.
- **UI Enhancements**: Improved dialogs and loading indicators with adaptive designs for Android and iOS.

- **Android Crash Fix**: Fixed critical `OutOfMemoryError` and crashes when interacting with or saving large PDF files (>10MB).
- **Memory Optimization**: Implemented strict single-document memory strategy and aggressive resource cleanup for Android saves.
- **Performance**: Optimized text snapping and drawing on Android using background serialization to prevent UI lag.

## 0.6.1

- **Page Counter**: Added `enablePageNumber` to `PdfViewerConfig` to show page numbers on Android (below page) and iOS (on page footer).
- **iOS Security**: Disabled text selection actions (Copy, Paste, Look Up, Share, etc.) for better content security.
- **iOS UI**: Fixed reversed page numbering on iOS.

## 0.6.0

- **Fix Android Bug**: Fix Crashed on Android when render pdf

## 0.5.1

- **iOS Undo/Redo Fix**: Fixed undo/redo functionality on iOS for all annotation types (drawing, highlights, underlines) by implementing proper annotation reference management with page indices.
- **iOS Initial Zoom**: Fixed initial zoom level on iOS to properly set to 0.5 (50%) by disabling auto-scaling and setting zoom after document loads.

## 0.5.0

- **Secure PDF Loading**: Implemented `useCache: false` to support secure PDF loading where the file is downloaded to a temporary location and immediately deleted after opening, ensuring no persistent copy remains on the device.

## 0.4.0

- **Jump to Page**: Added `jumpToPage` method to `AdvancedPdfViewerController` for programmatic navigation to specific pages.
- **Save PDF**: Added `savePdf` method to `AdvancedPdfViewerController` for saving annotated PDFs to local storage.
- **Highlight**: Added `highlightText` method to `AdvancedPdfViewerController` for highlighting text in the PDF.
- **Underline**: Added `underlineText` method to `AdvancedPdfViewerController` for underlining text in the PDF.
- **Text Note**: Added `addTextAnnotation` method to `AdvancedPdfViewerController` for adding text notes to the PDF.
- **Draw**: Added `drawOnPage` method to `AdvancedPdfViewerController` for drawing on the PDF.

## 0.3.0

- **Performance Optimization**: PDF saving now runs on background threads (Android & iOS) to prevent UI blocking.
- **Adaptive UI**: Toolbar icons are now platform-adaptive, providing a native look and feel on both iOS and Android.
- **Lifecycle Management**: Added `dispose()` method to `AdvancedPdfViewerController` for proper resource cleanup.
- **iOS Stability**: Fixed `MissingPluginException` for `setScrollLocked` and improved scroll-lock behavior on iOS.

## 0.1.0

- **Initial Release** with robust PDF viewing and annotation features.
- **Arabic Support**: Full Arabic character joining (shaping) and BiDi reordering for RTL text.
- **Advanced Annotations**: Support for Drawing (pen), Text Notes, Highlights, and Underlines.
- **Snap-to-Text**: Highlighting and Underlining automatically snaps to the nearest text line/word.
- **High Performance**: Virtualized page rendering (RecyclerView on Android) for smooth browsing of large PDF documents.
- **Customization**: Flexible `PdfViewerConfig` for colors, toolbar options, and full-screen modes.
- **Persistence**: Save annotated PDFs to local storage with font embedding for mixed language (Arabic/Latin) support.
