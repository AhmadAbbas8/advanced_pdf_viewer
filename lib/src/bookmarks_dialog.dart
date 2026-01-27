import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'bookmark_manager.dart';
import 'pdf_localizations.dart';

/// Shows an adaptive dialog to display and manage PDF bookmarks
Future<int?> showBookmarksDialog({
  required BuildContext context,
  required List<PdfBookmark> bookmarks,
  required Function(int page) onRemoveBookmark,
  required PdfLocalizations localizations,
}) async {
  if (Platform.isIOS) {
    return showCupertinoDialog<int>(
      context: context,
      builder: (context) => _CupertinoBookmarksDialog(
        bookmarks: bookmarks,
        onRemoveBookmark: onRemoveBookmark,
        localizations: localizations,
      ),
    );
  } else {
    return showDialog<int>(
      context: context,
      builder: (context) => _MaterialBookmarksDialog(
        bookmarks: bookmarks,
        onRemoveBookmark: onRemoveBookmark,
        localizations: localizations,
      ),
    );
  }
}

/// Material Design bookmarks dialog for Android
class _MaterialBookmarksDialog extends StatefulWidget {
  final List<PdfBookmark> bookmarks;
  final Function(int page) onRemoveBookmark;
  final PdfLocalizations localizations;

  const _MaterialBookmarksDialog({
    required this.bookmarks,
    required this.onRemoveBookmark,
    required this.localizations,
  });

  @override
  State<_MaterialBookmarksDialog> createState() =>
      _MaterialBookmarksDialogState();
}

class _MaterialBookmarksDialogState extends State<_MaterialBookmarksDialog> {
  late List<PdfBookmark> _bookmarks;

  @override
  void initState() {
    super.initState();
    _bookmarks = List.from(widget.bookmarks);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = widget.localizations;

    return AlertDialog(
      title: Text(localizations.bookmarks),
      content: _bookmarks.isEmpty
          ? SizedBox(
              height: 100,
              child: Center(child: Text(localizations.noBookmarksYet)),
            )
          : SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _bookmarks.length,
                itemBuilder: (context, index) {
                  final bookmark = _bookmarks[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Text('${bookmark.page + 1}'),
                      ),
                      title: Text(bookmark.name),
                      subtitle: Text(localizations.pageNumber(bookmark.page)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () {
                          setState(() {
                            _bookmarks.removeAt(index);
                          });
                          widget.onRemoveBookmark(bookmark.page);
                        },
                      ),
                      onTap: () => Navigator.of(context).pop(bookmark.page),
                    ),
                  );
                },
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(localizations.close),
        ),
      ],
    );
  }
}

/// Cupertino Design bookmarks dialog for iOS
class _CupertinoBookmarksDialog extends StatefulWidget {
  final List<PdfBookmark> bookmarks;
  final Function(int page) onRemoveBookmark;
  final PdfLocalizations localizations;

  const _CupertinoBookmarksDialog({
    required this.bookmarks,
    required this.onRemoveBookmark,
    required this.localizations,
  });

  @override
  State<_CupertinoBookmarksDialog> createState() =>
      _CupertinoBookmarksDialogState();
}

class _CupertinoBookmarksDialogState extends State<_CupertinoBookmarksDialog> {
  late List<PdfBookmark> _bookmarks;

  @override
  void initState() {
    super.initState();
    _bookmarks = List.from(widget.bookmarks);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = widget.localizations;

    return CupertinoAlertDialog(
      title: Text(localizations.bookmarks),
      content: _bookmarks.isEmpty
          ? Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(localizations.noBookmarksYet),
            )
          : Container(
              margin: const EdgeInsets.only(top: 16),
              height: 300,
              child: CupertinoScrollbar(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _bookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = _bookmarks[index];
                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        border: Border.all(color: CupertinoColors.systemGrey4),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: CupertinoListTile(
                        leading: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: CupertinoColors.systemBlue,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Center(
                            child: Text(
                              '${bookmark.page + 1}',
                              style: const TextStyle(
                                color: CupertinoColors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        title: Text(bookmark.name),
                        subtitle: Text(localizations.pageNumber(bookmark.page)),
                        trailing: CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            setState(() {
                              _bookmarks.removeAt(index);
                            });
                            widget.onRemoveBookmark(bookmark.page);
                          },
                          child: const Icon(
                            CupertinoIcons.delete,
                            color: CupertinoColors.destructiveRed,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(bookmark.page),
                      ),
                    );
                  },
                ),
              ),
            ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(localizations.close),
        ),
      ],
    );
  }
}
