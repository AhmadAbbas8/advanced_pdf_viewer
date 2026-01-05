import 'package:flutter_test/flutter_test.dart';
import 'package:advanced_pdf_viewer/advanced_pdf_viewer.dart';
import 'package:advanced_pdf_viewer/advanced_pdf_viewer_platform_interface.dart';
import 'package:advanced_pdf_viewer/advanced_pdf_viewer_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockAdvancedPdfViewerPlatform
    with MockPlatformInterfaceMixin
    implements AdvancedPdfViewerPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<void> setDrawingMode(String tool) => Future.value();

  @override
  Future<void> clearAnnotations() => Future.value();

  @override
  Future<List<int>?> savePdf() => Future.value([1, 2, 3]);
}

void main() {
  final AdvancedPdfViewerPlatform initialPlatform =
      AdvancedPdfViewerPlatform.instance;

  test('$MethodChannelAdvancedPdfViewer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelAdvancedPdfViewer>());
  });

  test('getPlatformVersion', () async {
    AdvancedPdfViewerPlugin advancedPdfViewerPlugin = AdvancedPdfViewerPlugin();
    MockAdvancedPdfViewerPlatform fakePlatform =
        MockAdvancedPdfViewerPlatform();
    AdvancedPdfViewerPlatform.instance = fakePlatform;

    expect(await advancedPdfViewerPlugin.getPlatformVersion(), '42');
  });
}
