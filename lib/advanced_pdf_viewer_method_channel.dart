import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'advanced_pdf_viewer_platform_interface.dart';

/// An implementation of [AdvancedPdfViewerPlatform] that uses method channels.
class MethodChannelAdvancedPdfViewer extends AdvancedPdfViewerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('advanced_pdf_viewer');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<void> setDrawingMode(String tool) async {
    await methodChannel.invokeMethod<void>('setDrawingMode', {'tool': tool});
  }

  @override
  Future<void> clearAnnotations() async {
    await methodChannel.invokeMethod<void>('clearAnnotations');
  }

  @override
  Future<List<int>?> savePdf() async {
    final pdfData = await methodChannel.invokeMethod<Uint8List>('savePdf');
    return pdfData;
  }

  @override
  Future<void> addTextAnnotation(String text, double x, double y) async {
    await methodChannel.invokeMethod('addTextAnnotation', {
      'text': text,
      'x': x,
      'y': y,
    });
  }

  @override
  Future<void> jumpToPage(int page) async {
    await methodChannel.invokeMethod('jumpToPage', {'page': page});
  }

  @override
  Future<int> getTotalPages() async {
    final int? count = await methodChannel.invokeMethod<int>('getTotalPages');
    return count ?? 0;
  }
}
