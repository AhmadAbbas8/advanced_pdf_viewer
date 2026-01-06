import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'advanced_pdf_viewer_platform_interface.dart';
import 'src/pdf_viewer_controller.dart';
import 'src/pdf_cache_manager.dart';
import 'src/pdf_viewer_config.dart';
import 'src/pdf_toolbar.dart';

export 'src/pdf_viewer_controller.dart';
export 'src/pdf_viewer_config.dart';

class AdvancedPdfViewerPlugin {
  Future<String?> getPlatformVersion() {
    return AdvancedPdfViewerPlatform.instance.getPlatformVersion();
  }
}

class AdvancedPdfViewer extends StatefulWidget {
  final String? url;
  final Uint8List? bytes;
  final AdvancedPdfViewerController? controller;
  final Widget? loadingWidget;
  final bool showToolbar;
  final PdfViewerConfig config;
  final bool useCache;

  const AdvancedPdfViewer.network(
    this.url, {
    super.key,
    this.controller,
    this.loadingWidget,
    this.showToolbar = true,
    this.config = const PdfViewerConfig(),
    this.useCache = true,
  }) : bytes = null;

  const AdvancedPdfViewer.bytes(
    this.bytes, {
    super.key,
    this.controller,
    this.loadingWidget,
    this.showToolbar = true,
    this.config = const PdfViewerConfig(),
    this.useCache = true,
  }) : url = null;

  const AdvancedPdfViewer._internal({
    this.url,
    this.bytes,
    this.controller,
    required this.showToolbar,
    required this.config,
    this.useCache = true,
  }) : loadingWidget = null;

  @override
  State<AdvancedPdfViewer> createState() => _AdvancedPdfViewerState();
}

class _AdvancedPdfViewerState extends State<AdvancedPdfViewer> {
  String? _localPath;
  bool _isLoading = true;
  bool _isTempFile = false;
  String? _error;
  PdfAnnotationTool _currentTool = PdfAnnotationTool.none;

  @override
  void initState() {
    super.initState();
    widget.controller?.setOnPdfTapped(_onPdfTapped);
    _preparePdf();
  }

  @override
  void didUpdateWidget(AdvancedPdfViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.config != oldWidget.config) {
      widget.controller?.updateConfig(
        drawColor: widget.config.drawColor,
        highlightColor: widget.config.highlightColor,
        underlineColor: widget.config.underlineColor,
      );
    }
  }

  @override
  void dispose() {
    if (!widget.useCache && _localPath != null) {
      _cleanupCache();
    }
    super.dispose();
  }

  Future<void> _cleanupCache() async {
    try {
      if (_localPath != null) {
        final file = File(_localPath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('Error cleaning up cache: $e');
    }
  }

  Future<void> _preparePdf() async {
    try {
      File file;
      if (!widget.useCache && widget.url != null) {
        file = await PdfCacheManager.downloadToTemp(widget.url!);
        _isTempFile = true;
      } else {
        file = await PdfCacheManager.preparePdf(
          url: widget.url,
          bytes: widget.bytes,
          useCache: widget.useCache,
        );
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

  void _onPdfTapped(double x, double y, int pageIndex) {
    if (_currentTool == PdfAnnotationTool.text) {
      _showTextInputDialog(x, y, pageIndex);
    }
  }

  Future<void> _showTextInputDialog(double x, double y, int pageIndex) async {
    final TextEditingController textController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Text'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter text here'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, textController.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      widget.controller?.addTextAnnotation(
        result,
        x,
        y,
        pageIndex,
        color: widget.config.drawColor,
      );
    }
  }

  void _onToolSelected(PdfAnnotationTool tool) {
    setState(() {
      _currentTool = tool;
    });
    Color? color;
    if (tool == PdfAnnotationTool.draw) color = widget.config.drawColor;
    if (tool == PdfAnnotationTool.highlight)
      color = widget.config.highlightColor;
    if (tool == PdfAnnotationTool.underline)
      color = widget.config.underlineColor;
    widget.controller?.setDrawingMode(tool, color: color);

    // Lock scrolling if any annotation tool is active
    final bool shouldLock = tool != PdfAnnotationTool.none;
    widget.controller?.setScrollLocked(shouldLock);
  }

  Future<void> _onFullScreen() async {
    widget.config.onFullScreenInit?.call();

    final PdfAnnotationTool? resultTool = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          body: Stack(
            children: [
              AdvancedPdfViewer._internal(
                url: widget.url,
                bytes: widget.bytes,
                controller: widget.controller,
                showToolbar: widget.showToolbar,
                config: widget.config.copyWith(allowFullScreen: false),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: CircleAvatar(
                      backgroundColor: Colors.black.withAlpha(54),
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () =>
                            Navigator.of(context).pop(_currentTool),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (mounted && resultTool != null) {
      _onToolSelected(resultTool);
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

    return Stack(
      children: [
        _buildNativeView(),
        if (widget.showToolbar)
          SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: PdfToolbar(
                  currentTool: _currentTool,
                  onToolSelected: _onToolSelected,
                  controller: widget.controller,
                  config: widget.config,
                  onFullScreenPressed: _onFullScreen,
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
      'isTempFile': _isTempFile,
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

    return Center(child: Text('$defaultTargetPlatform is not supported'));
  }

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('advanced_pdf_viewer_$id');
    widget.controller?.setChannel(channel);

    // Set initial colors from config
    widget.controller?.updateConfig(
      drawColor: widget.config.drawColor,
      highlightColor: widget.config.highlightColor,
      underlineColor: widget.config.underlineColor,
    );

    if (_currentTool != PdfAnnotationTool.none) {
      _onToolSelected(_currentTool);
    }
  }
}
