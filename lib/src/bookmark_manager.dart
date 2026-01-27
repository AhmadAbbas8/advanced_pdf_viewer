import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Model class representing a single bookmark
class PdfBookmark {
  final int page;
  final String name;

  const PdfBookmark({required this.page, required this.name});

  Map<String, dynamic> toJson() => {'page': page, 'name': name};

  factory PdfBookmark.fromJson(Map<String, dynamic> json) =>
      PdfBookmark(page: json['page'] as int, name: json['name'] as String);
}

/// Manages bookmark storage and retrieval for PDF documents
class BookmarkManager {
  static const String _storagePrefix = 'pdf_bookmarks_';
  static SharedPreferences? _prefs;

  /// Internal method to get the singleton instance of SharedPreferences
  Future<SharedPreferences> get _sharedPreferences async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// Generates a unique key for a PDF based on its source
  /// Uses URL for network PDFs and hash of bytes for byte PDFs
  static String generatePdfKey(String? url, Uint8List? bytes) {
    if (url != null && url.isNotEmpty) {
      // Use MD5 hash of URL
      final urlBytes = utf8.encode(url);
      final digest = md5.convert(urlBytes);
      return digest.toString();
    } else if (bytes != null && bytes.isNotEmpty) {
      // Use MD5 hash of first 1KB of data (or less if smaller)
      final sampleSize = bytes.length < 1024 ? bytes.length : 1024;
      final sample = bytes.sublist(0, sampleSize);
      final digest = md5.convert(sample);
      return digest.toString();
    }
    // Fallback to timestamp-based key (not ideal for persistence)
    return DateTime.now().millisecondsSinceEpoch.toString();
  }

  /// Saves a bookmark for a specific page in a PDF
  Future<void> saveBookmark(String pdfKey, int page, String name) async {
    final prefs = await _sharedPreferences;
    final storageKey = _storagePrefix + pdfKey;

    // Get existing bookmarks
    final bookmarks = await getBookmarks(pdfKey);

    // Remove existing bookmark for this page if any
    bookmarks.removeWhere((b) => b.page == page);

    // Add new bookmark
    bookmarks.add(PdfBookmark(page: page, name: name));

    // Sort by page number
    bookmarks.sort((a, b) => a.page.compareTo(b.page));

    // Save to storage
    final jsonList = bookmarks.map((b) => b.toJson()).toList();
    await prefs.setString(storageKey, jsonEncode(jsonList));
  }

  /// Removes a bookmark for a specific page
  Future<void> removeBookmark(String pdfKey, int page) async {
    final prefs = await _sharedPreferences;
    final storageKey = _storagePrefix + pdfKey;

    // Get existing bookmarks
    final bookmarks = await getBookmarks(pdfKey);

    // Remove bookmark for this page
    bookmarks.removeWhere((b) => b.page == page);

    // Save to storage
    final jsonList = bookmarks.map((b) => b.toJson()).toList();
    await prefs.setString(storageKey, jsonEncode(jsonList));
  }

  /// Gets all bookmarks for a PDF
  Future<List<PdfBookmark>> getBookmarks(String pdfKey) async {
    final prefs = await _sharedPreferences;
    final storageKey = _storagePrefix + pdfKey;

    final jsonString = prefs.getString(storageKey);
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }

    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList
          .map((json) => PdfBookmark.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // If parsing fails, return empty list
      return [];
    }
  }

  /// Checks if a specific page is bookmarked
  Future<bool> isBookmarked(String pdfKey, int page) async {
    final bookmarks = await getBookmarks(pdfKey);
    return bookmarks.any((b) => b.page == page);
  }

  /// Clears all bookmarks for a PDF
  Future<void> clearAllBookmarks(String pdfKey) async {
    final prefs = await _sharedPreferences;
    final storageKey = _storagePrefix + pdfKey;
    await prefs.remove(storageKey);
  }
}
