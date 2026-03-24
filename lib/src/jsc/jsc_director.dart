/// JavaScript challenge director - manages challenge providers
library jsc_director;

import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'js_challenge_provider.dart';
import 'challenge_types.dart';
import 'quickjs_provider.dart';
import 'flutter_js_provider.dart';
import '../utils/logger.dart';

/// Director for managing JavaScript challenge providers
/// Supports multiple JS runtimes:
/// 1. Flutter JS (for mobile apps and web, no external dependencies)
/// 2. QuickJS (lightweight, no npm required)
class JscDirector {
  final List<JsChallengeProvider> _providers = [];

  JscDirector() {
    // Priority 1: Flutter JS (for mobile apps and web, embedded, no external dependencies)
    // Only try on mobile platforms (iOS/Android) or web
    // The FlutterJsChallengeProvider will handle checking if Flutter environment is available
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      try {
        final flutterJsProvider = FlutterJsChallengeProvider();
        if (flutterJsProvider.isAvailable()) {
          _providers.add(flutterJsProvider);
          logger.info('jsc', 'Flutter JS provider available (embedded, no external dependencies)');
        } else {
          logger.debug('jsc', 'Flutter JS provider not available (flutter_js plugin not working or not in Flutter environment)');
        }
      } catch (e) {
        logger.warning('jsc', 'Flutter JS provider failed to initialize: $e');
      }
    }
    
    // Priority 2: QuickJS (lightweight, no npm dependencies)
    // Only try on desktop platforms
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      final quickjsProvider = QuickJsChallengeProvider();
      if (quickjsProvider.isAvailable()) {
        _providers.add(quickjsProvider);
        logger.info('jsc', 'QuickJS provider available (lightweight, no npm required)');
      } else {
        logger.debug('jsc', 'QuickJS provider not available (QuickJS not found). '
            'Install from: https://bellard.org/quickjs/');
      }
    }
  }

  /// Check if any provider is available
  bool isAvailable() {
    return _providers.isNotEmpty;
  }

  /// Solve JavaScript challenges in bulk
  Future<List<JsChallengeProviderResponse>> bulkSolve(
    List<JsChallengeRequest> requests,
  ) async {
    if (_providers.isEmpty) {
      throw JsChallengeProviderRejectedRequest(
          'No JavaScript challenge providers available. '
          'Please install QuickJS or use Flutter JS provider (for mobile apps).');
    }

    // Try each provider until one succeeds
    for (final provider in _providers) {
      try {
        return await provider.bulkSolve(requests);
      } catch (e) {
        if (e is JsChallengeProviderRejectedRequest) {
          // Try next provider
          continue;
        }
        // Other errors - rethrow
        rethrow;
      }
    }

    throw JsChallengeProviderRejectedRequest(
        'All JavaScript challenge providers failed');
  }
}

