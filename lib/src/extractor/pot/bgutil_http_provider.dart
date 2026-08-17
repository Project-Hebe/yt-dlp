/// bgutil HTTP PO Token provider (Brainicism/bgutil-ytdlp-pot-provider compatible).
///
/// Only used when the app explicitly passes a reachable [baseUrl].
/// Do NOT default to localhost — mobile devices have no local bgutil server.
library pot_bgutil_http_provider;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../utils/logger.dart';
import 'models.dart';
import 'provider.dart';
import 'utils.dart';

class BgUtilHttpPoTokenProvider implements PoTokenProvider {
  final http.Client client;
  final String baseUrl;
  final Duration timeout;
  final Duration pingCacheTtl;

  DateTime? _lastPing;
  bool _serverAvailable = true;

  BgUtilHttpPoTokenProvider({
    required this.client,
    this.baseUrl = 'http://127.0.0.1:4416',
    this.timeout = const Duration(seconds: 20),
    this.pingCacheTtl = const Duration(seconds: 60),
  });

  @override
  String get name => 'bgutil:http';

  @override
  bool isAvailable() {
    // Optimistic: allow attempt if ping cache expired or previously available.
    if (_lastPing == null) return true;
    if (DateTime.now().difference(_lastPing!) > pingCacheTtl) return true;
    return _serverAvailable;
  }

  Future<bool> ping() async {
    if (_lastPing != null && DateTime.now().difference(_lastPing!) < pingCacheTtl) {
      return _serverAvailable;
    }
    try {
      final resp = await client
          .get(Uri.parse(_join(baseUrl, 'ping')))
          .timeout(const Duration(seconds: 5));
      _serverAvailable = resp.statusCode == 200;
      if (_serverAvailable) {
        logger.debug('pot', 'bgutil ping OK at $baseUrl');
      }
    } catch (e) {
      _serverAvailable = false;
      logger.debug('pot', 'bgutil ping failed at $baseUrl: $e');
    }
    _lastPing = DateTime.now();
    return _serverAvailable;
  }

  @override
  Future<PoTokenResponse?> requestPot(PoTokenRequest request) async {
    if (!isWebPoClient(request.internalClientName)) {
      throw PoTokenProviderRejected(
        'bgutil HTTP only supports WebPO clients, got ${request.internalClientName}',
      );
    }

    if (!await ping()) {
      throw PoTokenProviderRejected('bgutil HTTP server unavailable at $baseUrl');
    }

    final binding = getWebPoContentBinding(request, bindToVisitorId: true);
    if (binding.binding == null || binding.binding!.isEmpty) {
      throw PoTokenProviderRejected(
        'Unable to compute content_binding for ${request.internalClientName}.${request.context.value}',
      );
    }

    final innertubeContext = request.innertubeContext ??
        {
          'client': {
            'clientName': innertubeClientNameFor(request.internalClientName),
            if (request.visitorData != null) 'visitorData': request.visitorData,
          },
        };

    final body = <String, dynamic>{
      'bypass_cache': request.bypassCache,
      'content_binding': binding.binding,
      'innertube_context': innertubeContext,
      if (request.botguardChallenge != null) 'challenge': request.botguardChallenge,
      if (request.videoId != null) 'video_id': request.videoId,
    };

    try {
      logger.info(
        'pot',
        'Requesting ${request.context.value} PO Token for '
        '${request.internalClientName} via bgutil HTTP ($baseUrl)',
      );
      final resp = await client
          .post(
            Uri.parse(_join(baseUrl, 'get_pot')),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(body),
          )
          .timeout(timeout);

      if (resp.statusCode != 200) {
        throw PoTokenProviderError(
          'bgutil /get_pot HTTP ${resp.statusCode}: ${resp.body}',
        );
      }

      final decoded = json.decode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map) {
        throw PoTokenProviderError('bgutil /get_pot returned non-object JSON');
      }
      if (decoded['error'] != null) {
        throw PoTokenProviderError('bgutil error: ${decoded['error']}');
      }
      final poToken = decoded['poToken'] ?? decoded['po_token'];
      if (poToken is! String || poToken.isEmpty) {
        throw PoTokenProviderError('bgutil response missing poToken');
      }
      final sanitized = sanitizePoToken(poToken) ?? poToken;
      return PoTokenResponse(poToken: sanitized);
    } on PoTokenProviderError {
      rethrow;
    } catch (e) {
      throw PoTokenProviderError('bgutil /get_pot failed: $e');
    }
  }

  String _join(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$b/$path';
  }
}
