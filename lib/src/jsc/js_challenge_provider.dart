/// JavaScript challenge provider interface
library js_challenge_provider;

import 'challenge_types.dart';

/// Exception thrown when JS challenge provider rejects a request
class JsChallengeProviderRejectedRequest implements Exception {
  final String message;
  final bool expected;

  JsChallengeProviderRejectedRequest(this.message, {this.expected = false});

  @override
  String toString() => message;
}

/// Exception thrown when JS challenge provider encounters an error
class JsChallengeProviderError implements Exception {
  final String message;
  final bool expected;

  JsChallengeProviderError(this.message, {this.expected = false});

  @override
  String toString() => message;
}

/// JavaScript challenge provider response
class JsChallengeProviderResponse {
  final JsChallengeRequest request;
  final JsChallengeResponse? response;
  final Exception? error;

  JsChallengeProviderResponse({
    required this.request,
    this.response,
    this.error,
  });
}

/// Abstract base class for JavaScript challenge providers
abstract class JsChallengeProvider {
  /// Provider name
  String get providerName;

  /// Check if provider is available
  bool isAvailable();

  /// Solve JavaScript challenges in bulk
  Future<List<JsChallengeProviderResponse>> bulkSolve(
    List<JsChallengeRequest> requests,
  );
}

