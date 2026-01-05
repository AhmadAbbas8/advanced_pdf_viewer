import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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

  const PdfViewerConfig({
    this.showDrawButton = true,
    this.showHighlightButton = true,
    this.showUnderlineButton = true,
    this.showTextButton = true,
    this.showClearButton = true,
    this.showUndoButton = true,
    this.showRedoButton = true,
    this.allowFullScreen = true,
    this.onFullScreenInit,
    this.toolbarColor,
    this.toolbarPadding = const EdgeInsets.symmetric(horizontal: 8.0),
    this.drawColor = Colors.red,
    this.highlightColor = const Color(0x80FFFF00), // Semi-transparent yellow
    this.underlineColor = Colors.blue,
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
    VoidCallback? onFullScreenInit,
    Color? toolbarColor,
    EdgeInsetsGeometry? toolbarPadding,
    Color? drawColor,
    Color? highlightColor,
    Color? underlineColor,
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
      onFullScreenInit: onFullScreenInit ?? this.onFullScreenInit,
      toolbarColor: toolbarColor ?? this.toolbarColor,
      toolbarPadding: toolbarPadding ?? this.toolbarPadding,
      drawColor: drawColor ?? this.drawColor,
      highlightColor: highlightColor ?? this.highlightColor,
      underlineColor: underlineColor ?? this.underlineColor,
    );
  }
}
