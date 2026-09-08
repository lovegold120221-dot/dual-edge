import 'dart:async';
import 'dart:isolate';

/// Message channel between the UI isolate and a sherpa worker isolate.
///
/// sherpa decode/generate calls block for seconds on phone CPUs, so all
/// native handles live in the worker. Messages are plain maps with an `id`;
/// every call ends with exactly one message carrying `'end': true.
class SherpaWorker {
  SherpaWorker._(this._isolate, this._inbox);

  final Isolate _isolate;
  final ReceivePort _inbox;
  SendPort? _sendPortValue;
  final _pending = <int, StreamController<Map<String, Object?>>>{};
  StreamSubscription<dynamic>? _subscription;
  var _nextId = 0;
  var _disposed = false;

  static Future<SherpaWorker> spawn(
    FutureOr<void> Function(SendPort mainPort) entry,
  ) async {
    final inbox = ReceivePort();
    final isolate = await Isolate.spawn(entry, inbox.sendPort);
    final worker = SherpaWorker._(isolate, inbox);
    final completer = Completer<SendPort>();
    worker._subscription = inbox.listen((message) {
      if (!completer.isCompleted && message is SendPort) {
        completer.complete(message);
        return;
      }
      worker._route(message);
    });
    try {
      worker._sendPortValue = await completer.future.timeout(
        const Duration(seconds: 30),
      );
    } catch (e) {
      worker.dispose();
      rethrow;
    }
    return worker;
  }

  SendPort get _out {
    final port = _sendPortValue;
    if (port == null || _disposed) throw StateError('Worker not ready');
    return port;
  }

  void _route(dynamic message) {
    if (message is! Map) return;
    final id = (message['id'] is int) ? message['id'] as int : 0;
    final controller = _pending[id];
    if (controller == null || controller.isClosed) return;
    controller.add(Map<String, Object?>.from(message));
    if (message['end'] == true) {
      _pending.remove(id);
      controller.close();
    }
  }

  /// Stream of reply maps for [cmd]; the last one has `'end': true`.
  Stream<Map<String, Object?>> call(
    String cmd, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) {
    if (_disposed) throw StateError('Worker is disposed');
    final id = ++_nextId;
    final controller = StreamController<Map<String, Object?>>();
    _pending[id] = controller;
    _out.send(<String, Object?>{'id': id, 'cmd': cmd, ...args});
    return controller.stream;
  }

  /// Single terminal reply for [cmd]; throws on `ok: false`.
  Future<Map<String, Object?>> callOnce(
    String cmd, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) async {
    final reply = await call(cmd, args)
        .firstWhere((message) => message['end'] == true)
        .timeout(const Duration(minutes: 5));
    if (reply['ok'] == false) {
      throw StateError(reply['error']?.toString() ?? 'Worker call failed');
    }
    return reply;
  }

  /// Fire-and-forget (id 0, no reply expected).
  void notify(String cmd, [Map<String, Object?> args = const {}]) {
    if (_disposed) return;
    try {
      _out.send(<String, Object?>{'id': 0, 'cmd': cmd, ...args});
    } catch (_) {}
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _out.send(const <String, Object?>{'id': 0, 'cmd': 'dispose'});
    } catch (_) {}
    for (final controller in _pending.values) {
      try {
        controller.close();
      } catch (_) {}
    }
    _pending.clear();
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      try {
        _isolate.kill(priority: Isolate.immediate);
      } catch (_) {}
      try {
        _inbox.close();
      } catch (_) {}
    });
    try {
      _subscription?.cancel();
    } catch (_) {}
  }
}

/// Worker-side helper: handshake with main, then loop over [onMessage].
///
/// [onMessage] receives the inbound map and a reply function. Long-running
/// streaming calls (TTS audio) may invoke [reply] multiple times and must
/// finish with `'end': true`.
Future<void> serveWorker(
  SendPort mainPort,
  Future<void> Function(
    Map<String, Object?> message,
    void Function(Map<String, Object?> reply) reply,
  )
  onMessage,
) async {
  final inbox = ReceivePort();
  mainPort.send(inbox.sendPort);
  await for (final raw in inbox) {
    if (raw is! Map) continue;
    final message = Map<String, Object?>.from(raw);
    final id = (message['id'] is int) ? message['id'] as int : 0;
    if (message['cmd'] == 'dispose') {
      inbox.close();
      Isolate.exit();
    }
    void reply(Map<String, Object?> response) {
      try {
        mainPort.send(<String, Object?>{'id': id, ...response});
      } catch (_) {}
    }

    try {
      await onMessage(message, reply);
    } catch (e) {
      reply(<String, Object?>{'end': true, 'ok': false, 'error': '$e'});
    }
  }
}
