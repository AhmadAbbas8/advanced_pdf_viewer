import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import 'advanced_pdf_viewer_platform_interface.dart';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';

enum PdfAnnotationTool { none, draw, highlight, underline }

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
  Future<void> setDrawingMode(PdfAnnotationTool tool) async {
    await _channel?.invokeMethod('setDrawingMode', {'tool': tool.name});
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
  final bool showToolbar;

  const AdvancedPdfViewer.network(
    this.url, {
    super.key,
    this.controller,
    this.loadingWidget,
    this.showToolbar = true,
  }) : bytes = null;

  const AdvancedPdfViewer.bytes(
    this.bytes, {
    super.key,
    this.controller,
    this.loadingWidget,
    this.showToolbar = true,
  }) : url = null;

  @override
  State<AdvancedPdfViewer> createState() => _AdvancedPdfViewerState();
}

class _AdvancedPdfViewerState extends State<AdvancedPdfViewer> {
  String? _localPath;
  bool _isLoading = true;
  String? _error;
  PdfAnnotationTool _currentTool = PdfAnnotationTool.none;

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

  void _onToolSelected(PdfAnnotationTool tool) {
    setState(() {
      _currentTool = tool;
    });
    widget.controller?.setDrawingMode(tool);
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

    return Stack(
      children: [
        Column(children: [Expanded(child: _buildNativeView())]),
        if (widget.showToolbar)
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ToolButton(
                      icon: Icons.pan_tool_alt,
                      isSelected: _currentTool == PdfAnnotationTool.none,
                      onPressed: () => _onToolSelected(PdfAnnotationTool.none),
                    ),
                    _ToolButton(
                      icon: Icons.edit,
                      isSelected: _currentTool == PdfAnnotationTool.draw,
                      onPressed: () => _onToolSelected(PdfAnnotationTool.draw),
                    ),
                    _ToolButton(
                      icon: Icons.brush,
                      isSelected: _currentTool == PdfAnnotationTool.highlight,
                      onPressed: () =>
                          _onToolSelected(PdfAnnotationTool.highlight),
                    ),
                    _ToolButton(
                      icon: Icons.format_underlined,
                      isSelected: _currentTool == PdfAnnotationTool.underline,
                      onPressed: () =>
                          _onToolSelected(PdfAnnotationTool.underline),
                    ),
                    const VerticalDivider(),
                    IconButton(
                      icon: const Icon(Icons.delete_sweep),
                      onPressed: () => widget.controller?.clearAnnotations(),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildNativeView() {
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

    return Text('$defaultTargetPlatform is not supported');
  }

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('advanced_pdf_viewer_$id');
    widget.controller?._setChannel(channel);
    // Sync current tool if already set
    if (_currentTool != PdfAnnotationTool.none) {
      widget.controller?.setDrawingMode(_currentTool);
    }
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final bool isSelected;
  final VoidCallback onPressed;

  const _ToolButton({
    required this.icon,
    required this.isSelected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon),
      color: isSelected ? Theme.of(context).primaryColor : null,
      onPressed: onPressed,
    );
  }
}
