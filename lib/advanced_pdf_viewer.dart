import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'advanced_pdf_viewer_platform_interface.dart';
import 'src/pdf_viewer_controller.dart';
import 'src/pdf_cache_manager.dart';
import 'src/pdf_viewer_config.dart';
import 'src/pdf_toolbar.dart';
import 'src/bookmark_manager.dart';
import 'src/bookmarks_dialog.dart';
import 'src/pdf_localizations.dart';
import 'src/pdf_snackbar.dart';

export 'src/pdf_viewer_controller.dart';
export 'src/pdf_viewer_config.dart';
export 'src/bookmark_manager.dart';
export 'src/pdf_localizations.dart';

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

  // Bookmark-related state
  final BookmarkManager _bookmarkManager = BookmarkManager();
  String? _pdfKey;
  int _currentPage = 0;
  bool _isCurrentPageBookmarked = false;

  // Runtime toolbar customization state
  late PdfToolbarPosition _toolbarPosition;
  late PdfToolbarStyle _toolbarStyle;
  late Color _drawColor;
  late Color _highlightColor;
  late Color _underlineColor;
  late Color _textColor;

  // Draggable text annotation overlay state
  OverlayEntry? _textOverlayEntry;
  String? _pendingText;
  int _pendingPageIndex = 0;
  Offset _textOverlayPosition = Offset.zero;
  double _textFontSize = 14.0;
  double _nativeTapX = 0.0;
  double _nativeTapY = 0.0;

  @override
  void initState() {
    super.initState();
    _toolbarPosition = widget.config.toolbarPosition;
    _toolbarStyle = widget.config.toolbarStyle;
    _drawColor = widget.config.drawColor;
    _highlightColor = widget.config.highlightColor;
    _underlineColor = widget.config.underlineColor;
    _textColor = widget.config.textColor;
    widget.controller?.setOnPdfTapped(_onPdfTapped);
    if (widget.config.enableBookmarks) {
      widget.controller?.setOnPageChanged(_onPageChanged);
      _initializeBookmarks();
    }
    _preparePdf();
  }

  void _initializeBookmarks() {
    // Generate or use provided PDF key
    _pdfKey =
        widget.config.bookmarkStorageKey ??
        BookmarkManager.generatePdfKey(widget.url, widget.bytes);
  }

  void _onPageChanged(int page) async {
    setState(() {
      _currentPage = page;
    });

    // Call config callback if provided
    widget.config.onPageChanged?.call(page);

    // Update bookmark state
    if (widget.config.enableBookmarks && _pdfKey != null) {
      final isBookmarked = await _bookmarkManager.isBookmarked(_pdfKey!, page);
      setState(() {
        _isCurrentPageBookmarked = isBookmarked;
      });
    }
  }

  @override
  void didUpdateWidget(AdvancedPdfViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.config != oldWidget.config) {
      widget.controller?.updateConfig(
        drawColor: widget.config.drawColor,
        highlightColor: widget.config.highlightColor,
        underlineColor: widget.config.underlineColor,
        enablePageNumber: widget.config.enablePageNumber,
      );
      setState(() {
        _toolbarPosition = widget.config.toolbarPosition;
        _toolbarStyle = widget.config.toolbarStyle;
        _drawColor = widget.config.drawColor;
        _highlightColor = widget.config.highlightColor;
        _underlineColor = widget.config.underlineColor;
        _textColor = widget.config.textColor;
      });
    }
  }

  @override
  void dispose() {
    _removeTextOverlay();
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

  /// Get effective localizations based on config, inheritance, or default
  PdfLocalizations _getEffectiveLocalizations(BuildContext context) {
    if (widget.config.language != null) {
      return PdfLocalizations(widget.config.language!);
    }

    // Try to get from provider
    final provider = context
        .dependOnInheritedWidgetOfExactType<PdfLocalizationsProvider>();
    if (provider != null) {
      return provider.localizations;
    }

    return const PdfLocalizations(PdfViewerLanguage.english);
  }

  Future<void> _showTextInputDialog(double x, double y, int pageIndex) async {
    final localizations = _getEffectiveLocalizations(context);
    final TextEditingController textController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(localizations.addText),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: InputDecoration(hintText: localizations.enterTextHere),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(localizations.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, textController.text),
            child: Text(localizations.add),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      _showDraggableTextOverlay(result, x, y, pageIndex);
    }
  }

  void _showDraggableTextOverlay(
    String text,
    double x,
    double y,
    int pageIndex,
  ) {
    _removeTextOverlay();
    _pendingText = text;
    _pendingPageIndex = pageIndex;
    _textFontSize = 14.0;
    _nativeTapX = x;
    _nativeTapY = y;

    // Get widget's global position to convert native coords to screen coords
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final globalOffset = renderBox.localToGlobal(Offset.zero);

    // Position overlay in screen space:
    // We assume x and y from native give us the exact tap position relative to the platform view
    _textOverlayPosition = Offset(x + globalOffset.dx, y + globalOffset.dy);

    _textOverlayEntry = OverlayEntry(
      builder: (_) => _DraggableTextOverlay(
        text: _pendingText!,
        initialPosition: _textOverlayPosition,
        initialFontSize: _textFontSize,
        textColor: _textColor,
        onConfirm: (Offset finalPosition, double finalFontSize) {
          // Calculate drag delta in screen pixels
          final deltaX = finalPosition.dx - _textOverlayPosition.dx;
          final deltaY = finalPosition.dy - _textOverlayPosition.dy;

          // Send original native coords + delta to native
          widget.controller?.addTextAnnotation(
            _pendingText!,
            _nativeTapX,
            _nativeTapY,
            _pendingPageIndex,
            color: _textColor,
            fontSize: finalFontSize,
            deltaX: deltaX,
            deltaY: deltaY,
          );
          _removeTextOverlay();
        },
        onDelete: () {
          _removeTextOverlay();
        },
      ),
    );

    Overlay.of(context).insert(_textOverlayEntry!);
  }

  void _removeTextOverlay() {
    _textOverlayEntry?.remove();
    _textOverlayEntry = null;
    _pendingText = null;
  }

  Future<void> _handleBookmarkPressed() async {
    if (_pdfKey == null) return;

    // Check if current page is already bookmarked
    if (_isCurrentPageBookmarked) {
      // Remove bookmark
      await _bookmarkManager.removeBookmark(_pdfKey!, _currentPage);
      setState(() {
        _isCurrentPageBookmarked = false;
      });
      if (mounted) {
        final localizations = _getEffectiveLocalizations(context);
        PdfSnackBar.show(
          context,
          content: localizations.bookmarkRemoved,
          type: SnackBarType.info,
        );
      }
    } else {
      // Show dialog to add bookmark with optional name
      final localizations = _getEffectiveLocalizations(context);
      final TextEditingController nameController = TextEditingController(
        text: localizations.pageNumber(_currentPage),
      );

      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(localizations.addBookmark),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: InputDecoration(
              hintText: localizations.enterBookmarkName,
              labelText: localizations.bookmarkName,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(localizations.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, nameController.text),
              child: Text(localizations.save),
            ),
          ],
        ),
      );

      if (result != null && result.isNotEmpty) {
        await _bookmarkManager.saveBookmark(_pdfKey!, _currentPage, result);
        setState(() {
          _isCurrentPageBookmarked = true;
        });
        if (mounted) {
          final localizations = _getEffectiveLocalizations(context);
          PdfSnackBar.show(
            context,
            content: localizations.bookmarkAdded,
            type: SnackBarType.success,
          );
        }
      }
    }
  }

  Future<void> _handleShowBookmarks() async {
    if (_pdfKey == null) return;

    final bookmarks = await _bookmarkManager.getBookmarks(_pdfKey!);

    if (!mounted) return;

    final selectedPage = await showBookmarksDialog(
      context: context,
      bookmarks: bookmarks,
      onRemoveBookmark: (page) async {
        await _bookmarkManager.removeBookmark(_pdfKey!, page);
        // Update state if the removed bookmark is current page
        if (page == _currentPage) {
          setState(() {
            _isCurrentPageBookmarked = false;
          });
        }
      },
      localizations: _getEffectiveLocalizations(context),
    );

    if (selectedPage != null && mounted) {
      // Navigate to selected page
      widget.controller?.jumpToPage(selectedPage);
    }
  }

  void _onToolSelected(PdfAnnotationTool tool) {
    setState(() {
      _currentTool = tool;
    });
    Color? color;
    if (tool == PdfAnnotationTool.draw) color = _drawColor;
    if (tool == PdfAnnotationTool.highlight) {
      color = _highlightColor;
    }
    if (tool == PdfAnnotationTool.underline) {
      color = _underlineColor;
    }
    if (tool == PdfAnnotationTool.text) {
      color = _textColor;
    }
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
      final localizations = _getEffectiveLocalizations(context);
      return Center(child: Text(localizations.errorMessage(_error!)));
    }

    // Get effective localizations for the provider
    final localizations = _getEffectiveLocalizations(context);

    // Wrap with localization provider and directionality
    return PdfLocalizationsProvider(
      localizations: localizations,
      child: Directionality(
        textDirection: localizations.isRTL
            ? TextDirection.rtl
            : TextDirection.ltr,
        child: _buildViewerContent(),
      ),
    );
  }

  Widget _buildViewerContent() {
    return Stack(
      children: [
        _buildNativeView(),
        if (widget.showToolbar)
          SafeArea(
            bottom: _toolbarPosition == PdfToolbarPosition.bottom,
            top: _toolbarPosition != PdfToolbarPosition.bottom,
            child: Align(
              alignment: _getToolbarAlignment(),
              child: Padding(
                padding: _getToolbarPadding(),
                child: PdfToolbar(
                  currentTool: _currentTool,
                  onToolSelected: _onToolSelected,
                  controller: widget.controller,
                  config: widget.config.copyWith(
                    toolbarPosition: _toolbarPosition,
                    toolbarStyle: _toolbarStyle,
                  ),
                  onFullScreenPressed: _onFullScreen,
                  onBookmarkPressed: widget.config.enableBookmarks
                      ? _handleBookmarkPressed
                      : null,
                  onShowBookmarksPressed: widget.config.enableBookmarks
                      ? _handleShowBookmarks
                      : null,
                  isCurrentPageBookmarked: _isCurrentPageBookmarked,
                  onStyleChanged: (style) =>
                      setState(() => _toolbarStyle = style),
                  onPositionChanged: (pos) =>
                      setState(() => _toolbarPosition = pos),
                  drawColor: _drawColor,
                  highlightColor: _highlightColor,
                  underlineColor: _underlineColor,
                  textColor: _textColor,
                  onDrawColorChanged: (color) =>
                      setState(() => _drawColor = color),
                  onHighlightColorChanged: (color) =>
                      setState(() => _highlightColor = color),
                  onUnderlineColorChanged: (color) =>
                      setState(() => _underlineColor = color),
                  onTextColorChanged: (color) =>
                      setState(() => _textColor = color),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Alignment _getToolbarAlignment() {
    switch (_toolbarPosition) {
      case PdfToolbarPosition.top:
        return Alignment.topCenter;
      case PdfToolbarPosition.bottom:
        return Alignment.bottomCenter;
      case PdfToolbarPosition.floating:
        return Alignment.topCenter;
    }
  }

  EdgeInsets _getToolbarPadding() {
    if (_toolbarPosition == PdfToolbarPosition.floating) {
      return const EdgeInsets.fromLTRB(16, 24, 16, 0);
    }
    return const EdgeInsets.all(16.0);
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
      enablePageNumber: widget.config.enablePageNumber,
    );

    if (_currentTool != PdfAnnotationTool.none) {
      _onToolSelected(_currentTool);
    }
  }
}

/// A draggable, resizable text overlay that allows the user to position text
/// on the PDF before confirming or deleting.
class _DraggableTextOverlay extends StatefulWidget {
  final String text;
  final Offset initialPosition;
  final double initialFontSize;
  final Color textColor;
  final void Function(Offset finalPosition, double finalFontSize) onConfirm;
  final VoidCallback onDelete;

  const _DraggableTextOverlay({
    required this.text,
    required this.initialPosition,
    required this.initialFontSize,
    required this.textColor,
    required this.onConfirm,
    required this.onDelete,
  });

  @override
  State<_DraggableTextOverlay> createState() => _DraggableTextOverlayState();
}

class _DraggableTextOverlayState extends State<_DraggableTextOverlay>
    with SingleTickerProviderStateMixin {
  late Offset _position;
  late double _fontSize;
  late AnimationController _animController;
  late Animation<double> _scaleAnim;

  static const double _minFontSize = 8.0;
  static const double _maxFontSize = 48.0;
  static const double _fontSizeStep = 2.0;

  @override
  void initState() {
    super.initState();
    _position = widget.initialPosition;
    _fontSize = widget.initialFontSize;
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _scaleAnim = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutBack,
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _increaseFontSize() {
    setState(() {
      _fontSize = (_fontSize + _fontSizeStep).clamp(_minFontSize, _maxFontSize);
    });
  }

  void _decreaseFontSize() {
    setState(() {
      _fontSize = (_fontSize - _fontSizeStep).clamp(_minFontSize, _maxFontSize);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Semi-transparent backdrop (dismissible on tap)
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onDelete,
            child: Container(color: Colors.black.withAlpha(30)),
          ),
        ),
        // Draggable text + action bar
        Positioned(
          left: _position.dx,
          top: _position.dy,
          child: ScaleTransition(
            scale: _scaleAnim,
            alignment: Alignment.topLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The draggable text
                GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      _position += details.delta;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(230),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: widget.textColor.withAlpha(150),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(40),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.drag_indicator,
                          size: 18,
                          color: Colors.grey.shade500,
                        ),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 250),
                          child: Text(
                            widget.text,
                            style: TextStyle(
                              color: widget.textColor,
                              fontSize: _fontSize,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                // Action bar
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(50),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Decrease font size
                      _ActionButton(
                        icon: Icons.text_decrease,
                        onTap: _decreaseFontSize,
                        tooltip: 'A−',
                      ),
                      // Font size indicator
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '${_fontSize.round()}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ),
                      // Increase font size
                      _ActionButton(
                        icon: Icons.text_increase,
                        onTap: _increaseFontSize,
                        tooltip: 'A+',
                      ),
                      Container(
                        width: 1,
                        height: 20,
                        color: Colors.grey.shade300,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      // Confirm
                      _ActionButton(
                        icon: Icons.check_circle,
                        color: Colors.green,
                        onTap: () => widget.onConfirm(_position, _fontSize),
                        tooltip: '✓',
                      ),
                      // Delete
                      _ActionButton(
                        icon: Icons.cancel,
                        color: Colors.red,
                        onTap: widget.onDelete,
                        tooltip: '✗',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Small icon button used in the text overlay action bar.
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final String? tooltip;

  const _ActionButton({
    required this.icon,
    required this.onTap,
    this.color,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 20, color: color ?? Colors.grey.shade700),
        ),
      ),
    );
  }
}
