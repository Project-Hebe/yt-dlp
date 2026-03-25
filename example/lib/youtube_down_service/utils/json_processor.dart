import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

/// Commands to be executed by the background isolate
sealed class _JsonCommand {
  final int id;
  const _JsonCommand(this.id);
}

class _EncodeCommand extends _JsonCommand {
  final dynamic data;
  const _EncodeCommand(super.id, this.data);
}

class _DecodeCommand extends _JsonCommand {
  final String jsonString;
  const _DecodeCommand(super.id, this.jsonString);
}

/// Response from the isolate
class _JsonResponse {
  final int id;
  final dynamic result;
  final Object? error;

  _JsonResponse(this.id, this.result, this.error);
}

/// Singleton object that manages a background isolate for JSON encoding/decoding
///
/// This class moves JSON operations to a separate isolate to avoid blocking
/// the main UI thread, especially when processing large objects or frequent updates.
class JsonProcessor {
  static final JsonProcessor _instance = JsonProcessor._internal();

  factory JsonProcessor() => _instance;

  JsonProcessor._internal();

  Isolate? _isolate;
  SendPort? _sendPort;
  final Map<int, Completer<dynamic>> _pendingCompleters = {};
  Timer? _shutdownTimer;
  int _nextId = 0;
  bool _isStarting = false;
  Completer<void>? _startCompleter;

  /// Encode an object to JSON string in isolate
  Future<String> encode(dynamic object) async {
    return await _process<String>((id) => _EncodeCommand(id, object));
  }

  /// Decode a JSON string to Map in isolate
  Future<Map<String, dynamic>> decode(String jsonString) async {
    return await _process<Map<String, dynamic>>((id) => _DecodeCommand(id, jsonString));
  }

  /// Internal processing logic
  Future<T> _process<T>(_JsonCommand Function(int id) commandBuilder) async {
    await _ensureStarted();
    _resetShutdownTimer();

    final id = _nextId++;
    final completer = Completer<T>();
    _pendingCompleters[id] = completer;

    final command = commandBuilder(id);
    _sendPort!.send(command);

    try {
      final result = await completer.future;
      return result;
    } catch (e) {
      rethrow;
    } finally {
      _resetShutdownTimer(); // Reset timer on completion too
    }
  }

  Future<void> _ensureStarted() async {
    if (_isolate != null && _sendPort != null) return;

    if (_isStarting) {
      await _startCompleter!.future;
      return;
    }

    _isStarting = true;
    _startCompleter = Completer<void>();

    try {
      final receivePort = ReceivePort();
      _isolate = await Isolate.spawn(_isolateMain, receivePort.sendPort);

      // Wait for the isolate to send its SendPort
      _sendPort = await receivePort.first as SendPort;

      // Create a new receive port for responses
      final responsePort = ReceivePort();
      _sendPort!.send(responsePort.sendPort);

      responsePort.listen(_handleResponse);

      if (!_startCompleter!.isCompleted) {
        _startCompleter!.complete();
      }
    } catch (e) {
      _isolate?.kill();
      _isolate = null;
      _sendPort = null;
      _isStarting = false;
      if (!_startCompleter!.isCompleted) {
        _startCompleter!.completeError(e);
      }
      rethrow;
    } finally {
      _isStarting = false;
    }
  }

  void _handleResponse(dynamic message) {
    if (message is _JsonResponse) {
      final completer = _pendingCompleters.remove(message.id);
      if (completer != null) {
        if (message.error != null) {
          completer.completeError(message.error!);
        } else {
          completer.complete(message.result);
        }
      }
    }
  }

  void _resetShutdownTimer() {
    _shutdownTimer?.cancel();
    _shutdownTimer = Timer(const Duration(minutes: 1), _shutdown);
  }

  void _shutdown() {
    _isolate?.kill();
    _isolate = null;
    _sendPort = null;
    _shutdownTimer?.cancel();
    _shutdownTimer = null;

    // Fail any pending requests
    for (final completer in _pendingCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Background isolate shut down'));
      }
    }
    _pendingCompleters.clear();
  }

  /// Manually shutdown the isolate (usually not needed)
  void dispose() {
    _shutdown();
  }
}

/// Main function for the isolate
void _isolateMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  SendPort? replyPort;

  receivePort.listen((message) async {
    if (message is SendPort) {
      replyPort = message;
    } else if (message is _JsonCommand) {
      if (replyPort == null) {
        return; // Should not happen if protocol is followed
      }

      try {
        final result = await _executeCommand(message);
        replyPort!.send(_JsonResponse(message.id, result, null));
      } catch (e) {
        replyPort!.send(_JsonResponse(message.id, null, e));
      }
    }
  });
}

/// Execute the command in the isolate
Future<dynamic> _executeCommand(_JsonCommand command) async {
  switch (command) {
    case _EncodeCommand c:
      return jsonEncode(c.data);

    case _DecodeCommand c:
      return jsonDecode(c.jsonString) as Map<String, dynamic>;
  }
}
