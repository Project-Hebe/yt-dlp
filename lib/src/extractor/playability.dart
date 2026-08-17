/// Playability helpers: age-gate detection + user-facing error messages.
library playability;

import 'youtube_cookies.dart';

enum PlayabilityKind {
  ok,
  ageRestricted,
  loginRequired,
  privateOrUnavailable,
  geoRestricted,
  rateLimited,
  captchaRequired,
  liveStreamOffline,
  drmProtected,
  unplayable,
  error,
  unknown,
}

class PlayabilityInfo {
  final String? status;
  final String? reason;
  final String? subreason;
  final bool desktopLegacyAgeGate;
  final bool hasCaptcha;
  final PlayabilityKind kind;

  const PlayabilityInfo({
    this.status,
    this.reason,
    this.subreason,
    this.desktopLegacyAgeGate = false,
    this.hasCaptcha = false,
    required this.kind,
  });

  bool get isOk =>
      kind == PlayabilityKind.ok || kind == PlayabilityKind.liveStreamOffline;

  bool get isAgeGated => kind == PlayabilityKind.ageRestricted;

  String get combinedReason {
    final parts = <String>[
      if (reason != null && reason!.trim().isNotEmpty) reason!.trim(),
      if (subreason != null && subreason!.trim().isNotEmpty) subreason!.trim(),
    ];
    return parts.join('. ');
  }
}

const _ageGateHints = [
  'confirm your age',
  'age-restricted',
  'inappropriate',
  'age_verification_required',
  'age_check_required',
];

/// Extract playability from a player / webpage response.
PlayabilityInfo analyzePlayability(Map? playerResponse) {
  if (playerResponse == null) {
    return const PlayabilityInfo(kind: PlayabilityKind.unknown);
  }

  final ps = playerResponse['playabilityStatus'];
  if (ps is! Map) {
    // No playability block but has streaming → treat as OK-ish unknown.
    if (playerResponse['streamingData'] != null) {
      return const PlayabilityInfo(status: 'OK', kind: PlayabilityKind.ok);
    }
    return const PlayabilityInfo(kind: PlayabilityKind.unknown);
  }

  final status = ps['status']?.toString();
  final reason = ps['reason']?.toString();
  final desktopLegacy = ps['desktopLegacyAgeGateReason'] != null;

  String? subreason;
  final errorScreen = ps['errorScreen'];
  if (errorScreen is Map) {
    final pemr = errorScreen['playerErrorMessageRenderer'];
    if (pemr is Map) {
      subreason = _textFromRenderer(pemr['subreason']) ??
          _textFromRenderer(pemr['reason']);
    }
  }

  final hasCaptcha = errorScreen is Map &&
      errorScreen['playerCaptchaViewModel'] is Map;

  final blob = [
    status,
    reason,
    subreason,
  ].whereType<String>().join(' ').toLowerCase();

  PlayabilityKind kind;
  if (status == 'OK') {
    kind = PlayabilityKind.ok;
  } else if (status == 'LIVE_STREAM_OFFLINE') {
    kind = PlayabilityKind.liveStreamOffline;
  } else if (desktopLegacy ||
      status == 'AGE_CHECK_REQUIRED' ||
      status == 'AGE_VERIFICATION_REQUIRED' ||
      _ageGateHints.any(blob.contains)) {
    kind = PlayabilityKind.ageRestricted;
  } else if (status == 'LOGIN_REQUIRED' || blob.contains('sign in')) {
    kind = PlayabilityKind.loginRequired;
  } else if (hasCaptcha) {
    kind = PlayabilityKind.captchaRequired;
  } else if (blob.contains('not made this video available in your country') ||
      blob.contains('not available in your country')) {
    kind = PlayabilityKind.geoRestricted;
  } else if (blob.contains("isn't available, try again later") ||
      blob.contains('try again later')) {
    kind = PlayabilityKind.rateLimited;
  } else if (status == 'UNPLAYABLE') {
    kind = PlayabilityKind.unplayable;
  } else if (status == 'ERROR') {
    kind = PlayabilityKind.error;
  } else {
    kind = PlayabilityKind.unknown;
  }

  return PlayabilityInfo(
    status: status,
    reason: reason,
    subreason: subreason,
    desktopLegacyAgeGate: desktopLegacy,
    hasCaptcha: hasCaptcha,
    kind: kind,
  );
}

bool isAgeGatedPlayerResponse(Map? playerResponse) =>
    analyzePlayability(playerResponse).isAgeGated;

/// Pick the most actionable playability across webpage + client responses.
PlayabilityInfo selectPrimaryPlayability(Iterable<PlayabilityInfo> infos) {
  final list = infos.toList();
  if (list.isEmpty) {
    return const PlayabilityInfo(kind: PlayabilityKind.unknown);
  }

  // Prefer concrete restriction kinds over OK/unknown.
  const priority = [
    PlayabilityKind.drmProtected,
    PlayabilityKind.ageRestricted,
    PlayabilityKind.loginRequired,
    PlayabilityKind.geoRestricted,
    PlayabilityKind.captchaRequired,
    PlayabilityKind.rateLimited,
    PlayabilityKind.privateOrUnavailable,
    PlayabilityKind.unplayable,
    PlayabilityKind.error,
    PlayabilityKind.liveStreamOffline,
    PlayabilityKind.unknown,
    PlayabilityKind.ok,
  ];

  for (final kind in priority) {
    for (final info in list) {
      if (info.kind == kind && (info.combinedReason.isNotEmpty || kind != PlayabilityKind.unknown)) {
        return info;
      }
    }
  }
  return list.first;
}

/// Build a user-facing extractor error when no downloadable formats exist.
String buildNoFormatsMessage({
  required PlayabilityInfo playability,
  required bool isAuthenticated,
  required bool triedWebEmbedded,
}) {
  final reason = playability.combinedReason;
  final loginHint =
      'Pass YouTube account cookies (LOGIN_INFO + SAPISID). See $kYoutubeCookieHowtoUrl';

  switch (playability.kind) {
    case PlayabilityKind.ageRestricted:
      if (!isAuthenticated) {
        return 'This video is age-restricted'
            '${reason.isNotEmpty ? ': $reason' : ''}. '
            '${triedWebEmbedded ? 'web_embedded was tried but returned no formats. ' : ''}'
            'Some formats need login. $loginHint';
      }
      return 'This video is age-restricted and may require account age-verification'
          '${reason.isNotEmpty ? ': $reason' : ''}. '
          'Logged-in cookies were used but no downloadable formats were returned.';

    case PlayabilityKind.loginRequired:
      return 'YouTube requires login'
          '${reason.isNotEmpty ? ': $reason' : ''}. $loginHint';

    case PlayabilityKind.geoRestricted:
      return 'This video is geo-restricted'
          '${reason.isNotEmpty ? ': $reason' : ''}';

    case PlayabilityKind.captchaRequired:
      return 'YouTube is requiring a captcha challenge before playback'
          '${reason.isNotEmpty ? ': $reason' : ''}';

    case PlayabilityKind.rateLimited:
      return 'YouTube rate-limited '
          '${isAuthenticated ? 'your account' : 'this session'}'
          '${reason.isNotEmpty ? ': $reason' : ''}. '
          'Wait and retry; avoid rapid requests.';

    case PlayabilityKind.liveStreamOffline:
      return 'Live stream is offline'
          '${reason.isNotEmpty ? ': $reason' : ''}';

    case PlayabilityKind.drmProtected:
      return 'This video is DRM protected and cannot be downloaded.';

    case PlayabilityKind.unplayable:
    case PlayabilityKind.error:
    case PlayabilityKind.privateOrUnavailable:
    case PlayabilityKind.unknown:
    case PlayabilityKind.ok:
      if (reason.isNotEmpty) {
        if (reason.toLowerCase().contains('sign in')) {
          return '$reason. $loginHint';
        }
        return 'No downloadable formats. $reason';
      }
      return 'No downloadable formats. Webpage may be SABR-only and player clients failed.';
  }
}

/// True when streamingData / formats indicate Widevine (or similar) DRM.
bool streamingDataHasDrm(Map? streamingData) {
  if (streamingData == null) return false;
  final licenseInfos = streamingData['licenseInfos'];
  if (licenseInfos is List && licenseInfos.isNotEmpty) return true;

  for (final key in const ['adaptiveFormats', 'formats']) {
    final list = streamingData[key];
    if (list is! List) continue;
    for (final item in list) {
      if (item is! Map) continue;
      final families = item['drmFamilies'];
      if (families is List && families.isNotEmpty) return true;
    }
  }
  return false;
}

bool playerResponsesHaveDrm(Iterable<Map?> playerResponses) {
  for (final pr in playerResponses) {
    if (pr == null) continue;
    if (streamingDataHasDrm(pr['streamingData'] as Map?)) return true;
  }
  return false;
}

/// Thrown when extraction fails due to playability / missing formats.
class YoutubeExtractorException implements Exception {
  final String message;
  final PlayabilityInfo? playability;
  final String? videoId;

  YoutubeExtractorException(
    this.message, {
    this.playability,
    this.videoId,
  });

  @override
  String toString() => message;
}

String? _textFromRenderer(dynamic node) {
  if (node == null) return null;
  if (node is String) return node;
  if (node is Map) {
    final simple = node['simpleText'];
    if (simple is String) return simple;
    final runs = node['runs'];
    if (runs is List) {
      return runs
          .whereType<Map>()
          .map((r) => r['text'])
          .whereType<String>()
          .join();
    }
  }
  return null;
}
