/// Flutter JS EJS solver implementation
/// Extends BaseEJSSolver to provide Flutter JS-specific JavaScript execution
library flutter_js_ejs_solver;

import 'base_ejs_solver.dart';
import 'ejs_builder.dart';
import 'flutter_js_stub.dart'
    if (dart.library.ui) 'flutter_js_flutter.dart'
    show getFlutterJsRuntime, evaluateFlutterJs;
import '../utils/logger.dart';

/// Flutter JS implementation of EJS solver
/// Uses flutter_js plugin to execute JavaScript without external dependencies
class FlutterJsEJSSolver extends BaseEJSSolver {
  dynamic _jsRuntime;
  bool _isInitialized = false;
  String? _baseScript; // Cached base script (lib + core)

  FlutterJsEJSSolver({dynamic jsRuntime}) : _jsRuntime = jsRuntime {
    if (_jsRuntime == null) {
      _initializeJsRuntime();
    }
  }

  void _initializeJsRuntime() {
    try {
      _jsRuntime = getFlutterJsRuntime();
      if (_jsRuntime == null) {
        logger.debug('jsc', 'Flutter JS runtime not available (running in non-Flutter environment)');
      }
    } catch (e) {
      // In non-Flutter environment, getFlutterJsRuntime may throw UnimplementedError
      // This is expected and should be handled gracefully
      logger.debug('jsc', 'Flutter JS runtime not available: $e');
      _jsRuntime = null;
    }
  }

  /// Check if solver is available
  bool isAvailable() {
    return _jsRuntime != null;
  }

  /// Initialize the solver by loading JS modules
  Future<void> _ensureInitialized() async {
    if (_isInitialized && _baseScript != null) return;

    try {
      // Try to load from GitHub first (using EJSBuilder.getJSModules)
      try {
        final modules = await EJSBuilder.getJSModules();
        _baseScript = modules;
        _isInitialized = true;
        logger.info('jsc', 'Flutter JS EJS solver initialized (from GitHub)');
        return;
      } catch (e) {
        logger.warning('jsc', 'Could not load modules from GitHub: $e');
        logger.debug('jsc', 'Falling back to asset loading...');
        // Fallback to asset loading would go here if needed
        rethrow;
      }
    } catch (e) {
      logger.error('jsc', 'Failed to initialize Flutter JS EJS solver', e);
      rethrow;
    }
  }

  @override
  Future<String> executeJavaScript(String jsCall) async {
    if (_jsRuntime == null) {
      throw Exception('Flutter JS runtime is not available. '
          'This code is running in a non-Flutter environment. '
          'Please use Flutter JS provider only in Flutter apps.');
    }

    await _ensureInitialized();

    // Build complete script: base script + jsCall wrapped in IIFE
    final script = '''
(function() {
$_baseScript

// Execute the JS call and return result
try {
  const result = $jsCall;
  return result;
} catch (error) {
  const errorMsg = error instanceof Error ? error.message : String(error);
  const errorStack = error instanceof Error ? error.stack : '';
  return JSON.stringify({
    type: 'error',
    error: errorMsg + (errorStack ? '\\n' + errorStack : '')
  });
}
})();
''';

    try {
      final jsResult = await evaluateFlutterJs(_jsRuntime, script);
      
      // Extract string result from flutter_js JsEvalResult
      String resultJson;
      if (jsResult is String) {
        resultJson = jsResult;
      } else if (jsResult is Map) {
        resultJson = jsResult['stringResult']?.toString() ?? 
                     jsResult['result']?.toString() ?? 
                     jsResult.toString();
      } else {
        // Try dynamic property access
        try {
          final dynamicResult = jsResult as dynamic;
          resultJson = dynamicResult.stringResult?.toString() ?? 
                       dynamicResult.result?.toString() ?? 
                       jsResult.toString();
        } catch (e) {
          resultJson = jsResult.toString();
        }
      }

      return resultJson;
    } catch (e) {
      throw Exception('Failed to execute JavaScript: $e');
    }
  }

  @override
  void dispose() {
    // Flutter JS runtime cleanup if needed
    _jsRuntime = null;
    _baseScript = null;
    _isInitialized = false;
  }
}

