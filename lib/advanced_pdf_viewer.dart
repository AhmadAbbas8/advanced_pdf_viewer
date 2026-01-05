import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import 'advanced_pdf_viewer_platform_interface.dart';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';

class AdvancedPdfViewerPlugin {
  Future<String?> getPlatformVersion() {
    return AdvancedPdfViewerPlatform.instance.getPlatformVersion();
  }
}

class AdvancedPdfViewerController {
  MethodChannel? _channel;

  void _setChannel(MethodChannel channel) {
    _channel = channel;
  }

  /// Sets the current drawing tool.
  /// Tools: 'none', 'draw', 'highlight', 'underline'
  Future<void> setDrawingMode(String tool) async {
    await _channel?.invokeMethod('setDrawingMode', {'tool': tool});
  }

  /// Clears all annotations from the PDF.
  Future<void> clearAnnotations() async {
    await _channel?.invokeMethod('clearAnnotations');
  }

  /// Saves the PDF with annotations and returns the data as a List of ints.
  Future<List<int>?> savePdf() async {
    final Uint8List? data = await _channel?.invokeMethod<Uint8List>('savePdf');
    return data?.toList();
  }
}

class AdvancedPdfViewer extends StatefulWidget {
  final String? url;
  final Uint8List? bytes;
  final AdvancedPdfViewerController? controller;
  final Widget? loadingWidget;

  const AdvancedPdfViewer.network(
    this.url, {
    super.key,
    this.controller,
    this.loadingWidget,
  }) : bytes = null;

  const AdvancedPdfViewer.bytes(
    this.bytes, {
    super.key,
    this.controller,
    this.loadingWidget,
  }) : url = null;

  @override
  State<AdvancedPdfViewer> createState() => _AdvancedPdfViewerState();
}

class _AdvancedPdfViewerState extends State<AdvancedPdfViewer> {
  String? _localPath;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _preparePdf();
  }

  Future<void> _preparePdf() async {
    try {
      final tempDir = await getTemporaryDirectory();
      File file;

      if (widget.url != null) {
        final hash = md5.convert(utf8.encode(widget.url!)).toString();
        file = File('${tempDir.path}/$hash.pdf');
        if (!await file.exists()) {
          final response = await http.get(Uri.parse(widget.url!));
          if (response.statusCode == 200) {
            await file.writeAsBytes(response.bodyBytes);
          } else {
            throw Exception('Failed to download PDF: ${response.statusCode}');
          }
        }
      } else if (widget.bytes != null) {
        final hash = md5.convert(widget.bytes!).toString();
        file = File('${tempDir.path}/$hash.pdf');
        if (!await file.exists()) {
          await file.writeAsBytes(widget.bytes!);
        }
      } else {
        throw Exception('No PDF source provided');
      }

      if (mounted) {
        setState(() {
          _localPath = file.path;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return widget.loadingWidget ??
          const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }

    const String viewType = 'advanced_pdf_viewer_view';
    final Map<String, dynamic> creationParams = <String, dynamic>{
      'path': _localPath,
    };

    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidView(
        viewType: viewType,
        onPlatformViewCreated: _onPlatformViewCreated,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: viewType,
        onPlatformViewCreated: _onPlatformViewCreated,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }

    return Text('$defaultTargetPlatform is not supported by AdvancedPdfViewer');
  }

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('advanced_pdf_viewer_$id');
    widget.controller?._setChannel(channel);
  }
}
