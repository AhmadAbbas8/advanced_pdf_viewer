import 'package:flutter/material.dart';
import 'pdf_localizations.dart';
import 'pdf_viewer_config.dart';

class PdfColorSelectionDialog extends StatefulWidget {
  final List<Color> defaultColors;
  final Color currentColor;
  final PdfViewerConfig config;
  final ValueChanged<Color> onColorSelected;
  final double? strokeWidth;
  final ValueChanged<double>? onStrokeWidthChanged;

  const PdfColorSelectionDialog({
    super.key,
    required this.defaultColors,
    required this.currentColor,
    required this.config,
    required this.onColorSelected,
    this.strokeWidth,
    this.onStrokeWidthChanged,
  });

  @override
  State<PdfColorSelectionDialog> createState() =>
      _PdfColorSelectionDialogState();
}

class _PdfColorSelectionDialogState extends State<PdfColorSelectionDialog> {
  late List<Color> _colors;
  late Color _selectedColor;
  double? _strokeWidth;

  @override
  void initState() {
    super.initState();
    _colors = List.from(widget.defaultColors);
    _selectedColor = widget.currentColor;
    _strokeWidth = widget.strokeWidth;

    // Ensure currentColor is in the list or added as custom
    if (!_colors.any((c) => c.value == widget.currentColor.value)) {
      _colors.add(widget.currentColor);
    }
  }

  void _showCustomColorPicker() {
    // Simple custom color picker using a Grid of basic colors or a slider
    // For now, let's provide a few more options or a simple way to enter hex
    final localizations = PdfLocalizations.of(context);

    showDialog(
      context: context,
      builder: (context) {
        Color tempColor = _selectedColor;
        return AlertDialog(
          title: Text(localizations.customColor),
          content: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  [
                    Colors.red,
                    Colors.pink,
                    Colors.purple,
                    Colors.deepPurple,
                    Colors.indigo,
                    Colors.blue,
                    Colors.lightBlue,
                    Colors.cyan,
                    Colors.teal,
                    Colors.green,
                    Colors.lightGreen,
                    Colors.lime,
                    Colors.yellow,
                    Colors.amber,
                    Colors.orange,
                    Colors.deepOrange,
                    Colors.brown,
                    Colors.grey,
                    Colors.blueGrey,
                    Colors.black,
                  ].map((color) {
                    return GestureDetector(
                      onTap: () {
                        tempColor = color;
                        Navigator.of(context).pop(tempColor);
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.grey.withOpacity(0.3),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(localizations.cancel),
            ),
          ],
        );
      },
    ).then((selected) {
      if (selected != null && selected is Color) {
        setState(() {
          if (!_colors.any((c) => c.value == selected.value)) {
            _colors.add(selected);
          }
          _selectedColor = selected;
        });
        widget.onColorSelected(selected);
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final localizations = PdfLocalizations.of(context);
    final theme = Theme.of(context);
    final bool showStrokeWidth =
        _strokeWidth != null && widget.onStrokeWidthChanged != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight * 0.85;
        return SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          localizations.selectColor,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 6,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                          ),
                      itemCount: _colors.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _colors.length) {
                          return GestureDetector(
                            onTap: _showCustomColorPicker,
                            child: Container(
                              decoration: BoxDecoration(
                                color: theme.dividerColor.withOpacity(0.1),
                                shape: BoxShape.circle,
                                border: Border.all(color: theme.dividerColor),
                              ),
                              child: const Icon(Icons.add, size: 20),
                            ),
                          );
                        }

                        final color = _colors[index];
                        final isSelected =
                            _selectedColor.value == color.value;

                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedColor = color;
                            });
                            widget.onColorSelected(color);
                            Navigator.of(context).pop();
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? theme.primaryColor
                                    : Colors.grey.withOpacity(0.3),
                                width: isSelected ? 3 : 1,
                              ),
                              boxShadow: [
                                if (isSelected)
                                  BoxShadow(
                                    color: theme.primaryColor.withOpacity(0.4),
                                    blurRadius: 8,
                                    spreadRadius: 2,
                                  ),
                              ],
                            ),
                            child: isSelected
                                ? const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 18,
                                  )
                                : null,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 24),
                    if (showStrokeWidth) ...[
                      _StrokePreview(
                        color: _selectedColor,
                        strokeWidth: _strokeWidth!,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (showStrokeWidth) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            localizations.strokeWidth,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '${_strokeWidth!.toStringAsFixed(1)}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.textTheme.bodySmall?.color,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Slider(
                        value: _strokeWidth!,
                        min: 1.0,
                        max: 12.0,
                        divisions: 22,
                        onChanged: (value) {
                          setState(() => _strokeWidth = value);
                          widget.onStrokeWidthChanged?.call(value);
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StrokePreview extends StatelessWidget {
  final Color color;
  final double strokeWidth;

  const _StrokePreview({required this.color, required this.strokeWidth});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withOpacity(0.08)),
      ),
      child: CustomPaint(
        painter: _StrokePreviewPainter(
          color: color,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _StrokePreviewPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  _StrokePreviewPainter({required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth;
    final y = size.height / 2;
    final start = Offset(12, y);
    final control = Offset(size.width * 0.5, y - 10);
    final end = Offset(size.width - 12, y);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StrokePreviewPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
