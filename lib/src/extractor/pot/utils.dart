/// WebPO content-binding helpers (yt-dlp pot/utils.py).
library pot_utils;

import 'dart:convert';

import 'models.dart';

const webPoClients = {
  'web',
  'mweb',
  'tv',
  'web_embedded',
  'web_creator',
  'web_music',
  'tv_simply',
  'tv_downgraded',
  'web_safari',
};

/// Map our short client ids to Innertube clientName strings.
String? innertubeClientNameFor(String clientId) {
  switch (clientId) {
    case 'web':
    case 'web_safari':
      return 'WEB';
    case 'mweb':
      return 'MWEB';
    case 'tv':
    case 'tv_downgraded':
      return 'TVHTML5';
    case 'tv_simply':
      return 'TVHTML5_SIMPLY';
    case 'web_embedded':
      return 'WEB_EMBEDDED_PLAYER';
    case 'web_creator':
      return 'WEB_CREATOR';
    case 'web_music':
      return 'WEB_REMIX';
    case 'android_vr':
      return 'ANDROID_VR';
    case 'android':
      return 'ANDROID';
    case 'ios':
      return 'IOS';
    case 'visionos':
      return 'VISIONOS';
    default:
      return null;
  }
}

bool isWebPoClient(String clientId) => webPoClients.contains(clientId);

({String? binding, ContentBindingType? type}) getWebPoContentBinding(
  PoTokenRequest request, {
  bool bindToVisitorId = false,
}) {
  final clientName = (request.innertubeContext?['client'] as Map?)?['clientName'] as String? ??
      innertubeClientNameFor(request.internalClientName);
  if (clientName == null) return (binding: null, type: null);

  final webNames = {
    'WEB',
    'MWEB',
    'TVHTML5',
    'WEB_EMBEDDED_PLAYER',
    'WEB_CREATOR',
    'WEB_REMIX',
    'TVHTML5_SIMPLY',
    'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
  };
  if (!webNames.contains(clientName)) {
    return (binding: null, type: null);
  }

  if (request.context == PoTokenContext.gvs && request.gvsBindToVideoId) {
    return (binding: request.videoId, type: ContentBindingType.videoId);
  }

  if (request.context == PoTokenContext.gvs || clientName == 'WEB_REMIX') {
    if (request.isAuthenticated) {
      return (binding: request.dataSyncId, type: ContentBindingType.dataSyncId);
    }
    if (bindToVisitorId) {
      final visitorId = extractVisitorId(request.visitorData);
      if (visitorId != null) {
        return (binding: visitorId, type: ContentBindingType.visitorId);
      }
    }
    return (binding: request.visitorData, type: ContentBindingType.visitorData);
  }

  if (request.context == PoTokenContext.player || request.context == PoTokenContext.subs) {
    return (binding: request.videoId, type: ContentBindingType.videoId);
  }

  return (binding: null, type: null);
}

String? extractVisitorId(String? visitorData) {
  if (visitorData == null || visitorData.isEmpty) return null;
  try {
    var input = Uri.decodeComponent(visitorData);
    final mod = input.length % 4;
    if (mod > 0) input = input.padRight(input.length + (4 - mod), '=');
    final bytes = base64Url.decode(input);
    if (bytes.length < 13) return null;
    final visitorId = utf8.decode(bytes.sublist(2, 13), allowMalformed: true);
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(visitorId)) {
      return visitorId;
    }
  } catch (_) {}
  return null;
}

/// Best-effort BotGuard challenge extraction from watch HTML (bgutil-compatible).
String? extractBotguardChallenge(String? webpage) {
  if (webpage == null || webpage.isEmpty) return null;

  // window.ytAtR = "...";
  final ytAtR = RegExp(
    r'''window\.ytAtR\s*=\s*(["'])((?:\\.|(?!\1).)*)\1\s*;''',
    dotAll: true,
  ).firstMatch(webpage);
  if (ytAtR != null) {
    try {
      final raw = _unescapeJsString(ytAtR.group(2)!);
      final decoded = json.decode(raw);
      if (decoded is Map && decoded['bgChallenge'] is String) {
        return decoded['bgChallenge'] as String;
      }
      if (decoded is String) {
        final nested = json.decode(decoded);
        if (nested is Map && nested['bgChallenge'] is String) {
          return nested['bgChallenge'] as String;
        }
      }
    } catch (_) {}
  }

  // Fallback: search bgChallenge JSON field.
  final bg = RegExp(r'"bgChallenge"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"').firstMatch(webpage);
  if (bg != null) {
    return _unescapeJsString(bg.group(1)!);
  }
  return null;
}

String _unescapeJsString(String input) {
  return input
      .replaceAll(r'\"', '"')
      .replaceAll(r"\'", "'")
      .replaceAll(r'\\', r'\')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\t', '\t');
}

String? sanitizePoToken(String? token) {
  if (token == null || token.isEmpty) return null;
  try {
    var input = Uri.decodeComponent(token.trim());
    final mod = input.length % 4;
    if (mod > 0) input = input.padRight(input.length + (4 - mod), '=');
    final decoded = base64Url.decode(input);
    return base64Url.encode(decoded);
  } catch (_) {
    final cleaned = token.trim();
    return cleaned.isEmpty ? null : cleaned;
  }
}

/// Append `pot=` query param used by GVS CDN requests.
String appendPotQuery(String url, String? poToken) {
  if (poToken == null || poToken.isEmpty) return url;
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final params = Map<String, String>.from(uri.queryParameters);
  if (params['pot'] == poToken) return url;
  params['pot'] = poToken;
  return uri.replace(queryParameters: params).toString();
}

/// Parse yt-dlp style tokens: `CLIENT.CONTEXT+TOKEN`.
Map<String, Map<PoTokenContext, String>> parsePoTokenConfigs(List<String> configs) {
  final result = <String, Map<PoTokenContext, String>>{};
  for (final raw in configs) {
    final plus = raw.indexOf('+');
    if (plus <= 0 || plus >= raw.length - 1) continue;

    final meta = raw.substring(0, plus);
    final tokenRaw = raw.substring(plus + 1);
    final dot = meta.indexOf('.');
    final client = (dot > 0 ? meta.substring(0, dot) : meta).toLowerCase();
    final contextName = dot > 0 ? meta.substring(dot + 1) : 'gvs';
    final context = PoTokenContext.tryParse(contextName) ?? PoTokenContext.gvs;
    final token = sanitizePoToken(tokenRaw);
    if (token == null) continue;

    result.putIfAbsent(client, () => <PoTokenContext, String>{})[context] = token;
  }
  return result;
}

String? lookupConfiguredPoToken(
  Map<String, Map<PoTokenContext, String>> tokens, {
  required String client,
  required PoTokenContext context,
}) {
  return tokens[client.toLowerCase()]?[context];
}
