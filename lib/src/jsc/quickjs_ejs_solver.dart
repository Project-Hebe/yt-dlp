/// QuickJS EJS solver implementation
/// Extends BaseEJSSolver to provide QuickJS-specific JavaScript execution
library quickjs_ejs_solver;

import 'dart:io';
import 'dart:convert';
import 'base_ejs_solver.dart';
import 'ejs_builder.dart';

/// QuickJS implementation of EJS solver
/// Uses QuickJS executable to execute JavaScript
class QuickJsEJSSolver extends BaseEJSSolver {
  final String? _quickjsPath;

  QuickJsEJSSolver({String? quickjsPath})
      : _quickjsPath = quickjsPath ?? _findQuickJsPath();

  static String? _findQuickJsPath() {
    // Try common QuickJS executable names
    final possibleNames = ['qjs', 'quickjs', 'qjsc'];
    for (final name in possibleNames) {
      try {
        final result = Process.runSync('which', [name]);
        if (result.exitCode == 0) {
          return result.stdout.toString().trim();
        }
      } catch (e) {
        // Continue searching
      }
    }
    return null;
  }

  /// Check if solver is available
  bool isAvailable() {
    if (_quickjsPath == null) {
      return false;
    }
    try {
      final result = Process.runSync(_quickjsPath!, ['--version']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<String> executeJavaScript(String jsCall) async {
    if (_quickjsPath == null) {
      throw Exception('QuickJS is not available. '
          'Please install QuickJS to enable signature decryption. '
          'Download from: https://bellard.org/quickjs/');
    }

    // Load JS modules (lib + core)
    final modules = await EJSBuilder.getJSModules();

    // Build complete script: modules + jsCall
    final script = '''
$modules

// Execute the JS call and return result
try {
  const result = $jsCall;
  print(JSON.stringify(result));
} catch (error) {
  const errorMsg = error instanceof Error ? error.message : String(error);
  const errorStack = error instanceof Error ? error.stack : '';
  print(JSON.stringify({
    type: 'error',
    error: errorMsg + (errorStack ? '\\n' + errorStack : '')
  }));
}
''';

    // QuickJS doesn't support reading from stdin, so we use a temp file
    final tempFile = File(
        '${Directory.systemTemp.path}/yt_dlp_${DateTime.now().millisecondsSinceEpoch}.js');
    try {
      await tempFile.writeAsString(script);

      // Execute with QuickJS
      final process = await Process.start(
        _quickjsPath!,
        ['--script', tempFile.path],
        mode: ProcessStartMode.normal,
      );

      final stdout = await process.stdout.transform(utf8.decoder).join();
      final stderr = await process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode;

      // Clean up temp file
      try {
        await tempFile.delete();
      } catch (e) {
        // Ignore cleanup errors
      }

      if (exitCode != 0) {
        throw Exception(
            'QuickJS execution failed with exit code $exitCode. stderr: $stderr');
      }

      // QuickJS outputs JSON to stdout
      final resultJson = stdout.trim();
      if (resultJson.isEmpty) {
        throw Exception('QuickJS returned empty output');
      }

      return resultJson;
    } catch (e) {
      // Clean up temp file on error
      try {
        await tempFile.delete();
      } catch (_) {
        // Ignore cleanup errors
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    // QuickJS doesn't need cleanup
  }
}

