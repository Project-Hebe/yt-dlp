/// QuickJS JavaScript challenge provider (lightweight, no npm dependencies)
library quickjs_provider;

import 'js_challenge_provider.dart';
import 'challenge_types.dart';
import 'js_challenge.dart';
import 'quickjs_ejs_solver.dart';
import '../utils/logger.dart';

/// QuickJS provider for solving JavaScript challenges
/// QuickJS is a lightweight JavaScript engine that doesn't require npm packages
class QuickJsChallengeProvider extends JsChallengeProvider {
  QuickJsEJSSolver? _solver;

  QuickJsChallengeProvider({String? quickjsPath}) {
    _initializeSolver(quickjsPath);
  }

  void _initializeSolver(String? quickjsPath) {
    try {
      _solver = QuickJsEJSSolver(quickjsPath: quickjsPath);
      if (_solver!.isAvailable()) {
        logger.info('jsc', 'QuickJS solver initialized successfully');
      } else {
        logger.debug('jsc', 'QuickJS solver not available (QuickJS not found). '
            'Install from: https://bellard.org/quickjs/');
        _solver = null;
      }
    } catch (e) {
      logger.warning('jsc', 'QuickJS solver failed to initialize: $e');
      _solver = null;
    }
  }

  @override
  String get providerName => 'quickjs';

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
          'QuickJS is not available. Please install QuickJS to enable signature decryption. '
          'Download from: https://bellard.org/quickjs/');
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
