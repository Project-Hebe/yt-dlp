/// Flutter JS implementation for Flutter environment
/// This file is only imported when running in Flutter (dart.library.ui available)
///
/// NOTE: Linter errors here are expected when analyzing the library outside Flutter.
/// These imports are only resolved in Flutter apps that have flutter_js dependency.
library flutter_js_flutter;

// These imports are only available in Flutter environment
// ignore: uri_does_not_exist
import 'package:flutter_js/flutter_js.dart' as flutter_js;
import '../utils/logger.dart';

/// Get Flutter JS runtime
dynamic getFlutterJsRuntime() {
  try {
    return flutter_js.getJavascriptRuntime();
  } catch (e) {
    logger.debug('jsc', 'Failed to get Flutter JS runtime: $e');
    return null;
  }
}

/// Evaluate JavaScript code
dynamic evaluateFlutterJs(dynamic jsRuntime, String script) async {
  if (jsRuntime == null) {
    throw ArgumentError('JS runtime is null');
  }

  try {
    final result = await jsRuntime.evaluate(script);
    logger.debug('jsc', 'JavaScript evaluation result: $result');
    return result;
  } catch (e) {
    logger.error('jsc', 'Failed to evaluate JavaScript', e);
    rethrow;
  }
}

