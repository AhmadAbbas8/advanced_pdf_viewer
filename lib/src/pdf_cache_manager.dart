import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:typed_data';

class PdfCacheManager {
  static Future<File> preparePdf({
    String? url,
    Uint8List? bytes,
    bool useCache = true,
  }) async {
    final tempDir = await getTemporaryDirectory();
    File file;

    if (url != null) {
      final hash = useCache
          ? md5.convert(utf8.encode(url)).toString()
          : '${DateTime.now().millisecondsSinceEpoch}_${md5.convert(utf8.encode(url)).toString()}';
      file = File('${tempDir.path}/$hash.pdf');
      if (!useCache || !await file.exists()) {
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          await file.writeAsBytes(response.bodyBytes);
        } else {
          throw Exception('Failed to download PDF: ${response.statusCode}');
        }
      }
    } else if (bytes != null) {
      final hash = md5.convert(bytes).toString();
      file = File('${tempDir.path}/$hash.pdf');
      if (!await file.exists()) {
        await file.writeAsBytes(bytes);
      }
    } else {
      throw Exception('No PDF source provided');
    }

    return file;
  }

  static Future<File> downloadToTemp(String url) async {
    final tempDir = await getTemporaryDirectory();
    final uniqueId = DateTime.now().millisecondsSinceEpoch.toString();
    final file = File('${tempDir.path}/temp_$uniqueId.pdf');

    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      await file.writeAsBytes(response.bodyBytes);
      return file;
    } else {
      throw Exception('Failed to download PDF: ${response.statusCode}');
    }
  }
}
