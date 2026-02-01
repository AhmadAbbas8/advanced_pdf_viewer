import 'package:flutter/material.dart';
import 'pdf_localizations.dart';
import 'pdf_viewer_config.dart';

class PdfColorSelectionDialog extends StatefulWidget {
  final List<Color> defaultColors;
  final Color currentColor;
  final PdfViewerConfig config;
  final ValueChanged<Color> onColorSelected;

  const PdfColorSelectionDialog({
    super.key,
    required this.defaultColors,
    required this.currentColor,
    required this.config,
    required this.onColorSelected,
  });

  @override
  State<PdfColorSelectionDialog> createState() =>
      _PdfColorSelectionDialogState();
}

class _PdfColorSelectionDialogState extends State<PdfColorSelectionDialog> {
  late List<Color> _colors;
  late Color _selectedColor;

  @override
  void initState() {
    super.initState();
    _colors = List.from(widget.defaultColors);
    _selectedColor = widget.currentColor;

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

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
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
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
              final isSelected = _selectedColor.value == color.value;

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
                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                      : null,
                ),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
