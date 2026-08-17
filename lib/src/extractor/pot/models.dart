/// PO Token models / enums.
library pot_models;

enum PoTokenContext {
  gvs,
  player,
  subs;

  String get value {
    switch (this) {
      case PoTokenContext.gvs:
        return 'gvs';
      case PoTokenContext.player:
        return 'player';
      case PoTokenContext.subs:
        return 'subs';
    }
  }

  static PoTokenContext? tryParse(String raw) {
    switch (raw.toLowerCase()) {
      case 'gvs':
        return PoTokenContext.gvs;
      case 'player':
        return PoTokenContext.player;
      case 'subs':
        return PoTokenContext.subs;
      default:
        return null;
    }
  }
}

enum ContentBindingType {
  visitorData,
  dataSyncId,
  videoId,
  visitorId;

  String get value {
    switch (this) {
      case ContentBindingType.visitorData:
        return 'visitor_data';
      case ContentBindingType.dataSyncId:
        return 'datasync_id';
      case ContentBindingType.videoId:
        return 'video_id';
      case ContentBindingType.visitorId:
        return 'visitor_id';
    }
  }
}

/// never = don't fetch; auto = only when required/recommended; always = always try.
enum FetchPotPolicy { never, auto, always }

class PoTokenRequest {
  final PoTokenContext context;
  final String internalClientName;
  final Map<String, dynamic>? innertubeContext;
  final String? visitorData;
  final String? dataSyncId;
  final String? videoId;
  final String? videoWebpage;
  final String? playerUrl;
  final bool isAuthenticated;
  final bool gvsBindToVideoId;
  final bool bypassCache;
  final String? botguardChallenge;

  const PoTokenRequest({
    required this.context,
    required this.internalClientName,
    this.innertubeContext,
    this.visitorData,
    this.dataSyncId,
    this.videoId,
    this.videoWebpage,
    this.playerUrl,
    this.isAuthenticated = false,
    this.gvsBindToVideoId = false,
    this.bypassCache = false,
    this.botguardChallenge,
  });

  PoTokenRequest copyWith({
    PoTokenContext? context,
    String? internalClientName,
    Map<String, dynamic>? innertubeContext,
    String? visitorData,
    String? dataSyncId,
    String? videoId,
    String? videoWebpage,
    String? playerUrl,
    bool? isAuthenticated,
    bool? gvsBindToVideoId,
    bool? bypassCache,
    String? botguardChallenge,
  }) {
    return PoTokenRequest(
      context: context ?? this.context,
      internalClientName: internalClientName ?? this.internalClientName,
      innertubeContext: innertubeContext ?? this.innertubeContext,
      visitorData: visitorData ?? this.visitorData,
      dataSyncId: dataSyncId ?? this.dataSyncId,
      videoId: videoId ?? this.videoId,
      videoWebpage: videoWebpage ?? this.videoWebpage,
      playerUrl: playerUrl ?? this.playerUrl,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      gvsBindToVideoId: gvsBindToVideoId ?? this.gvsBindToVideoId,
      bypassCache: bypassCache ?? this.bypassCache,
      botguardChallenge: botguardChallenge ?? this.botguardChallenge,
    );
  }
}

class PoTokenResponse {
  final String poToken;
  final int? expiresAtEpochSeconds;

  const PoTokenResponse({
    required this.poToken,
    this.expiresAtEpochSeconds,
  });
}

class PoTokenProviderRejected implements Exception {
  final String message;
  PoTokenProviderRejected(this.message);
  @override
  String toString() => 'PoTokenProviderRejected: $message';
}

class PoTokenProviderError implements Exception {
  final String message;
  final bool expected;
  PoTokenProviderError(this.message, {this.expected = true});
  @override
  String toString() => 'PoTokenProviderError: $message';
}
