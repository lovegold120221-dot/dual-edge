import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/models/history_item.dart';

class PdfExportService {
  Future<void> export(List<HistoryItem> history) async {
    if (history.isEmpty) {
      throw StateError('No translation history to export.');
    }
    final document = pw.Document();
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Text(
              'Dual Translator Chat History',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            pw.Text('Exported on ${dateFormat.format(DateTime.now())}'),
            pw.Text('Powered by Eburon AI'),
            pw.SizedBox(height: 12),
          ],
        ),
        build: (context) => <pw.Widget>[
          pw.TableHelper.fromTextArray(
            headers: const <String>[
              'Time',
              'Languages',
              'Source',
              'Translation',
            ],
            data: history
                .map(
                  (item) => <String>[
                    dateFormat.format(item.timestamp),
                    '${item.language1} → ${item.language2}',
                    item.sourceText,
                    item.translatedText,
                  ],
                )
                .toList(),
            headerDecoration: const pw.BoxDecoration(
              color: PdfColor.fromInt(0xFF448DFF),
            ),
            headerStyle: pw.TextStyle(
              color: PdfColors.white,
              fontWeight: pw.FontWeight.bold,
            ),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellPadding: const pw.EdgeInsets.all(5),
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          ),
        ],
      ),
    );
    await Printing.sharePdf(
      bytes: await document.save(),
      filename: 'dual_translator_history.pdf',
    );
  }
}
