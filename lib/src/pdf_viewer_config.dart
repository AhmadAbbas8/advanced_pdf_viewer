import 'package:flutter/material.dart';
import 'pdf_localizations.dart';

/// Position of the toolbar in the viewer.
enum PdfToolbarPosition {
  /// At the top of the viewer.
  top,

  /// At the bottom of the viewer.
  bottom,

  /// Floating at the top-center.
  floating,
}

/// Style configuration for the PDF toolbar.
class PdfToolbarStyle {
  /// Background color of the toolbar.
  final Color? backgroundColor;

  /// Elevation (shadow) of the toolbar.
  final double elevation;

  /// Corner radius of the toolbar.
  final BorderRadius? borderRadius;

  /// Color for active/selected tools.
  final Color? activeColor;

  /// Color for inactive tools.
  final Color? inactiveColor;

  /// Whether to use a blur effect (glassmorphism).
  final bool useBlur;

  /// Blur intensity (sigma) if [useBlur] is true.
  final double blurSigma;

  /// Optional gradient for the toolbar background.
  final Gradient? gradient;

  /// Margin around the toolbar.
  final EdgeInsetsGeometry? margin;

  /// Spacing between toolbar items.
  final double itemSpacing;

  const PdfToolbarStyle({
    this.backgroundColor,
    this.elevation = 8.0,
    this.borderRadius,
    this.activeColor,
    this.inactiveColor,
    this.useBlur = true,
    this.blurSigma = 15.0,
    this.gradient,
    this.margin,
    this.itemSpacing = 8.0,
  });

  PdfToolbarStyle copyWith({
    Color? backgroundColor,
    double? elevation,
    BorderRadius? borderRadius,
    Color? activeColor,
    Color? inactiveColor,
    bool? useBlur,
    double? blurSigma,
    Gradient? gradient,
    EdgeInsetsGeometry? margin,
    double? itemSpacing,
  }) {
    return PdfToolbarStyle(
      backgroundColor: backgroundColor ?? this.backgroundColor,
      elevation: elevation ?? this.elevation,
      borderRadius: borderRadius ?? this.borderRadius,
      activeColor: activeColor ?? this.activeColor,
      inactiveColor: inactiveColor ?? this.inactiveColor,
      useBlur: useBlur ?? this.useBlur,
      blurSigma: blurSigma ?? this.blurSigma,
      gradient: gradient ?? this.gradient,
      margin: margin ?? this.margin,
      itemSpacing: itemSpacing ?? this.itemSpacing,
    );
  }
}

class PdfViewerConfig {
  /// Whether to show the drawing tool button.
  final bool showDrawButton;

  /// Whether to show the highlight tool button.
  final bool showHighlightButton;

  /// Whether to show the underline tool button.
  final bool showUnderlineButton;

  /// Whether to show the text tool button.
  final bool showTextButton;

  /// Whether to show the clear annotations button.
  final bool showClearButton;

  /// Whether to show the undo button.
  final bool showUndoButton;

  /// Whether to show the redo button.
  final bool showRedoButton;

  /// Whether to allow full-screen mode.
  final bool allowFullScreen;

  /// Whether to show zoom in/out buttons.
  final bool showZoomButtons;

  /// Callback when full-screen is initialized.
  final VoidCallback? onFullScreenInit;

  /// Background color of the toolbar.
  final Color? toolbarColor;

  /// Padding for the toolbar.
  final EdgeInsetsGeometry toolbarPadding;

  /// Color for drawing annotations.
  final Color drawColor;

  /// Color for highlights.
  final Color highlightColor;

  /// Color for underlines.
  final Color underlineColor;

  /// Whether to show the page number identifier.
  final bool enablePageNumber;

  /// Whether to enable bookmarks feature.
  final bool enableBookmarks;

  /// Whether to show the bookmark button in toolbar.
  final bool showBookmarkButton;

  /// Whether to show the bookmarks list button in toolbar.
  final bool showBookmarksListButton;

  /// Optional custom storage key for bookmarks. If null, auto-generated.
  final String? bookmarkStorageKey;

  /// Callback when the current page changes.
  final Function(int page)? onPageChanged;

  /// Language for UI strings. If null, will try to use InheritedWidget or default to English.
  final PdfViewerLanguage? language;

  /// Position of the toolbar.
  final PdfToolbarPosition toolbarPosition;

  /// Style configuration for the toolbar.
  final PdfToolbarStyle toolbarStyle;

  /// Whether to show the settings button for the user to customize the toolbar.
  final bool showToolbarSettings;

  /// Whether to show the search button in the toolbar.
  final bool showSearchButton;
  

  const PdfViewerConfig({
    this.showDrawButton = true,
    this.showHighlightButton = true,
    this.showUnderlineButton = true,
    this.showTextButton = true,
    this.showClearButton = true,
    this.showUndoButton = true,
    this.showRedoButton = true,
    this.allowFullScreen = true,
    this.showZoomButtons = true,
    this.onFullScreenInit,
    this.toolbarColor,
    this.toolbarPadding = const EdgeInsets.symmetric(
      horizontal: 12.0,
      vertical: 6,
    ),
    this.drawColor = Colors.red,
    this.highlightColor = const Color(0x80FFFF00), // Semi-transparent yellow
    this.underlineColor = Colors.blue,
    this.enablePageNumber = false,
    this.enableBookmarks = false,
    this.showBookmarkButton = true,
    this.showBookmarksListButton = true,
    this.bookmarkStorageKey,
    this.onPageChanged,
    this.language,
    this.toolbarPosition = PdfToolbarPosition.top,
    this.toolbarStyle = const PdfToolbarStyle(),
    this.showToolbarSettings = true,
    this.showSearchButton = true,
  });

  PdfViewerConfig copyWith({
    bool? showDrawButton,
    bool? showHighlightButton,
    bool? showUnderlineButton,
    bool? showTextButton,
    bool? showClearButton,
    bool? showUndoButton,
    bool? showRedoButton,
    bool? allowFullScreen,
    bool? showZoomButtons,
    VoidCallback? onFullScreenInit,
    Color? toolbarColor,
    EdgeInsetsGeometry? toolbarPadding,
    Color? drawColor,
    Color? highlightColor,
    Color? underlineColor,
    bool? enablePageNumber,
    bool? enableBookmarks,
    bool? showBookmarkButton,
    bool? showBookmarksListButton,
    String? bookmarkStorageKey,
    Function(int page)? onPageChanged,
    PdfViewerLanguage? language,
    PdfToolbarPosition? toolbarPosition,
    PdfToolbarStyle? toolbarStyle,
    bool? showToolbarSettings,
    bool? showSearchButton,
  }) {
    return PdfViewerConfig(
      showDrawButton: showDrawButton ?? this.showDrawButton,
      showHighlightButton: showHighlightButton ?? this.showHighlightButton,
      showUnderlineButton: showUnderlineButton ?? this.showUnderlineButton,
      showTextButton: showTextButton ?? this.showTextButton,
      showClearButton: showClearButton ?? this.showClearButton,
      showUndoButton: showUndoButton ?? this.showUndoButton,
      showRedoButton: showRedoButton ?? this.showRedoButton,
      allowFullScreen: allowFullScreen ?? this.allowFullScreen,
      showZoomButtons: showZoomButtons ?? this.showZoomButtons,
      onFullScreenInit: onFullScreenInit ?? this.onFullScreenInit,
      toolbarColor: toolbarColor ?? this.toolbarColor,
      toolbarPadding: toolbarPadding ?? this.toolbarPadding,
      drawColor: drawColor ?? this.drawColor,
      highlightColor: highlightColor ?? this.highlightColor,
      underlineColor: underlineColor ?? this.underlineColor,
      enablePageNumber: enablePageNumber ?? this.enablePageNumber,
      enableBookmarks: enableBookmarks ?? this.enableBookmarks,
      showBookmarkButton: showBookmarkButton ?? this.showBookmarkButton,
      showBookmarksListButton:
          showBookmarksListButton ?? this.showBookmarksListButton,
      bookmarkStorageKey: bookmarkStorageKey ?? this.bookmarkStorageKey,
      onPageChanged: onPageChanged ?? this.onPageChanged,
      language: language ?? this.language,
      toolbarPosition: toolbarPosition ?? this.toolbarPosition,
      toolbarStyle: toolbarStyle ?? this.toolbarStyle,
      showToolbarSettings: showToolbarSettings ?? this.showToolbarSettings,
      showSearchButton: showSearchButton ?? this.showSearchButton,
    );
  }
}
