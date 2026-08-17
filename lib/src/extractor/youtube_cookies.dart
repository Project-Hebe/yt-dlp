/// YouTube cookie jar + SAPISIDHASH auth (mirrors yt-dlp cookie login).
library youtube_cookies;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Cookie howto (same as yt-dlp wiki).
const kYoutubeCookieHowtoUrl =
    'https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies';

/// In-memory YouTube cookie store for watch-page + Innertube API requests.
class YoutubeCookieJar {
  final Map<String, String> _cookies;

  YoutubeCookieJar([Map<String, String>? cookies])
      : _cookies = Map<String, String>.from(cookies ?? const {});

  factory YoutubeCookieJar.empty() => YoutubeCookieJar();

  /// From `name=value` map (typical WebView export).
  factory YoutubeCookieJar.fromMap(Map<String, String> cookies) =>
      YoutubeCookieJar(cookies);

  /// From a raw `Cookie` request header: `a=1; b=2`.
  factory YoutubeCookieJar.fromHeader(String header) {
    final map = <String, String>{};
    for (final part in header.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      final name = trimmed.substring(0, eq).trim();
      final value = trimmed.substring(eq + 1).trim();
      if (name.isNotEmpty) map[name] = value;
    }
    return YoutubeCookieJar(map);
  }

  /// Parse Netscape / curl cookie file contents (desktop export).
  factory YoutubeCookieJar.fromNetscape(String contents) {
    final map = <String, String>{};
    for (final rawLine in contents.split('\n')) {
      var line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#HttpOnly_')) {
        line = line.substring('#HttpOnly_'.length);
      } else if (line.startsWith('#')) {
        continue;
      }
      final parts = line.split('\t');
      if (parts.length < 7) continue;
      final domain = parts[0].toLowerCase();
      if (!domain.contains('youtube.com') && !domain.contains('google.com')) {
        continue;
      }
      final name = parts[5];
      final value = parts[6];
      if (name.isNotEmpty) map[name] = value;
    }
    return YoutubeCookieJar(map);
  }

  bool get isEmpty => _cookies.isEmpty;
  bool get isNotEmpty => _cookies.isNotEmpty;

  String? operator [](String name) => _cookies[name];

  void operator []=(String name, String value) => _cookies[name] = value;

  /// Replace all cookies (e.g. after WebView login).
  void replaceAll(Map<String, String> cookies) {
    _cookies
      ..clear()
      ..addAll(cookies);
  }

  /// Clear all cookies.
  void clear() => _cookies.clear();

  Map<String, String> get asMap => Map.unmodifiable(_cookies);

  /// Logged-in when LOGIN_INFO + any SAPISID family cookie exist (yt-dlp rule).
  bool get isAuthenticated {
    final hasLoginInfo = _cookies.containsKey('LOGIN_INFO');
    final hasSid = _cookies.containsKey('SAPISID') ||
        _cookies.containsKey('__Secure-1PAPISID') ||
        _cookies.containsKey('__Secure-3PAPISID');
    return hasLoginInfo && hasSid;
  }

  String? get sapisid =>
      _cookies['SAPISID'] ?? _cookies['__Secure-3PAPISID'];

  String? get sapisid1p => _cookies['__Secure-1PAPISID'];

  String? get sapisid3p => _cookies['__Secure-3PAPISID'];

  /// `Cookie` header value, or null if empty.
  String? toCookieHeader() {
    if (_cookies.isEmpty) return null;
    return _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// Build `Authorization: SAPISIDHASH ...` for Innertube (secure origin).
  String? buildAuthorizationHeader({
    String origin = 'https://www.youtube.com',
    String? userSessionId,
    String? timestamp,
  }) {
    final parts = <String>[];
    final additional = <String, String>{};
    if (userSessionId != null && userSessionId.isNotEmpty) {
      additional['u'] = userSessionId;
    }

    void add(String scheme, String? sid) {
      if (sid == null || sid.isEmpty) return;
      parts.add(makeSidAuthorization(
        scheme: scheme,
        sid: sid,
        origin: origin,
        additionalParts: additional,
        timestamp: timestamp,
      ));
    }

    add('SAPISIDHASH', _cookies['SAPISID'] ?? _cookies['__Secure-3PAPISID']);
    add('SAPISID1PHASH', sapisid1p);
    add('SAPISID3PHASH', sapisid3p);

    if (parts.isEmpty) return null;
    return parts.join(' ');
  }

  /// Extra headers for Innertube / watch-page calls when cookies are set.
  Map<String, String> buildRequestHeaders({
    String origin = 'https://www.youtube.com',
    String? userSessionId,
    bool includeAuth = true,
  }) {
    final headers = <String, String>{};
    final cookie = toCookieHeader();
    if (cookie != null) headers['Cookie'] = cookie;

    if (includeAuth) {
      final auth = buildAuthorizationHeader(
        origin: origin,
        userSessionId: userSessionId,
      );
      if (auth != null) {
        headers['Authorization'] = auth;
        headers['X-Origin'] = origin;
      }
      if (isAuthenticated) {
        headers['X-Youtube-Bootstrap-Logged-In'] = 'true';
      }
    }
    return headers;
  }
}

/// Python: `SAPISIDHASH timestamp_sidhash[_additionalKeys]`.
String makeSidAuthorization({
  required String scheme,
  required String sid,
  required String origin,
  Map<String, String> additionalParts = const {},
  String? timestamp,
}) {
  final ts = timestamp ??
      (DateTime.now().toUtc().millisecondsSinceEpoch / 1000).round().toString();
  final hashParts = <String>[];
  if (additionalParts.isNotEmpty) {
    hashParts.add(additionalParts.values.join(':'));
  }
  hashParts.addAll([ts, sid, origin]);
  final sidhash = sha1.convert(utf8.encode(hashParts.join(' '))).toString();
  final parts = <String>[ts, sidhash];
  if (additionalParts.isNotEmpty) {
    // Python: ''.join(additional_parts) joins dict **keys**.
    parts.add(additionalParts.keys.join());
  }
  return '$scheme ${parts.join('_')}';
}
