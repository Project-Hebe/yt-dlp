/// URL parser utilities for extracting YouTube video IDs
library url_parser;

import 'dart:core';

/// YouTube URL patterns
class YouTubeUrlParser {
  /// Valid YouTube URL regex pattern
  /// Supports multiple YouTube URL formats
  static final RegExp _validUrlPattern = RegExp(
    r'^.*(?:youtube\.com/(?:[^/]+/.+/|(?:v|e|embed|shorts|live)/|.*[?&]v=)|youtu\.be/|youtube\.googleapis\.com/)(?<id>[0-9A-Za-z_-]{11}).*',
    caseSensitive: false,
  );

  /// Alternative pattern for watch URLs
  static final RegExp _watchUrlPattern = RegExp(
    r'(?:youtube\.com/watch\?v=|youtu\.be/)(?<id>[0-9A-Za-z_-]{11})',
    caseSensitive: false,
  );

  /// Pattern for embed URLs
  static final RegExp _embedUrlPattern = RegExp(
    r'youtube\.com/(?:embed|v|e)/(?<id>[0-9A-Za-z_-]{11})',
    caseSensitive: false,
  );

  /// Pattern for shorts URLs
  static final RegExp _shortsUrlPattern = RegExp(
    r'youtube\.com/shorts/(?<id>[0-9A-Za-z_-]{11})',
    caseSensitive: false,
  );

  /// Simple pattern for video ID only (11 characters)
  static final RegExp _videoIdPattern = RegExp(
    r'^[0-9A-Za-z_-]{11}$',
  );

  /// Extract video ID from YouTube URL
  /// 
  /// Returns the video ID if found, null otherwise
  static String? extractVideoId(String url) {
    if (url.isEmpty) return null;

    // Try watch URL pattern first (most common)
    var match = _watchUrlPattern.firstMatch(url);
    if (match != null) {
      final id = match.namedGroup('id');
      if (id != null && id.length == 11) return id;
    }

    // Try embed URL pattern
    match = _embedUrlPattern.firstMatch(url);
    if (match != null) {
      final id = match.namedGroup('id');
      if (id != null && id.length == 11) return id;
    }

    // Try shorts URL pattern
    match = _shortsUrlPattern.firstMatch(url);
    if (match != null) {
      final id = match.namedGroup('id');
      if (id != null && id.length == 11) return id;
    }

    // Try general pattern
    match = _validUrlPattern.firstMatch(url);
    if (match != null) {
      final id = match.namedGroup('id');
      if (id != null && id.length == 11) return id;
    }

    // If URL is just the video ID
    if (_videoIdPattern.hasMatch(url)) {
      return url;
    }

    // Try to extract from query parameters
    final uri = Uri.tryParse(url);
    if (uri != null) {
      final vParam = uri.queryParameters['v'];
      if (vParam != null && vParam.length == 11) {
        return vParam;
      }
    }

    return null;
  }

  /// Check if URL is a valid YouTube URL
  static bool isValidUrl(String url) {
    if (url.isEmpty) return false;
    
    // Check if we can extract a video ID
    return extractVideoId(url) != null;
  }

  /// Normalize YouTube URL to standard format
  static String normalizeUrl(String url) {
    final videoId = extractVideoId(url);
    if (videoId == null) return url;
    return 'https://www.youtube.com/watch?v=$videoId';
  }
}

