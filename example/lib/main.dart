import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:advanced_pdf_viewer/advanced_pdf_viewer.dart';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

void main() {
  runApp(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const MyApp(),
    ),
  );
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

  Future<void> _loadNetworkPdf() async {
    setState(() {
      _bytes = null;
      _url =
          'https://easy.easy-stream.net/pdfs/5bbc9de8-2085-4874-bdb1-005533269a5c.pdf';
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
    if (data != null) {
      setState(() {
        _bytes = Uint8List.fromList(data);
        _url = null; // Switch to displaying bytes
      });
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
              icon: const Icon(Icons.save),
              onPressed: _savePdf,
              tooltip: 'Save PDF',
            ),
          ],
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'text',
            onPressed: () async {
              await _controller.addTextAnnotation(
                "Programmatic Text",
                100.0,
                200.0,
                0, // pageIndex
                color: Colors.purple,
              );
            },
            tooltip: 'Add Programmatic Text',
            child: const Icon(Icons.text_fields),
          ),
          const SizedBox(height: 10),
          FloatingActionButton(
            heroTag: 'page',
            onPressed: () async {
              final total = await _controller.getTotalPages();
              log("Total pages: $total");
              if (total > 0) {
                await _controller.jumpToPage(1);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Jumped to last page of $total')),
                  );
                }
              }
            },
            tooltip: 'Jump to Last Page',
            child: const Icon(Icons.last_page),
          ),
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
                          config: PdfViewerConfig(
                            showTextButton: false,
                            drawColor: Colors.red,
                            allowFullScreen: false,
                            showZoomButtons: false,
                            toolbarColor: Colors.white,
                            onFullScreenInit: () {
                              log('full screen initialized');
                            },
                            highlightColor: Color(
                              0x8000FF00,
                            ), // Semi-transparent green
                          ),
                        )
                      : AdvancedPdfViewer.bytes(
                          _bytes!,
                          controller: _controller,

                          key: ValueKey(_bytes.hashCode),
                          config: PdfViewerConfig(
                            showTextButton: false,
                            drawColor: Colors.red,
                            allowFullScreen: false,
                            showZoomButtons: false,

                            onFullScreenInit: () {
                              print("Entered full screen!");
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}
