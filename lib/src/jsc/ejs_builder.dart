/// EJS (External JavaScript Solver) builder
/// Based on youtube_explode_dart's implementation
/// Builds JavaScript calls for signature and n-challenge solving
library ejs_builder;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'js_challenge.dart';
import 'ejs_modules.g.dart' as ejs;

String? _libCache;
String? _coreCache;

/// Builder for EJS JavaScript solver calls
/// This class handles building the JavaScript code that calls the yt-dlp/ejs solver
abstract class EJSBuilder {
  /// Build the JavaScript call string for solving challenges
  /// 
  /// [playerScript] - The YouTube player JavaScript code
  /// [requests] - Map of challenge types to lists of challenge strings
  /// [isPreprocessed] - Whether the player script is already preprocessed
  /// 
  /// Returns a JavaScript expression string that can be evaluated
  /// Format: `JSON.stringify(jsc({...input...}))`
  static String buildJSCall(
    String playerScript,
    Map<JSChallengeType, List<String>> requests, {
    bool isPreprocessed = false,
  }) {
    // Build requests array matching yt-dlp format
    final encodedRequests = [
      for (final entry in requests.entries)
        {
          'type': entry.key.name, // 'n' or 'sig'
          'challenges': entry.value,
        }
    ];

    // Build input object matching yt-dlp format
    late Map<String, dynamic> input;
    if (isPreprocessed) {
      input = {
        'type': 'preprocessed',
        'preprocessed_player': playerScript,
        'requests': encodedRequests,
      };
    } else {
      input = {
        'type': 'player',
        'player': playerScript,
        'requests': encodedRequests,
        'output_preprocessed': true,
      };
    }

    // Return JavaScript expression that calls jsc and stringifies the result
    // This matches youtube_explode_dart's format: JSON.stringify(jsc({...}))
    return 'JSON.stringify(jsc(${json.encode(input)}))';
  }

  /// Build the complete script including lib and core modules
  /// 
  /// [libScript] - The lib script (meriyah + astring)
  /// [coreScript] - The core solver script (yt.solver.core.js)
  /// 
  /// Returns the complete script ready to execute
  static String _buildScript(String lib, String core) {
    return '''
$lib
Object.assign(globalThis, lib);
$core

''';
  }

  /// Get JS modules from GitHub releases (with hash verification)
  /// This downloads the lib and core modules from yt-dlp/ejs releases
  /// and verifies their integrity using SHA256 hashes
  static Future<String> getJSModules() async {
    if (_libCache != null && _coreCache != null) {
      return _buildScript(_libCache!, _coreCache!);
    }

    final lib = ejs.modules['lib']!;
    final core = ejs.modules['core']!;

    // Download and verify lib module
    final libReq = await http.get(Uri.parse(lib['url']!));
    final libHash = sha256.convert(libReq.bodyBytes).toString();
    if (libHash != lib['hash']) {
      throw Exception('Lib module hash mismatch. Expected: ${lib['hash']}, Got: $libHash');
    }

    // Download and verify core module
    final coreReq = await http.get(Uri.parse(core['url']!));
    final coreHash = sha256.convert(coreReq.bodyBytes).toString();
    if (coreHash != core['hash']) {
      throw Exception('Core module hash mismatch. Expected: ${core['hash']}, Got: $coreHash');
    }

    _libCache = libReq.body;
    _coreCache = coreReq.body;

    return _buildScript(_libCache!, _coreCache!);
  }
}

