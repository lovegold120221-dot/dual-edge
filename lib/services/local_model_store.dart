import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../data/sherpa_speech_assets.dart';

/// Per-file + aggregate progress for model downloads.
class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.fileIndex,
    required this.fileCount,
    required this.fileName,
    required this.fileFraction,
    required this.overallFraction,
    required this.downloadedBytes,
    required this.totalBytes,
  });

  final int fileIndex;
  final int fileCount;
  final String fileName;

  /// 0..1 for the current file, -1 when the size is unknown.
  final double fileFraction;

  /// 0..1 across all files, -1 when sizes are unknown.
  final double overallFraction;
  final int downloadedBytes;
  final int totalBytes;
}

/// Pure-Dart resumable model downloader (phones have no curl binary).
///
/// Files land atomically (`*.partial` → rename) under Application
/// Support/models so interrupted downloads resume instead of restarting.
class LocalModelStore {
  LocalModelStore({this._client});

  HttpClient? _client;
  bool _closed = false;

  Future<Directory> modelsDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/models');
    await dir.create(recursive: true);
    return dir;
  }

  String _join(String a, String b) => '$a/$b';

  Future<File> _file(String relativePath) async {
    final dir = await modelsDir();
    return File(_join(dir.path, relativePath));
  }

  Future<bool> isPresent(ModelFileRef ref) async {
    try {
      final file = await _file(ref.relativePath);
      return await file.exists() && await file.length() > ref.minBytes;
    } catch (_) {
      return false;
    }
  }

  Future<bool> arePresent(List<ModelFileRef> files) async {
    for (final file in files) {
      if (!await isPresent(file)) return false;
    }
    return true;
  }

  /// Download every missing file, emitting aggregate progress.
  /// Already-valid files are skipped (idempotent).
  Stream<ModelDownloadProgress> ensureFiles(List<ModelFileRef> files) async* {
    final totals = await _probeTotals(files);
    var doneBytes = 0;
    final grandTotal = totals.fold<int>(0, (a, b) => a + (b < 0 ? 0 : b));
    final unknown = grandTotal <= 0;

    for (var i = 0; i < files.length; i++) {
      final ref = files[i];
      if (await isPresent(ref)) {
        final size = totals[i] > 0 ? totals[i] : 0;
        doneBytes += size;
        yield ModelDownloadProgress(
          fileIndex: i,
          fileCount: files.length,
          fileName: _baseName(ref.relativePath),
          fileFraction: 1,
          overallFraction: unknown ? -1 : (doneBytes / grandTotal).clamp(0, 1),
          downloadedBytes: doneBytes,
          totalBytes: grandTotal,
        );
        continue;
      }
      final fileTotal = totals[i];
      await for (final event in _downloadOne(ref, i, files.length)) {
        final frac = event.fileFraction;
        final overall = unknown || fileTotal <= 0
            ? -1.0
            : ((doneBytes + frac * fileTotal) / grandTotal).clamp(0.0, 1.0);
        yield ModelDownloadProgress(
          fileIndex: i,
          fileCount: files.length,
          fileName: _baseName(ref.relativePath),
          fileFraction: frac,
          overallFraction: overall,
          downloadedBytes: doneBytes + event.downloadedBytes,
          totalBytes: grandTotal,
        );
      }
      doneBytes += fileTotal > 0 ? fileTotal : 0;
      if (!await isPresent(ref)) {
        throw StateError(
          'Downloaded file failed validation: ${ref.relativePath}',
        );
      }
    }
  }

  /// Best-effort total sizes (HEAD, then 0-byte Range). -1 when unknown.
  Future<List<int>> _probeTotals(List<ModelFileRef> files) async {
    final out = <int>[];
    for (final ref in files) {
      out.add(await _probeTotal(ref.url));
    }
    return out;
  }

  Future<int> _probeTotal(String url) async {
    final client = _http();
    try {
      final head = await client
          .headUrl(Uri.parse(url))
          .then((r) => r.close())
          .timeout(const Duration(seconds: 15));
      await head.drain<void>();
      if (head.statusCode >= 200 &&
          head.statusCode < 300 &&
          head.contentLength > 0) {
        return head.contentLength;
      }
    } catch (_) {}
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Range', 'bytes=0-0');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final range = response.headers.value('content-range');
      await response.drain<void>();
      if (range != null) {
        final total = int.tryParse(range.split('/').last.trim());
        if (total != null && total > 0) return total;
      }
      if (response.contentLength > 0) return response.contentLength;
    } catch (_) {}
    return -1;
  }

  Stream<_FileEvent> _downloadOne(
    ModelFileRef ref,
    int index,
    int count,
  ) async* {
    final target = await _file(ref.relativePath);
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.partial');
    var offset = 0;
    if (await partial.exists()) {
      offset = await partial.length();
    }
    final client = _http();
    final request = await client.getUrl(Uri.parse(ref.url));
    if (offset > 0) {
      request.headers.set('Range', 'bytes=$offset-');
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    final resumed =
        offset > 0 && response.statusCode == HttpStatus.partialContent;
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw HttpException(
        'Download failed (${response.statusCode}): ${ref.url}',
      );
    }
    final mode = resumed ? FileMode.append : FileMode.write;
    if (!resumed) offset = 0;
    final sink = partial.openWrite(mode: mode);
    var received = offset;
    final declared = response.contentLength;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        final frac = declared > 0
            ? (received / (resumed ? offset + declared : declared)).clamp(
                0.0,
                1.0,
              )
            : -1.0;
        yield _FileEvent(fileFraction: frac, downloadedBytes: received);
      }
      await sink.flush();
      await sink.close();
      if (await partial.length() <= ref.minBytes) {
        throw StateError('Download too small, likely truncated: ${ref.url}');
      }
      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      await partial.rename(target.path);
      yield _FileEvent(fileFraction: 1, downloadedBytes: received);
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow;
    }
  }

  /// Download [zip] (if needed) and unzip into [targetDirName].
  /// Skips work when [markerFileName] exists inside the target dir.
  Future<Directory> ensureUnzipped({
    required ModelFileRef zip,
    required String targetDirName,
    String markerFileName = '.extracted',
  }) async {
    final dir = await modelsDir();
    final target = Directory(_join(dir.path, targetDirName));
    final marker = File(_join(target.path, markerFileName));
    if (await marker.exists()) return target;
    await for (final _ in ensureFiles(<ModelFileRef>[zip])) {}
    final zipFile = await _file(zip.relativePath);
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    await _writeArchiveEntries(target, archive);
    await marker.writeAsString(DateTime.now().toIso8601String(), flush: true);
    if (kDebugMode) {
      debugPrint('LocalModelStore: extracted ${zip.relativePath}');
    }
    return target;
  }

  /// Download a `.tar.bz2` bundle (sherpa Piper voices) and extract it.
  /// A uniform top-level dir inside the archive is stripped so [targetDirName]
  /// directly contains the model files.
  Future<Directory> ensureTarBz2({
    required ModelFileRef bundle,
    required String targetDirName,
    String markerFileName = '.extracted',
  }) async {
    final dir = await modelsDir();
    final target = Directory(_join(dir.path, targetDirName));
    final marker = File(_join(target.path, markerFileName));
    if (await marker.exists()) return target;
    await for (final _ in ensureFiles(<ModelFileRef>[bundle])) {}
    final file = await _file(bundle.relativePath);
    final compressed = await file.readAsBytes();
    // Transient ~3x memory of the bundle size; released after extraction.
    final tarBytes = BZip2Decoder().decodeBytes(compressed);
    final archive = TarDecoder().decodeBytes(tarBytes);
    await _writeArchiveEntries(target, archive, stripTopLevelDir: true);
    await marker.writeAsString(DateTime.now().toIso8601String(), flush: true);
    if (kDebugMode) {
      debugPrint('LocalModelStore: extracted ${bundle.relativePath}');
    }
    return target;
  }

  Future<void> _writeArchiveEntries(
    Directory target,
    Archive archive, {
    bool stripTopLevelDir = false,
  }) async {
    var prefix = '';
    if (stripTopLevelDir) {
      final tops = archive.files
          .map((e) => e.name.split('/').first)
          .where((s) => s.isNotEmpty)
          .toSet();
      if (tops.length == 1) prefix = '${tops.single}/';
    }
    await target.create(recursive: true);
    for (final entry in archive) {
      if (!entry.isFile) continue;
      var name = entry.name;
      if (prefix.isNotEmpty && name.startsWith(prefix)) {
        name = name.substring(prefix.length);
      }
      if (name.isEmpty) continue;
      final out = File(_join(target.path, name));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(entry.content as List<int>, flush: true);
    }
  }

  HttpClient _http() {
    if (_closed) throw StateError('LocalModelStore is closed');
    return _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'eburon-translator/1.0';
  }

  static String _baseName(String path) {
    final index = path.lastIndexOf('/');
    return index < 0 ? path : path.substring(index + 1);
  }

  Future<void> dispose() async {
    _closed = true;
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }
}

class _FileEvent {
  const _FileEvent({required this.fileFraction, required this.downloadedBytes});

  final double fileFraction;
  final int downloadedBytes;
}
