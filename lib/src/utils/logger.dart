/// Unified logging system for yt-dlp-dart
library logger;

import 'dart:io';

/// Check if ANSI colors are supported
/// In Flutter, ANSI colors are not well supported in console output
/// and may appear as escape sequences (e.g., \^[[32m)
/// Default to false to avoid display issues in Flutter
bool _supportsAnsiColors() {
  // Check if stdout supports ANSI colors
  // In Flutter, stdout may not be a terminal, so colors won't work
  try {
    if (stdout.hasTerminal) {
      // Check environment variable for color support
      final noColor = Platform.environment['NO_COLOR'];
      if (noColor != null && noColor.isNotEmpty) {
        return false;
      }
      
      // For Flutter compatibility, default to false
      // Users can enable colors explicitly if needed
      return false;
    }
  } catch (e) {
    // If we can't check, assume no color support (safer for Flutter)
  }
  
  return false; // Default to false for Flutter compatibility
}

/// Log levels
enum LogLevel {
  debug(0),
  info(1),
  warning(2),
  error(3),
  none(4); // Disable all logging

  final int value;
  const LogLevel(this.value);

  bool operator >=(LogLevel other) => value >= other.value;
  bool operator <=(LogLevel other) => value <= other.value;
}

/// Log handler interface
abstract class LogHandler {
  void handle(LogLevel level, String tag, String message, [Object? error, StackTrace? stackTrace]);
}

/// Console log handler (default)
class ConsoleLogHandler implements LogHandler {
  final bool useColors;
  final bool includeTimestamp;

  ConsoleLogHandler({
    bool? useColors,
    this.includeTimestamp = false,
  }) : useColors = useColors ?? _supportsAnsiColors();

  @override
  void handle(LogLevel level, String tag, String message, [Object? error, StackTrace? stackTrace]) {
    final buffer = StringBuffer();

    // Timestamp
    if (includeTimestamp) {
      final now = DateTime.now();
      buffer.write('[${now.toIso8601String()}] ');
    }

    // Level prefix
    final levelPrefix = _getLevelPrefix(level);
    buffer.write(levelPrefix);

    // Tag
    if (tag.isNotEmpty) {
      buffer.write('[$tag] ');
    }

    // Message
    buffer.write(message);

    // Error
    if (error != null) {
      buffer.write('\nError: $error');
    }

    // Stack trace
    if (stackTrace != null) {
      buffer.write('\n$stackTrace');
    }

    print(buffer.toString());
  }

  String _getLevelPrefix(LogLevel level) {
    if (!useColors) {
      switch (level) {
        case LogLevel.debug:
          return '[DEBUG] ';
        case LogLevel.info:
          return '[INFO] ';
        case LogLevel.warning:
          return '[WARNING] ';
        case LogLevel.error:
          return '[ERROR] ';
        case LogLevel.none:
          return '';
      }
    }

    // ANSI color codes
    switch (level) {
      case LogLevel.debug:
        return '\x1B[36m[DEBUG]\x1B[0m '; // Cyan
      case LogLevel.info:
        return '\x1B[32m[INFO]\x1B[0m '; // Green
      case LogLevel.warning:
        return '\x1B[33m[WARNING]\x1B[0m '; // Yellow
      case LogLevel.error:
        return '\x1B[31m[ERROR]\x1B[0m '; // Red
      case LogLevel.none:
        return '';
    }
  }
}

/// File log handler
class FileLogHandler implements LogHandler {
  final String filePath;
  final bool append;
  IOSink? _sink;

  FileLogHandler({
    required this.filePath,
    this.append = true,
  });

  @override
  void handle(LogLevel level, String tag, String message, [Object? error, StackTrace? stackTrace]) async {
    _sink ??= await _openFile();

    final buffer = StringBuffer();
    final now = DateTime.now();

    // Timestamp
    buffer.write('[${now.toIso8601String()}] ');

    // Level
    buffer.write('[${level.name.toUpperCase()}] ');

    // Tag
    if (tag.isNotEmpty) {
      buffer.write('[$tag] ');
    }

    // Message
    buffer.write(message);

    // Error
    if (error != null) {
      buffer.write('\nError: $error');
    }

    // Stack trace
    if (stackTrace != null) {
      buffer.write('\n$stackTrace');
    }

    buffer.write('\n');

    try {
      _sink!.write(buffer.toString());
      await _sink!.flush();
    } catch (e) {
      // If file writing fails, fall back to console
      print('[Logger] Failed to write to log file: $e');
    }
  }

  Future<IOSink> _openFile() async {
    final file = File(filePath);
    if (!append && await file.exists()) {
      await file.delete();
    }
    return file.openWrite(mode: append ? FileMode.append : FileMode.write);
  }

  /// Close the log file
  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}

/// Composite log handler (multiple handlers)
class CompositeLogHandler implements LogHandler {
  final List<LogHandler> handlers;

  CompositeLogHandler(this.handlers);

  @override
  void handle(LogLevel level, String tag, String message, [Object? error, StackTrace? stackTrace]) {
    for (final handler in handlers) {
      try {
        handler.handle(level, tag, message, error, stackTrace);
      } catch (e) {
        // Ignore handler errors to prevent logging failures from breaking the app
      }
    }
  }
}

/// Main logger class
class Logger {
  static Logger? _instance;
  LogLevel _level = LogLevel.info;
  LogHandler _handler = ConsoleLogHandler(useColors: false); // Disable colors by default for Flutter compatibility

  Logger._();

  /// Get singleton instance
  factory Logger.instance() {
    _instance ??= Logger._();
    return _instance!;
  }

  /// Set log level
  void setLevel(LogLevel level) {
    _level = level;
  }

  /// Get current log level
  LogLevel get level => _level;

  /// Set log handler
  void setHandler(LogHandler handler) {
    _handler = handler;
  }

  /// Add log handler (creates composite if needed)
  void addHandler(LogHandler handler) {
    if (_handler is CompositeLogHandler) {
      (_handler as CompositeLogHandler).handlers.add(handler);
    } else {
      _handler = CompositeLogHandler([_handler, handler]);
    }
  }

  /// Log debug message
  void debug(String tag, String message) {
    if (_level <= LogLevel.debug) {
      _handler.handle(LogLevel.debug, tag, message);
    }
  }

  /// Log info message
  void info(String tag, String message) {
    if (_level <= LogLevel.info) {
      _handler.handle(LogLevel.info, tag, message);
    }
  }

  /// Log warning message
  void warning(String tag, String message) {
    if (_level <= LogLevel.warning) {
      _handler.handle(LogLevel.warning, tag, message);
    }
  }

  /// Log error message
  void error(String tag, String message, [Object? error, StackTrace? stackTrace]) {
    if (_level <= LogLevel.error) {
      _handler.handle(LogLevel.error, tag, message, error, stackTrace);
    }
  }

  /// Convenience method for logging with automatic tag detection
  void log(LogLevel level, String message, {String? tag}) {
    final actualTag = tag ?? _getCallerTag();
    switch (level) {
      case LogLevel.debug:
        debug(actualTag, message);
        break;
      case LogLevel.info:
        info(actualTag, message);
        break;
      case LogLevel.warning:
        warning(actualTag, message);
        break;
      case LogLevel.error:
        error(actualTag, message);
        break;
      case LogLevel.none:
        break;
    }
  }

  /// Get caller tag from stack trace (simplified)
  String _getCallerTag() {
    try {
      final stack = StackTrace.current;
      final lines = stack.toString().split('\n');
      if (lines.length > 2) {
        final caller = lines[2];
        // Extract class/method name from stack trace
        final match = RegExp(r'(\w+)\.(\w+)').firstMatch(caller);
        if (match != null) {
          return '${match.group(1)}.${match.group(2)}';
        }
      }
    } catch (e) {
      // Ignore
    }
    return 'unknown';
  }
}

/// Global logger instance for convenience
final logger = Logger.instance();

