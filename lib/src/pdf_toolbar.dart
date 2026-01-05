import 'package:flutter/material.dart';
import 'pdf_viewer_controller.dart';
import 'pdf_viewer_config.dart';

class PdfToolbar extends StatelessWidget {
  final PdfAnnotationTool currentTool;
  final Function(PdfAnnotationTool) onToolSelected;
  final AdvancedPdfViewerController? controller;
  final PdfViewerConfig config;
  final VoidCallback onFullScreenPressed;

  const PdfToolbar({
    super.key,
    required this.currentTool,
    required this.onToolSelected,
    this.controller,
    required this.config,
    required this.onFullScreenPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      color: config.toolbarColor,
      child: Padding(
        padding: config.toolbarPadding,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ToolButton(
                  icon: Icons.pan_tool_alt,
                  isSelected: currentTool == PdfAnnotationTool.none,
                  onPressed: () => onToolSelected(PdfAnnotationTool.none),
                  tooltip: 'Pan',
                ),
                if (config.showDrawButton)
                  _ToolButton(
                    icon: Icons.edit,
                    isSelected: currentTool == PdfAnnotationTool.draw,
                    onPressed: () => onToolSelected(PdfAnnotationTool.draw),
                    tooltip: 'Draw',
                  ),
                if (config.showHighlightButton)
                  _ToolButton(
                    icon: Icons.brush,
                    isSelected: currentTool == PdfAnnotationTool.highlight,
                    onPressed: () =>
                        onToolSelected(PdfAnnotationTool.highlight),
                    tooltip: 'Highlight',
                  ),
                if (config.showUnderlineButton)
                  _ToolButton(
                    icon: Icons.format_underlined,
                    isSelected: currentTool == PdfAnnotationTool.underline,
                    onPressed: () =>
                        onToolSelected(PdfAnnotationTool.underline),
                    tooltip: 'Underline',
                  ),
                if (config.showTextButton)
                  _ToolButton(
                    icon: Icons.text_fields,
                    isSelected: currentTool == PdfAnnotationTool.text,
                    onPressed: () => onToolSelected(PdfAnnotationTool.text),
                    tooltip: 'Add Text',
                  ),
                if (config.showUndoButton ||
                    config.showRedoButton ||
                    config.showClearButton)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8.0),
                    child: VerticalDivider(width: 20),
                  ),
                if (config.showUndoButton)
                  IconButton(
                    icon: const Icon(Icons.undo),
                    onPressed: () => controller?.undo(),
                    tooltip: 'Undo',
                  ),
                if (config.showRedoButton)
                  IconButton(
                    icon: const Icon(Icons.redo),
                    onPressed: () => controller?.redo(),
                    tooltip: 'Redo',
                  ),
                if (config.showClearButton)
                  IconButton(
                    icon: const Icon(Icons.delete_sweep),
                    onPressed: () => controller?.clearAnnotations(),
                    tooltip: 'Clear All',
                  ),
                if (config.allowFullScreen) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8.0),
                    child: VerticalDivider(width: 20),
                  ),
                  IconButton(
                    icon: const Icon(Icons.fullscreen),
                    onPressed: onFullScreenPressed,
                    tooltip: 'Full Screen',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final bool isSelected;
  final VoidCallback onPressed;
  final String tooltip;

  const _ToolButton({
    required this.icon,
    required this.isSelected,
    required this.onPressed,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: isSelected ? Colors.yellow.withOpacity(0.8) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: IconButton(
        icon: Icon(icon),
        color: isSelected ? Colors.black : null,
        onPressed: onPressed,
        tooltip: tooltip,
      ),
    );
  }
}
