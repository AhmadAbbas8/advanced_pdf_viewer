import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';

enum PdfAnnotationTool { none, draw, highlight, underline, text }

class AdvancedPdfViewerController {
  MethodChannel? _channel;
  Function(double x, double y, int pageIndex)? _onPdfTapped;
  Function(int page)? _onPageChanged;
  int _currentPage = 0;

  /// Sets the method channel and initializes the tap handler.
  void setChannel(MethodChannel channel) {
    _channel = channel;
    _channel?.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onPdfTapped') {
        final Map<dynamic, dynamic> args =
            call.arguments as Map<dynamic, dynamic>;
        final double x = (args['x'] as num).toDouble();
        final double y = (args['y'] as num).toDouble();
        final int pageIndex = (args['pageIndex'] as int?) ?? 0;
        _onPdfTapped?.call(x, y, pageIndex);
      } else if (call.method == 'onPageChanged') {
        final int page = (call.arguments as int?) ?? 0;
        _handlePageChanged(page);
      }
    });
  }

  /// Sets a callback for when the PDF is tapped (used for text input).
  void setOnPdfTapped(Function(double x, double y, int pageIndex) callback) {
    _onPdfTapped = callback;
  }

  /// Sets a callback for when the current page changes.
  void setOnPageChanged(Function(int page) callback) {
    _onPageChanged = callback;
  }

  /// Handles page change events from the native platform.
  void _handlePageChanged(int page) {
    _currentPage = page;
    _onPageChanged?.call(page);
  }

  /// Returns the current page index (0-indexed).
  int getCurrentPage() {
    return _currentPage;
  }

  /// Sets the current drawing tool and configuration (colors, etc).
  Future<void> setDrawingMode(PdfAnnotationTool tool, {Color? color}) async {
    await _channel?.invokeMethod('setDrawingMode', {
      'tool': tool.name,
      'color': color?.value,
    });
  }

  /// Clears all annotations from the PDF.
  Future<void> clearAnnotations() async {
    await _channel?.invokeMethod('clearAnnotations');
  }

  /// Undoes the last annotation action.
  Future<void> undo() async {
    await _channel?.invokeMethod('undo');
  }

  /// Redoes the last undone annotation action.
  Future<void> redo() async {
    await _channel?.invokeMethod('redo');
  }

  /// Explicitly locks or unlocks scrolling on the native view.
  Future<void> setScrollLocked(bool locked) async {
    await _channel?.invokeMethod('setScrollLocked', {'locked': locked});
  }

  /// Saves the PDF with annotations and returns the data as a List of ints.
  Future<List<int>?> savePdf() async {
    final Uint8List? data = await _channel?.invokeMethod<Uint8List>('savePdf');
    return data?.toList();
  }

  /// Adds text annotation at a specific location.
  Future<void> addTextAnnotation(
    String text,
    double x,
    double y,
    int pageIndex, {
    Color? color,
  }) async {
    await _channel?.invokeMethod('addTextAnnotation', {
      'text': text,
      'x': x,
      'y': y,
      'pageIndex': pageIndex,
      'color': color?.value,
    });
  }

  /// Jumps to a specific page index (0-indexed).
  Future<void> jumpToPage(int page) async {
    await _channel?.invokeMethod('jumpToPage', {'page': page});
  }

  /// Returns the total number of pages in the current PDF.
  Future<int> getTotalPages() async {
    final int? count = await _channel?.invokeMethod<int>('getTotalPages');
    return count ?? 0;
  }

  /// Updates the native configuration (e.g. colors) without changing the tool.
  Future<void> updateConfig({
    Color? drawColor,
    Color? highlightColor,
    Color? underlineColor,
    bool? enablePageNumber,
  }) async {
    await _channel?.invokeMethod('updateConfig', {
      'drawColor': drawColor?.value,
      'highlightColor': highlightColor?.value,
      'underlineColor': underlineColor?.value,
      'enablePageNumber': enablePageNumber,
    });
  }

  /// Zooms in by a fixed increment.
  Future<void> zoomIn() async {
    await _channel?.invokeMethod('zoomIn');
  }

  /// Zooms out by a fixed increment.
  Future<void> zoomOut() async {
    await _channel?.invokeMethod('zoomOut');
  }

  /// Sets the zoom level to a specific scale.
  Future<void> setZoom(double scale) async {
    await _channel?.invokeMethod('setZoom', {'scale': scale});
  }

  /// Requests the current page from the native platform.
  Future<int> requestCurrentPage() async {
    final int? page = await _channel?.invokeMethod<int>('getCurrentPage');
    if (page != null) {
      _currentPage = page;
    }
    return _currentPage;
  }

  /// Disposes of the controller and its resources.
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _onPdfTapped = null;
    _onPageChanged = null;
  }
}
