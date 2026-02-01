import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pdf_viewer_controller.dart';
import 'pdf_viewer_config.dart';
import 'pdf_localizations.dart';

class PdfToolbar extends StatelessWidget {
  final PdfAnnotationTool currentTool;
  final Function(PdfAnnotationTool) onToolSelected;
  final AdvancedPdfViewerController? controller;
  final PdfViewerConfig config;
  final VoidCallback onFullScreenPressed;
  final VoidCallback? onBookmarkPressed;
  final VoidCallback? onShowBookmarksPressed;
  final bool isCurrentPageBookmarked;
  final ValueChanged<PdfToolbarStyle>? onStyleChanged;
  final ValueChanged<PdfToolbarPosition>? onPositionChanged;

  const PdfToolbar({
    super.key,
    required this.currentTool,
    required this.onToolSelected,
    this.controller,
    required this.config,
    required this.onFullScreenPressed,
    this.onBookmarkPressed,
    this.onShowBookmarksPressed,
    this.isCurrentPageBookmarked = false,
    this.onStyleChanged,
    this.onPositionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final style = config.toolbarStyle;
    final isFloating = config.toolbarPosition == PdfToolbarPosition.floating;
    final borderRadius =
        style.borderRadius ?? BorderRadius.circular(isFloating ? 32 : 12);

    Widget content = Container(
      margin: style.margin,
      padding: config.toolbarPadding,
      decoration: BoxDecoration(
        color:
            style.backgroundColor ??
            (style.useBlur
                ? Colors.white.withOpacity(0.4)
                : Theme.of(context).cardColor),
        gradient: style.gradient,
        borderRadius: borderRadius,
        boxShadow: [
          if (style.elevation > 0)
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: style.elevation,
              spreadRadius: style.elevation * 0.1,
              offset: Offset(0, style.elevation / 4),
            ),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.3), width: 0.8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ToolButton(
                icon: Icons.pan_tool_alt_rounded,
                isSelected: currentTool == PdfAnnotationTool.none,
                onPressed: () => _handleToolSelect(PdfAnnotationTool.none),
                tooltip: 'Pan',
                activeColor: Colors.amber,
                config: config,
              ),
              if (config.showDrawButton)
                _ToolButton(
                  icon: Icons.edit_rounded,
                  isSelected: currentTool == PdfAnnotationTool.draw,
                  onPressed: () => _handleToolSelect(PdfAnnotationTool.draw),
                  tooltip: 'Draw',
                  config: config,
                ),
              if (config.showHighlightButton)
                _ToolButton(
                  icon: Icons.brush_rounded,
                  isSelected: currentTool == PdfAnnotationTool.highlight,
                  onPressed: () =>
                      _handleToolSelect(PdfAnnotationTool.highlight),
                  tooltip: 'Highlight',
                  config: config,
                  activeColor: Colors.cyan,
                ),
              if (config.showUnderlineButton)
                _ToolButton(
                  icon: Icons.format_underlined_rounded,
                  isSelected: currentTool == PdfAnnotationTool.underline,
                  onPressed: () =>
                      _handleToolSelect(PdfAnnotationTool.underline),
                  tooltip: 'Underline',
                  config: config,
                ),
              if (config.showTextButton)
                _ToolButton(
                  icon: Icons.text_fields_rounded,
                  isSelected: currentTool == PdfAnnotationTool.text,
                  onPressed: () => _handleToolSelect(PdfAnnotationTool.text),
                  tooltip: 'Add Text',
                  config: config,
                ),
              _Divider(config: config),
              if (config.showUndoButton)
                _ActionButton(
                  icon: Icons.undo_rounded,
                  onPressed: () => controller?.undo(),
                  tooltip: 'Undo',
                  config: config,
                ),
              if (config.showRedoButton)
                _ActionButton(
                  icon: Icons.redo_rounded,
                  onPressed: () => controller?.redo(),
                  tooltip: 'Redo',
                  config: config,
                ),
              if (config.showClearButton)
                _ActionButton(
                  icon: Icons.delete_sweep_rounded,
                  onPressed: () => controller?.clearAnnotations(),
                  tooltip: 'Clear All',
                  config: config,
                ),
              if (config.allowFullScreen ||
                  config.showZoomButtons ||
                  config.enableBookmarks ||
                  config.showToolbarSettings)
                _Divider(config: config),
              if (config.allowFullScreen)
                _ActionButton(
                  icon: Icons.fullscreen_rounded,
                  onPressed: onFullScreenPressed,
                  tooltip: 'Full Screen',
                  config: config,
                ),
              if (config.showZoomButtons) ...[
                _ActionButton(
                  icon: Icons.zoom_in_rounded,
                  onPressed: () => controller?.zoomIn(),
                  tooltip: 'Zoom In',
                  config: config,
                ),
                _ActionButton(
                  icon: Icons.zoom_out_rounded,
                  onPressed: () => controller?.zoomOut(),
                  tooltip: 'Zoom Out',
                  config: config,
                ),
              ],
              if (config.enableBookmarks) ...[
                if (config.showBookmarkButton)
                  _ActionButton(
                    icon: isCurrentPageBookmarked
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_border_rounded,
                    onPressed: onBookmarkPressed,
                    tooltip: isCurrentPageBookmarked
                        ? 'Remove Bookmark'
                        : 'Add Bookmark',
                    config: config,
                  ),
                if (config.showBookmarksListButton)
                  _ActionButton(
                    icon: Icons.bookmarks_rounded,
                    onPressed: onShowBookmarksPressed,
                    tooltip: 'View Bookmarks',
                    config: config,
                  ),
              ],
              if (config.showToolbarSettings)
                _ActionButton(
                  icon: Icons.tune_rounded,
                  onPressed: () => _showSettings(context),
                  tooltip: 'Toolbar Settings',
                  config: config,
                ),
            ],
          ),
        ),
      ),
    );

    if (style.useBlur) {
      content = ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: style.blurSigma,
            sigmaY: style.blurSigma,
          ),
          child: content,
        ),
      );
    }

    return Hero(
      tag: 'pdf_toolbar',
      child: Padding(padding: style.margin ?? EdgeInsets.zero, child: content),
    );
  }

  void _handleToolSelect(PdfAnnotationTool tool) {
    HapticFeedback.mediumImpact();
    onToolSelected(tool);
  }

  void _showSettings(BuildContext context) {
    final localizations = PdfLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _SettingsSheet(
        initialConfig: config,
        localizations: localizations,
        onStyleChanged: onStyleChanged,
        onPositionChanged: onPositionChanged,
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final bool isSelected;
  final VoidCallback onPressed;
  final String tooltip;
  final Color? activeColor;
  final PdfViewerConfig config;

  const _ToolButton({
    required this.icon,
    required this.isSelected,
    required this.onPressed,
    required this.tooltip,
    this.activeColor,
    required this.config,
  });

  @override
  Widget build(BuildContext context) {
    final style = config.toolbarStyle;
    final effectiveActiveColor =
        activeColor ?? style.activeColor ?? Theme.of(context).primaryColor;

    return Tooltip(
      message: tooltip,
      child: AnimatedScale(
        scale: isSelected ? 1.1 : 1.0,
        duration: const Duration(milliseconds: 200),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.elasticOut,
          margin: EdgeInsets.symmetric(
            horizontal: style.itemSpacing / 2,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: isSelected
                ? effectiveActiveColor.withOpacity(0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected
                  ? effectiveActiveColor.withOpacity(0.3)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: IconButton(
            icon: Icon(icon),
            color: isSelected
                ? effectiveActiveColor
                : (style.inactiveColor ?? Colors.black54),
            onPressed: onPressed,
            iconSize: 22,
            splashRadius: 24,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final PdfViewerConfig config;

  const _ActionButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    required this.config,
  });

  @override
  Widget build(BuildContext context) {
    final style = config.toolbarStyle;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon),
        color: style.inactiveColor ?? Colors.black54,
        onPressed: () {
          HapticFeedback.selectionClick();
          onPressed?.call();
        },
        iconSize: 22,
        splashRadius: 24,
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  final PdfViewerConfig config;
  const _Divider({required this.config});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
      child: Container(
        width: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withOpacity(0),
              Colors.black.withOpacity(0.1),
              Colors.black.withOpacity(0),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSheet extends StatefulWidget {
  final PdfViewerConfig initialConfig;
  final PdfLocalizations localizations;
  final ValueChanged<PdfToolbarStyle>? onStyleChanged;
  final ValueChanged<PdfToolbarPosition>? onPositionChanged;

  const _SettingsSheet({
    required this.initialConfig,
    required this.localizations,
    this.onStyleChanged,
    this.onPositionChanged,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late PdfToolbarPosition _currentPosition;
  late PdfToolbarStyle _currentStyle;

  @override
  void initState() {
    super.initState();
    _currentPosition = widget.initialConfig.toolbarPosition;
    _currentStyle = widget.initialConfig.toolbarStyle;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor.withOpacity(0.98),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        top: 12,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).padding.bottom + 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                margin: const EdgeInsets.only(bottom: 28),
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.localizations.toolbarSettings,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.8,
                      fontSize: 22,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      widget.onStyleChanged?.call(const PdfToolbarStyle());
                      widget.onPositionChanged?.call(PdfToolbarPosition.top);
                      HapticFeedback.vibrate();
                      Navigator.pop(context);
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    label: const Text(
                      'Reset',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              _buildSection(
                widget.localizations.position,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: theme.dividerColor.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return ToggleButtons(
                        constraints: BoxConstraints.expand(
                          width: (constraints.maxWidth - 4) / 3,
                          height: 48,
                        ),
                        isSelected: [
                          _currentPosition == PdfToolbarPosition.top,
                          _currentPosition == PdfToolbarPosition.bottom,
                          _currentPosition == PdfToolbarPosition.floating,
                        ],
                        onPressed: (index) {
                          setState(() {
                            _currentPosition = PdfToolbarPosition.values[index];
                          });
                          widget.onPositionChanged?.call(_currentPosition);
                          HapticFeedback.lightImpact();
                        },
                        borderRadius: BorderRadius.circular(16),
                        borderWidth: 0,
                        selectedBorderColor: Colors.transparent,
                        fillColor: theme.primaryColor,
                        selectedColor: Colors.white,
                        color: theme.hintColor.withOpacity(0.6),
                        renderBorder: false,
                        children: [
                          _buildToggleItem(
                            widget.localizations.top,
                            Icons.align_vertical_top_rounded,
                            _currentPosition == PdfToolbarPosition.top,
                          ),
                          _buildToggleItem(
                            widget.localizations.bottom,
                            Icons.align_vertical_bottom_rounded,
                            _currentPosition == PdfToolbarPosition.bottom,
                          ),
                          _buildToggleItem(
                            widget.localizations.floating,
                            Icons.grid_view_rounded,
                            _currentPosition == PdfToolbarPosition.floating,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 32),
              _buildSection(
                widget.localizations.theme,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                      _ThemePresetButton(
                        label: 'Indigo',
                        color1: Colors.indigo,
                        color2: Colors.indigoAccent,
                        isSelected:
                            _currentStyle.activeColor == Colors.indigoAccent,
                        onTap: () => _updateLocalStyle(
                          activeColor: Colors.indigoAccent,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Colors.indigo, Colors.indigoAccent],
                          ),
                        ),
                      ),
                      _ThemePresetButton(
                        label: 'Ocean',
                        color1: Colors.blue,
                        color2: Colors.cyanAccent,
                        isSelected: _currentStyle.activeColor == Colors.blue,
                        onTap: () => _updateLocalStyle(
                          activeColor: Colors.blue,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Colors.blue, Colors.cyanAccent],
                          ),
                        ),
                      ),
                      _ThemePresetButton(
                        label: 'Emerald',
                        color1: Colors.teal,
                        color2: Colors.greenAccent,
                        isSelected: _currentStyle.activeColor == Colors.teal,
                        onTap: () => _updateLocalStyle(
                          activeColor: Colors.teal,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Colors.teal, Colors.greenAccent],
                          ),
                        ),
                      ),
                      _ThemePresetButton(
                        label: 'Crimson',
                        color1: Colors.red,
                        color2: Colors.orangeAccent,
                        isSelected: _currentStyle.activeColor == Colors.red,
                        onTap: () => _updateLocalStyle(
                          activeColor: Colors.red,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Colors.red, Colors.orangeAccent],
                          ),
                        ),
                      ),
                      _ThemePresetButton(
                        label: 'Classic',
                        color1: isDark ? Colors.grey[700]! : Colors.grey[300]!,
                        color2: isDark ? Colors.grey[800]! : Colors.grey[400]!,
                        isSelected:
                            _currentStyle.activeColor == null &&
                            _currentStyle.gradient == null,
                        onTap: () => _updateLocalStyle(
                          activeColor: null,
                          gradient: null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.dividerColor.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: theme.primaryColor.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.auto_awesome_rounded,
                            color: theme.primaryColor,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          widget.localizations.transparency,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Switch.adaptive(
                      value: _currentStyle.useBlur,
                      activeColor: theme.primaryColor,
                      onChanged: (value) {
                        setState(() {
                          _currentStyle = _currentStyle.copyWith(
                            useBlur: value,
                          );
                        });
                        widget.onStyleChanged?.call(_currentStyle);
                        HapticFeedback.lightImpact();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _updateLocalStyle({Color? activeColor, Gradient? gradient}) {
    setState(() {
      _currentStyle = _currentStyle.copyWith(
        activeColor: activeColor,
        gradient: gradient,
      );
    });
    widget.onStyleChanged?.call(_currentStyle);
    HapticFeedback.selectionClick();
  }

  Widget _buildToggleItem(String label, IconData icon, bool isSelected) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 20),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildSection(String title, {required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 16),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: Colors.grey,
              letterSpacing: 1.5,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _ThemePresetButton extends StatelessWidget {
  final String label;
  final Color color1;
  final Color color2;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemePresetButton({
    required this.label,
    required this.color1,
    required this.color2,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: 20),
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              width: 64,
              height: 64,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? color1 : Colors.transparent,
                  width: 3,
                ),
                boxShadow: [
                  if (isSelected)
                    BoxShadow(
                      color: color1.withOpacity(0.3),
                      blurRadius: 15,
                      spreadRadius: 2,
                    ),
                ],
              ),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [color1, color2],
                  ),
                ),
                child: isSelected
                    ? const Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 28,
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
                color: isSelected ? color1 : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorButton extends StatelessWidget {
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  const _ColorButton({
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: isSelected ? Border.all(color: Colors.black, width: 2) : null,
        ),
      ),
    );
  }
}
