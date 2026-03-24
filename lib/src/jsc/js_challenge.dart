/// JavaScript challenge types and base solver interface
/// Based on youtube_explode_dart's implementation
library js_challenge;

/// JavaScript challenge type (matches youtube_explode_dart)
enum JSChallengeType {
  n,
  sig,
}

/// Base class for JavaScript challenge solvers
/// Based on youtube_explode_dart's BaseJSChallengeSolver
abstract class BaseJSChallengeSolver {
  /// Solves JavaScript challenges in bulk.
  /// The [requests] parameter is a map where the key is the type of challenge
  /// and the value is a list of challenge strings to be solved.
  ///
  /// Returns a map where each challenge string maps to its solved result or null if unsolved.
  Future<Map<String, String?>> solveBulk(
    String playerUrl,
    Map<JSChallengeType, List<String>> requests,
  );

  /// Solves a single JavaScript challenge of the specified [type].
  /// Returns the solved challenge as a string.
  ///
  /// See [solveBulk] for bulk solving.
  Future<String> solve(
    String playerUrl,
    JSChallengeType type,
    String challenge,
  );

  void dispose() {}
}

