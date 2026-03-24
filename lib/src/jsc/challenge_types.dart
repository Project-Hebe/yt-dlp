/// JavaScript challenge types
enum JsChallengeType {
  n, // n challenge
  sig, // Signature challenge
}

/// N challenge input
class NChallengeInput {
  final String playerUrl;
  final List<String> challenges;

  NChallengeInput({
    required this.playerUrl,
    this.challenges = const [],
  });
}

/// Signature challenge input
class SigChallengeInput {
  final String playerUrl;
  final List<String> challenges;

  SigChallengeInput({
    required this.playerUrl,
    this.challenges = const [],
  });
}

/// N challenge output
class NChallengeOutput {
  final Map<String, String> results;

  NChallengeOutput({this.results = const {}});
}

/// Signature challenge output
class SigChallengeOutput {
  final Map<String, String> results;

  SigChallengeOutput({this.results = const {}});
}

/// JavaScript challenge request
class JsChallengeRequest {
  final JsChallengeType type;
  final dynamic input; // NChallengeInput or SigChallengeInput
  final String? videoId;

  JsChallengeRequest({
    required this.type,
    required this.input,
    this.videoId,
  });
}

/// JavaScript challenge response
class JsChallengeResponse {
  final JsChallengeType type;
  final dynamic output; // NChallengeOutput or SigChallengeOutput

  JsChallengeResponse({
    required this.type,
    required this.output,
  });
}

