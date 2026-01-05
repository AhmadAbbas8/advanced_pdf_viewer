import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:advanced_pdf_viewer/advanced_pdf_viewer.dart';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MaterialApp(home: MyApp()));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String? _url;
  Uint8List? _bytes;
  final AdvancedPdfViewerController _controller = AdvancedPdfViewerController();
  String _currentTool = 'none';

  Future<void> _loadNetworkPdf() async {
    setState(() {
      _bytes = null;
      _url =
          'https://pdftron.s3.amazonaws.com/downloads/pl/PDFTRON_mobile_about.pdf';
    });
  }

  Future<void> _loadBytesPdf() async {
    // For demo, we'll download it first and then use bytes
    final response = await http.get(
      Uri.parse(
        'https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf',
      ),
    );
    setState(() {
      _url = null;
      // _bytes = response.bodyBytes;
    });
  }

  Future<void> _savePdf() async {
    final data = await _controller.savePdf();
   setState(() {
     
   _bytes = Uint8List.fromList(data!);
    });
    if (data != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PDF Saved! Data length: ${data.length}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Advanced PDF Viewer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_download),
            onPressed: _loadNetworkPdf,
            tooltip: 'Load Network PDF',
          ),
          IconButton(
            icon: const Icon(Icons.data_object),
            onPressed: _loadBytesPdf,
            tooltip: 'Load Bytes PDF',
          ),
          if (_url != null || _bytes != null) ...[
            IconButton(
              icon: Icon(
                Icons.edit,
                color: _currentTool == 'draw' ? Colors.blue : null,
              ),
              onPressed: () {
                setState(() => _currentTool = 'draw');
                _controller.setDrawingMode('draw');
              },
            ),
            IconButton(
              icon: Icon(
                Icons.brush,
                color: _currentTool == 'highlight' ? Colors.blue : null,
              ),
              onPressed: () {
                setState(() => _currentTool = 'highlight');
                _controller.setDrawingMode('highlight');
              },
            ),
            IconButton(
              icon: Icon(
                Icons.format_underlined,
                color: _currentTool == 'underline' ? Colors.blue : null,
              ),
              onPressed: () {
                setState(() => _currentTool = 'underline');
                _controller.setDrawingMode('underline');
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: () => _controller.clearAnnotations(),
            ),
            IconButton(icon: const Icon(Icons.save), onPressed: _savePdf),
          ],
        ],
      ),
      body: _url == null && _bytes == null
          ? const Center(child: Text('Pick a source to load PDF'))
          : Column(
              children: [
                Expanded(
                  child: _url != null
                      ? AdvancedPdfViewer.network(
                          _url!,
                          controller: _controller,
                          key: ValueKey(_url),
                        )
                      : AdvancedPdfViewer.bytes(
                          _bytes!,
                          controller: _controller,
                          key: ValueKey(_bytes.hashCode),
                        ),
                ),
              ],
            ),
    );
  }
}
