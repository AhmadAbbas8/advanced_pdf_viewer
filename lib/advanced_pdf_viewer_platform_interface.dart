import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'advanced_pdf_viewer_method_channel.dart';

abstract class AdvancedPdfViewerPlatform extends PlatformInterface {
  /// Constructs a AdvancedPdfViewerPlatform.
  AdvancedPdfViewerPlatform() : super(token: _token);

  static final Object _token = Object();

  static AdvancedPdfViewerPlatform _instance = MethodChannelAdvancedPdfViewer();

  /// The default instance of [AdvancedPdfViewerPlatform] to use.
  ///
  /// Defaults to [MethodChannelAdvancedPdfViewer].
  static AdvancedPdfViewerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AdvancedPdfViewerPlatform] when
  /// they register themselves.
  static set instance(AdvancedPdfViewerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<void> setDrawingMode(String tool) {
    throw UnimplementedError('setDrawingMode() has not been implemented.');
  }

  Future<void> clearAnnotations() {
    throw UnimplementedError('clearAnnotations() has not been implemented.');
  }

  Future<List<int>?> savePdf() {
    throw UnimplementedError('savePdf() has not been implemented.');
  }
}
