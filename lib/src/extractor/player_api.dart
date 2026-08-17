/// YouTube Innertube player API client.
library player_api;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/logger.dart';
import 'innertube_clients.dart';

class InnertubeSession {
  final String? visitorData;
  final String? apiKey;

  const InnertubeSession({this.visitorData, this.apiKey});
}

/// Extract visitorData / INNERTUBE_API_KEY from watch-page HTML / ytcfg.
InnertubeSession extractInnertubeSession(String html) {
  String? visitorData;
  String? apiKey;

  final visitorMatch = RegExp(r'"visitorData"\s*:\s*"([^"]+)"').firstMatch(html);
  if (visitorMatch != null) {
    visitorData = visitorMatch.group(1);
  }

  final apiKeyMatch = RegExp(r'"INNERTUBE_API_KEY"\s*:\s*"([^"]+)"').firstMatch(html);
  if (apiKeyMatch != null) {
    apiKey = apiKeyMatch.group(1);
  }

  // Fallback: ytcfg.set({...}) — may be truncated by naive regex, so keep string search first.
  if (visitorData == null || apiKey == null) {
    final ytcfgMatch = RegExp(r'ytcfg\.set\(({.*?})\);', dotAll: true).firstMatch(html);
    if (ytcfgMatch != null) {
      try {
        final ytcfg = json.decode(ytcfgMatch.group(1)!) as Map;
        visitorData ??=
            (((ytcfg['INNERTUBE_CONTEXT'] as Map?)?['client'] as Map?)?['visitorData']) as String?;
        apiKey ??= ytcfg['INNERTUBE_API_KEY'] as String?;
      } catch (_) {
        // ignore malformed ytcfg slice
      }
    }
  }

  return InnertubeSession(visitorData: visitorData, apiKey: apiKey);
}

class PlayerApi {
  final http.Client client;
  /// Optional Cookie / Authorization headers (from [YoutubeCookieJar]).
  final Map<String, String> extraHeaders;

  PlayerApi(this.client, {this.extraHeaders = const {}});

  /// Fetch a single client player response (`youtubei/v1/player`).
  Future<Map<String, dynamic>?> fetchPlayerResponse({
    required String videoId,
    required InnertubeClient innertubeClient,
    String? visitorData,
    String? apiKey,
    String? signatureTimestamp,
    String? playerPoToken,
  }) async {
    final contextClient = innertubeClient.buildClientContext(visitorData: visitorData);
    final body = <String, dynamic>{
      'context': {'client': contextClient},
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
      'playbackContext': {
        'contentPlaybackContext': {
          'html5Preference': 'HTML5_PREF_WANTS',
          if (signatureTimestamp != null && signatureTimestamp.isNotEmpty)
            'signatureTimestamp': int.tryParse(signatureTimestamp) ?? signatureTimestamp,
        },
      },
      if (playerPoToken != null && playerPoToken.isNotEmpty)
        'serviceIntegrityDimensions': {'poToken': playerPoToken},
    };

    var url = 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';
    if (apiKey != null && apiKey.isNotEmpty) {
      url = '$url&key=${Uri.encodeQueryComponent(apiKey)}';
    }

    final headers = innertubeClient.buildApiHeaders(visitorData: visitorData);
    // Attach cookies / SAPISIDHASH only for cookie-capable clients.
    if (innertubeClient.supportsCookies && extraHeaders.isNotEmpty) {
      headers.addAll(extraHeaders);
    }

    try {
      final response = await client
          .post(
            Uri.parse(url),
            headers: headers,
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        logger.warning(
          'player_api',
          'Player API ${innertubeClient.id} HTTP ${response.statusCode}',
        );
        return null;
      }

      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) {
        return null;
      }
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      logger.warning('player_api', 'Player API ${innertubeClient.id} failed: $e');
      return null;
    }
  }

  /// Fetch multiple clients in parallel. Returns map of clientId -> playerResponse.
  /// Keeps non-OK responses (for age-gate / error analysis); merge filters formats.
  Future<Map<String, Map<String, dynamic>>> fetchPlayerResponses({
    required String videoId,
    required List<String> clientIds,
    String? visitorData,
    String? apiKey,
    String? signatureTimestamp,
    Map<String, String?> playerPoTokens = const {},
  }) async {
    final uniqueIds = <String>[];
    final seen = <String>{};
    for (final id in clientIds) {
      if (seen.add(id)) uniqueIds.add(id);
    }

    final futures = <Future<MapEntry<String, Map<String, dynamic>?>>>[];
    for (final clientId in uniqueIds) {
      final cfg = kInnertubeClients[clientId];
      if (cfg == null) {
        logger.warning('player_api', 'Unknown player client: $clientId');
        continue;
      }

      futures.add(() async {
        final pr = await fetchPlayerResponse(
          videoId: videoId,
          innertubeClient: cfg,
          visitorData: visitorData,
          apiKey: apiKey,
          signatureTimestamp: signatureTimestamp,
          playerPoToken: playerPoTokens[clientId],
        );
        return MapEntry(clientId, pr);
      }());
    }

    final results = <String, Map<String, dynamic>>{};
    final entries = await Future.wait(futures);
    for (final entry in entries) {
      final clientId = entry.key;
      final pr = entry.value;
      if (pr == null) continue;

      final prVideoId = (pr['videoDetails'] as Map?)?['videoId'] as String?;
      if (prVideoId != null && prVideoId != videoId) {
        logger.warning(
          'player_api',
          'Skipping $clientId: unexpected videoId $prVideoId (wanted $videoId)',
        );
        continue;
      }

      final status = (pr['playabilityStatus'] as Map?)?['status'] as String?;
      final streamingData = pr['streamingData'] as Map?;
      final downloadable = countDownloadableFormats(streamingData);
      logger.info(
        'player_api',
        'Client $clientId: status=$status downloadableFormats=$downloadable',
      );

      if (status != null && status != 'OK' && downloadable == 0) {
        final reason = (pr['playabilityStatus'] as Map?)?['reason'];
        logger.info(
          'player_api',
          '$clientId not downloadable: status=$status reason=$reason '
          '(kept for playability analysis)',
        );
      }

      results[clientId] = pr;
    }

    return results;
  }
}

int countDownloadableFormats(Map? streamingData) {
  if (streamingData == null) return 0;
  var count = 0;
  for (final key in const ['adaptiveFormats', 'formats']) {
    final list = streamingData[key];
    if (list is! List) continue;
    for (final item in list) {
      if (item is Map && isDownloadableFormat(item)) count++;
    }
  }
  return count;
}

bool isDownloadableFormat(Map format) {
  final url = format['url'];
  if (url is String && url.isNotEmpty) return true;
  final sc = format['signatureCipher'];
  return sc is String && sc.isNotEmpty;
}

bool hasDownloadableFormats(Map? streamingData) =>
    countDownloadableFormats(streamingData) > 0;

/// Merge streamingData from multiple player responses.
/// Prefer formats that already have a direct URL / signatureCipher.
/// Tag each format with `_yt_dlp_client` for UA/header selection.
///
/// By default webpage streamingData is ignored (yt-dlp 2026.03+ behavior:
/// webpage player response is SABR-only / skipped). Set
/// [includeWebpageStreamingData] only as an explicit fallback.
Map<String, dynamic>? mergePlayerStreamingData(
  Map<String, Map<String, dynamic>> playerResponses, {
  Map? webpageStreamingData,
  List<String> clientPriority = const [
    'android_vr',
    'visionos',
    'tv_downgraded',
    'web_embedded',
    'tv',
    'web',
    'ios',
  ],
  bool includeWebpageStreamingData = false,
}) {
  final mergedAdaptive = <Map<String, dynamic>>[];
  final mergedProgressive = <Map<String, dynamic>>[];
  final seenAdaptive = <String>{};
  final seenProgressive = <String>{};
  String? dashManifestUrl;
  String? hlsManifestUrl;
  String? expiresInSeconds;

  Map<String, dynamic>? takeStreamingData(String clientId, Map? sd) {
    if (sd == null) return null;
    return Map<String, dynamic>.from(sd);
  }

  void absorb(String clientId, Map? sd) {
    final streamingData = takeStreamingData(clientId, sd);
    if (streamingData == null) return;

    expiresInSeconds ??= streamingData['expiresInSeconds']?.toString();
    dashManifestUrl ??= streamingData['dashManifestUrl'] as String?;
    hlsManifestUrl ??= streamingData['hlsManifestUrl'] as String?;

    void absorbList(String key, List<Map<String, dynamic>> out, Set<String> seen) {
      final list = streamingData[key];
      if (list is! List) return;
      for (final raw in list) {
        if (raw is! Map) continue;
        if (!isDownloadableFormat(raw)) continue;

        final format = Map<String, dynamic>.from(raw);
        format['_yt_dlp_client'] = clientId;
        final client = kInnertubeClients[clientId];
        if (client != null) {
          format['httpHeaders'] = {
            'User-Agent': client.userAgent,
            'Accept': '*/*',
            'Accept-Language': 'en-US,en;q=0.9',
            'Accept-Encoding': 'identity',
            'Origin': 'https://www.youtube.com',
            'Referer': 'https://www.youtube.com/',
          };
        }

        final dedupeKey = _formatDedupeKey(format);
        if (!seen.add(dedupeKey)) continue;
        out.add(format);
      }
    }

    absorbList('adaptiveFormats', mergedAdaptive, seenAdaptive);
    absorbList('formats', mergedProgressive, seenProgressive);
  }

  // Higher priority clients first so their formats win dedupe.
  final ordered = <String>[
    ...clientPriority.where(playerResponses.containsKey),
    ...playerResponses.keys.where((id) => !clientPriority.contains(id)),
  ];

  for (final clientId in ordered) {
    absorb(clientId, playerResponses[clientId]?['streamingData'] as Map?);
  }

  // Only absorb webpage formats when explicitly enabled AND they are downloadable.
  // Never return SABR-only stub adaptiveFormats as a successful result.
  if (includeWebpageStreamingData && webpageStreamingData != null) {
    absorb('web', webpageStreamingData);
  }

  if (mergedAdaptive.isEmpty && mergedProgressive.isEmpty) {
    return null;
  }

  return {
    if (expiresInSeconds != null) 'expiresInSeconds': expiresInSeconds,
    if (dashManifestUrl != null) 'dashManifestUrl': dashManifestUrl,
    if (hlsManifestUrl != null) 'hlsManifestUrl': hlsManifestUrl,
    'adaptiveFormats': mergedAdaptive,
    'formats': mergedProgressive,
  };
}

String _formatDedupeKey(Map format) {
  final itag = format['itag']?.toString() ?? '';
  final audioTrack = format['audioTrack'];
  final audioTrackId = audioTrack is Map ? audioTrack['id']?.toString() ?? '' : '';
  final isDrc = format['isDrc'] == true ? '1' : '0';
  return '$itag|$audioTrackId|$isDrc';
}
