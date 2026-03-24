/// Stub for flutter_js integration (non-Flutter environment)
/// This file is used when running outside Flutter (pure Dart)
library flutter_js_stub;

/// Get Flutter JS runtime (stub for non-Flutter environment)
dynamic getFlutterJsRuntime() {
  // Stub implementation for non-Flutter environments
  return null;
}

/// Evaluate JavaScript code (stub for non-Flutter environment)
Future<dynamic> evaluateFlutterJs(dynamic jsRuntime, String script) async {
  // Stub implementation for non-Flutter environments
  throw UnimplementedError(
      'Flutter JS is only available in Flutter environment. '
      'This code is running in a non-Flutter context.');
}


