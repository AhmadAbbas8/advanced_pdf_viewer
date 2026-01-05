import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:advanced_pdf_viewer/advanced_pdf_viewer_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelAdvancedPdfViewer platform = MethodChannelAdvancedPdfViewer();
  const MethodChannel channel = MethodChannel('advanced_pdf_viewer');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        return '42';
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
