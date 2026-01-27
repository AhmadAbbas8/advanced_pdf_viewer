import 'dart:async';
import 'package:flutter/material.dart';

/// Type of the snackbar to display
enum SnackBarType { info, success, error }

/// Helper class to show adaptive and enhanced SnackBars using Overlay
class PdfSnackBar {
  static OverlayEntry? _currentEntry;

  /// Shows a customized SnackBar with improved UI, animations, and reliable dismissal
  static void show(
    BuildContext context, {
    required String content,
    SnackBarType type = SnackBarType.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    // 1. Immediately remove any existing SnackBar
    _removeCurrent();

    // 2. Create the new overlay entry
    final entry = OverlayEntry(
      builder: (context) => _SnackbarWidget(
        content: content,
        type: type,
        duration: duration,
        onDismiss: _removeCurrent,
      ),
    );

    // 3. Insert into overlay
    Overlay.of(context).insert(entry);
    _currentEntry = entry;
  }

  static void _removeCurrent() {
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

class _SnackbarWidget extends StatefulWidget {
  final String content;
  final SnackBarType type;
  final Duration duration;
  final VoidCallback onDismiss;

  const _SnackbarWidget({
    required this.content,
    required this.type,
    required this.duration,
    required this.onDismiss,
  });

  @override
  State<_SnackbarWidget> createState() => _SnackbarWidgetState();
}

class _SnackbarWidgetState extends State<_SnackbarWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<Offset> _offset;
  Timer? _timer;

  @override
  void initState() {
    super.initState();

    // Setup Animation
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
      reverseDuration: const Duration(milliseconds: 300),
    );

    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

    _offset = Tween<Offset>(begin: const Offset(0.0, 1.0), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: Curves.easeOut, // Bouncy spring effect
          ),
        );

    // Start Entry Animation
    _controller.forward();

    // Setup Auto-Dismiss Timer
    _timer = Timer(widget.duration, () => _dismiss());
  }

  Future<void> _dismiss() async {
    _timer?.cancel();
    await _controller.reverse();
    widget.onDismiss();
  }

  @override
  void dispose() {
    _controller.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Determine colors and icon based on type
    Color backgroundColor;
    IconData icon;
    Color iconColor = Colors.white;

    switch (widget.type) {
      case SnackBarType.success:
        backgroundColor = const Color(0xFF4CAF50); // Green
        icon = Icons.check_circle_outline;
        break;
      case SnackBarType.error:
        backgroundColor = const Color(0xFFF44336); // Red
        icon = Icons.error_outline;
        break;
      case SnackBarType.info:
      default:
        backgroundColor = const Color(0xFF323232); // Dark Grey
        icon = Icons.info_outline;
        break;
    }

    return Positioned(
      bottom: 24,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: SlideTransition(
          position: _offset,
          child: FadeTransition(
            opacity: _opacity,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(icon, color: iconColor),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.content,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: _dismiss,
                    borderRadius: BorderRadius.circular(20),
                    child: const Padding(
                      padding: EdgeInsets.all(4.0),
                      child: Icon(Icons.close, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
