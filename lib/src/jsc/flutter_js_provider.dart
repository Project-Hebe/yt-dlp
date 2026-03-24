/// Flutter JS JavaScript challenge provider (for Flutter mobile apps)
/// Uses flutter_js plugin to execute JavaScript without external dependencies
/// 
/// NOTE: This requires flutter_js plugin to be added to pubspec.yaml:
///   dependencies:
///     flutter_js: ^0.3.2
library flutter_js_provider;

import 'js_challenge_provider.dart';
import 'challenge_types.dart';
import 'js_challenge.dart';
import 'flutter_js_ejs_solver.dart';
import '../utils/logger.dart';

// Conditional import: use Flutter implementation if available, otherwise use stub
// dart.library.ui is only available in Flutter environment
import 'flutter_js_stub.dart'
    if (dart.library.ui) 'flutter_js_flutter.dart'
    show getFlutterJsRuntime;

/// Flutter JS provider for solving JavaScript challenges
/// This provider automatically uses flutter_js in Flutter environment
/// 
/// Usage:
/// - Add flutter_js: ^0.3.2 to pubspec.yaml (in Flutter app)
/// - No additional code required - works automatically!
class FlutterJsChallengeProvider extends JsChallengeProvider {
  FlutterJsEJSSolver? _solver;
  dynamic _jsRuntime;

  FlutterJsChallengeProvider({
    dynamic jsRuntime, // Allow passing JS runtime from Flutter app
  }) : _jsRuntime = jsRuntime {
    _initializeJsRuntime();
  }

  void _initializeJsRuntime() {
    try {
      if (_jsRuntime == null) {
        _jsRuntime = getFlutterJsRuntime();
      }
      if (_jsRuntime != null) {
        _solver = FlutterJsEJSSolver(jsRuntime: _jsRuntime);
        logger.info('jsc', 'Flutter JS runtime initialized successfully');
      } else {
        logger.debug('jsc', 'Flutter JS runtime not available. '
            'This may be because: '
            '1. Running in non-Flutter environment (use QuickJS provider instead), or '
            '2. flutter_js: ^0.3.2 is not added to pubspec.yaml');
      }
    } catch (e) {
      // In non-Flutter environment, getFlutterJsRuntime may throw UnimplementedError
      // This is expected and should be handled gracefully
      logger.debug('jsc', 'Flutter JS runtime not available: $e');
      _solver = null;
    }
  }

  @override
  String get providerName => 'flutter_js';

  @override
  bool isAvailable() {
    return _solver != null && _solver!.isAvailable();
  }

  @override
  Future<List<JsChallengeProviderResponse>> bulkSolve(
    List<JsChallengeRequest> requests,
  ) async {
    if (!isAvailable()) {
      throw JsChallengeProviderRejectedRequest(
          'Flutter JS runtime is not available. '
          'Please initialize JS runtime in Flutter app.');
    }

    final solver = _solver!;

    // Group requests by player URL
    final grouped = <String, List<JsChallengeRequest>>{};
    for (final request in requests) {
      final playerUrl = request.type == JsChallengeType.sig
          ? (request.input as SigChallengeInput).playerUrl
          : (request.input as NChallengeInput).playerUrl;
      grouped.putIfAbsent(playerUrl, () => []).add(request);
    }

    final responses = <JsChallengeProviderResponse>[];

    for (final entry in grouped.entries) {
      final playerUrl = entry.key;
      final groupedRequests = entry.value;

      // Convert requests to BaseEJSSolver format
      final jsRequests = <JSChallengeType, List<String>>{};
      for (final request in groupedRequests) {
        final jsType = request.type == JsChallengeType.sig 
            ? JSChallengeType.sig 
            : JSChallengeType.n;
        final challenges = request.type == JsChallengeType.sig
            ? (request.input as SigChallengeInput).challenges
            : (request.input as NChallengeInput).challenges;
        
        jsRequests.putIfAbsent(jsType, () => []).addAll(challenges);
      }

      try {
        // Use BaseEJSSolver to solve (handles caching, parsing, etc.)
        final results = await solver.solveBulk(playerUrl, jsRequests);

        // Convert results back to JsChallengeProviderResponse format
        for (final request in groupedRequests) {
          final challenges = request.type == JsChallengeType.sig
              ? (request.input as SigChallengeInput).challenges
              : (request.input as NChallengeInput).challenges;

          final challengeResults = <String, String>{};
          for (final challenge in challenges) {
            final result = results[challenge];
            if (result != null) {
              challengeResults[challenge] = result;
            }
          }

          if (request.type == JsChallengeType.sig) {
            responses.add(JsChallengeProviderResponse(
              request: request,
              response: JsChallengeResponse(
                type: JsChallengeType.sig,
                output: SigChallengeOutput(results: challengeResults),
              ),
            ));
          } else {
            responses.add(JsChallengeProviderResponse(
              request: request,
              response: JsChallengeResponse(
                type: JsChallengeType.n,
                output: NChallengeOutput(results: challengeResults),
              ),
            ));
          }
        }
      } catch (e) {
        // Handle errors for all requests in this group
        for (final request in groupedRequests) {
          responses.add(JsChallengeProviderResponse(
            request: request,
            error: e is Exception
                ? e
                : JsChallengeProviderError(e.toString()),
          ));
        }
      }
    }

    return responses;
  }
}
