/// In-memory PO Token cache with TTL.
library pot_cache;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'utils.dart';

class PoTokenCacheEntry {
  final String poToken;
  final int expiresAtEpochSeconds;

  const PoTokenCacheEntry({
    required this.poToken,
    required this.expiresAtEpochSeconds,
  });

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAtEpochSeconds;
}

class PoTokenMemoryCache {
  final Map<String, PoTokenCacheEntry> _entries = {};
  final int defaultTtlSeconds;

  PoTokenMemoryCache({this.defaultTtlSeconds = 21600});

  String buildKey(PoTokenRequest request) {
    final binding = getWebPoContentBinding(request, bindToVisitorId: true);
    final payload = {
      't': 'webpo',
      'client': request.internalClientName,
      'ctx': request.context.value,
      'cb': binding.binding,
      'cbt': binding.type?.value,
      'vid': request.videoId,
    };
    final digest = sha256.convert(utf8.encode(json.encode(payload)));
    return digest.toString();
  }

  String? get(PoTokenRequest request) {
    if (request.bypassCache) return null;
    final key = buildKey(request);
    final entry = _entries[key];
    if (entry == null) return null;
    if (entry.isExpired) {
      _entries.remove(key);
      return null;
    }
    return entry.poToken;
  }

  void store(PoTokenRequest request, PoTokenResponse response) {
    final ttl = response.expiresAtEpochSeconds == null
        ? defaultTtlSeconds
        : max(
            0,
            response.expiresAtEpochSeconds! -
                (DateTime.now().millisecondsSinceEpoch ~/ 1000),
          );
    if (ttl <= 0) return;
    final key = buildKey(request);
    _entries[key] = PoTokenCacheEntry(
      poToken: response.poToken,
      expiresAtEpochSeconds:
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + ttl,
    );
  }

  void clear() => _entries.clear();
}
