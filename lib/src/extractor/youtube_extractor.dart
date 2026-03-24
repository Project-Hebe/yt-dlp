/// YouTube video information extractor
library youtube_extractor;

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/video_info.dart';
import '../utils/url_parser.dart';
import '../jsc/jsc_director.dart';
import '../jsc/challenge_types.dart';
import '../utils/logger.dart';
import '../utils/iso639_utils.dart';
import '../utils/retry_manager.dart';
import 'package:flutter/foundation.dart';

/// YouTube extractor class
class YouTubeExtractor {
  final http.Client _client;
  final JscDirector? _jscDirector;
  final int extractorRetries;
  final Duration Function(int attempt)? retrySleepFunction;
  static const String _baseUrl = 'https://www.youtube.com';
  static final Map<String, String> _defaultHeaders = {
    // Use a more recent Chrome User-Agent to avoid bot detection
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept-Encoding': 'gzip, deflate, br',
    'Connection': 'keep-alive',
    'Upgrade-Insecure-Requests': '1',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'none',
    'Sec-Fetch-User': '?1',
    'Cache-Control': 'max-age=0',
    'DNT': '1',
  };

  YouTubeExtractor({
    http.Client? client,
    JscDirector? jscDirector,
    this.extractorRetries = 3,
    this.retrySleepFunction,
  })  : _client = client ?? http.Client(),
        _jscDirector = jscDirector ?? (JscDirector().isAvailable() ? JscDirector() : null);

  /// Extract video information from YouTube URL
  Future<VideoInfo> extractInfo(String url) async {
    final videoId = YouTubeUrlParser.extractVideoId(url);
    if (videoId == null) {
      throw Exception('Invalid YouTube URL: $url. Could not extract video ID.');
    }

    final watchUrl = '$_baseUrl/watch?v=$videoId';

    // Use RetryManager for extraction with retry logic
    for (final retry in RetryManager(
      retries: extractorRetries,
      sleepFunction: retrySleepFunction ?? RetryManager.exponentialBackoff,
      onRetry: (error, attempt, retries) {
        RetryManager.reportRetry(
          error,
          attempt,
          retries,
          sleepFunc: retrySleepFunction != null ? (n) => retrySleepFunction!(n) : (n) => RetryManager.exponentialBackoff(n),
          info: (msg) => logger.info('extractor', msg),
          warn: (msg) => logger.warning('extractor', msg),
        );
      },
    ).iterable) {
      try {
        // Try with gzip/deflate only first (no brotli)
        return await _extractInfoWithEncoding(watchUrl, videoId, {'Accept-Encoding': 'gzip, deflate'});
      } catch (e) {
        // If that fails and error mentions brotli, try again with different encoding
        if (e.toString().contains('Brotli') || e.toString().contains('br')) {
          logger.debug('extractor', 'Retrying with identity encoding (no compression)...');
          try {
            return await _extractInfoWithEncoding(watchUrl, videoId, {'Accept-Encoding': 'identity'});
          } catch (e2) {
            // Set error for retry manager
            retry.error = Exception('Failed to fetch video page. Original error: $e. Retry error: $e2');
            continue;
          }
        }

        // Check if it's a network error that should be retried
        if (_shouldRetryError(e)) {
          retry.error = e;
          continue;
        }

        // Non-retryable error, rethrow
        rethrow;
      }
    }

    // Should not reach here, but just in case
    throw Exception('Failed to extract video information after $extractorRetries retries');
  }

  /// Check if an error should be retried
  bool _shouldRetryError(Object error) {
    final errorStr = error.toString().toLowerCase();

    // Network errors that should be retried
    if (errorStr.contains('timeout') || errorStr.contains('connection') || errorStr.contains('network') || errorStr.contains('socket') || errorStr.contains('failed host lookup') || errorStr.contains('connection refused') || errorStr.contains('connection reset')) {
      return true;
    }

    // HTTP errors that should be retried (except 403, 404, 429)
    if (error is Exception) {
      final message = error.toString();
      // Check for HTTP status codes
      final statusMatch = RegExp(r'(\d{3})').firstMatch(message);
      if (statusMatch != null) {
        final statusCode = int.tryParse(statusMatch.group(1) ?? '');
        if (statusCode != null) {
          // Retry on 5xx errors and some 4xx errors (but not 403, 404, 429)
          if (statusCode >= 500 || (statusCode >= 400 && statusCode != 403 && statusCode != 404 && statusCode != 429)) {
            return true;
          }
        }
      }
    }

    return false;
  }

  /// Internal method to extract info with specific Accept-Encoding header
  Future<VideoInfo> _extractInfoWithEncoding(String watchUrl, String videoId, Map<String, String> encodingHeaders) async {
    // Use RetryManager for HTTP requests
    for (final retry in RetryManager(
      retries: extractorRetries,
      sleepFunction: retrySleepFunction ?? RetryManager.exponentialBackoff,
      fatal: false, // Don't throw, let caller handle
    ).iterable) {
      try {
        // Create a request without automatic decompression
        // We'll handle decompression manually following yt-dlp's logic
        final request = http.Request('GET', Uri.parse(watchUrl));
        final headers = Map<String, String>.from(_defaultHeaders);
        headers.addAll(encodingHeaders);
        request.headers.addAll(headers);

        // Send request and get response
        final streamedResponse = await _client.send(request).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            throw Exception('Request timeout: Failed to fetch video page within 30 seconds');
          },
        );

        // Check HTTP status code
        if (streamedResponse.statusCode != 200) {
          // Retry on 5xx errors and some 4xx errors (but not 403, 404, 429)
          if (streamedResponse.statusCode >= 500 || (streamedResponse.statusCode >= 400 && streamedResponse.statusCode != 403 && streamedResponse.statusCode != 404 && streamedResponse.statusCode != 429)) {
            retry.error = Exception('HTTP ${streamedResponse.statusCode}: ${streamedResponse.reasonPhrase}');
            continue;
          }
          // Non-retryable HTTP error
          throw Exception('Failed to fetch video page: ${streamedResponse.statusCode} ${streamedResponse.reasonPhrase}');
        }

        // Continue with response processing (break out of retry loop on success)
        return await _processResponse(streamedResponse, videoId, watchUrl);
      } catch (e) {
        if (_shouldRetryError(e)) {
          retry.error = e;
          continue;
        }
        // Non-retryable error, rethrow
        rethrow;
      }
    }

    // Should not reach here, but just in case
    throw Exception('Failed to fetch video page after $extractorRetries retries');
  }

  /// Process HTTP response and extract video info
  Future<VideoInfo> _processResponse(http.StreamedResponse streamedResponse, String videoId, String watchUrl) async {
    // Read the response body as bytes (before any automatic decompression)
    final responseBytes = await streamedResponse.stream.toList();
    final rawBytes = responseBytes.expand((x) => x).toList();

    // Get Content-Encoding header before creating response object
    final contentEncodingHeader = streamedResponse.headers['content-encoding'] ?? streamedResponse.headers['Content-Encoding'] ?? '';

    if (streamedResponse.statusCode != 200) {
      throw Exception('Failed to fetch video page: ${streamedResponse.statusCode} ${streamedResponse.reasonPhrase}');
    }

    // Get response body - handle encoding properly
    // Following yt-dlp's approach: check Content-Encoding header and decompress in reverse order
    String html;
    final bytes = rawBytes;

    // Debug: Print first few bytes to check if it's compressed
    if (bytes.isNotEmpty) {
      final firstBytes = bytes.take(10).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      debugPrint('First 10 bytes (hex): $firstBytes');
    }

    // Content-Encoding header already retrieved above
    debugPrint('Content-Encoding header: "$contentEncodingHeader"');

    final encodings = contentEncodingHeader.split(',').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();

    // Check if data looks compressed by magic number
    final isGzipByMagic = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
    debugPrint('Is gzip by magic number: $isGzipByMagic');
    debugPrint('Encodings from header: $encodings');

    // Process encodings in reverse order (as yt-dlp does)
    // Content-Encoding lists encodings in order they were applied,
    // so we decompress in reverse order
    List<int> decompressedBytes = bytes;
    bool decompressionAttempted = false;

    // If we have encodings in header, process them
    if (encodings.isNotEmpty) {
      for (var encoding in encodings.reversed) {
        debugPrint('Processing encoding: $encoding');
        if (encoding == 'gzip' || encoding == 'x-gzip') {
          // Check if data actually looks compressed by magic number
          // If http package already decompressed it, magic number won't match
          if (!isGzipByMagic) {
            debugPrint('Content-Encoding says gzip but magic number doesn\'t match - data likely already decompressed by http package');
            debugPrint('Skipping gzip decompression (data is already decompressed)');
            // Data is already decompressed, skip
            continue;
          }
          decompressionAttempted = true;
          try {
            // yt-dlp uses: zlib.decompress(data, wbits=zlib.MAX_WBITS | 16)
            // In Dart, gzip.decode() is equivalent
            final beforeSize = decompressedBytes.length;
            decompressedBytes = gzip.decode(decompressedBytes);
            debugPrint('Successfully decompressed gzip: $beforeSize -> ${decompressedBytes.length} bytes');
          } catch (e) {
            debugPrint('Gzip decompression failed: $e');
            // If decompression fails, the data might already be decompressed
            // or might be corrupted - try to continue with current bytes
            debugPrint('Assuming data is already decompressed, continuing with current bytes');
            continue;
          }
        } else if (encoding == 'deflate') {
          try {
            // yt-dlp tries: zlib.decompress(data, -zlib.MAX_WBITS) first (raw deflate)
            // then falls back to: zlib.decompress(data) (zlib format)
            // In Dart, zlib.decode() expects zlib format
            final beforeSize = decompressedBytes.length;
            decompressedBytes = zlib.decode(decompressedBytes);
            debugPrint('Successfully decompressed deflate: $beforeSize -> ${decompressedBytes.length} bytes');
          } catch (e) {
            debugPrint('Deflate decompression failed: $e');
            // If zlib format fails, it might be raw deflate
            // Dart doesn't have direct support for raw deflate with negative window bits
            // So we'll just continue with the current bytes
            continue;
          }
        } else if (encoding == 'br') {
          // Brotli compression - Dart standard library doesn't support it
          // Throw exception to trigger retry without br
          debugPrint('Brotli compression detected but not supported. Will retry without br in Accept-Encoding...');
          throw Exception('Brotli compression not supported. Please retry request without br in Accept-Encoding header.');
        }
      }
    } else if (isGzipByMagic) {
      // No Content-Encoding header but data looks compressed, try to decompress
      debugPrint('No Content-Encoding header, but magic number suggests gzip, attempting decompression');
      decompressionAttempted = true;
      try {
        final beforeSize = decompressedBytes.length;
        decompressedBytes = gzip.decode(bytes);
        debugPrint('Successfully decompressed gzip (by magic number): $beforeSize -> ${decompressedBytes.length} bytes');
      } catch (e) {
        debugPrint('Gzip decompression failed (by magic number): $e');
        // Decompression failed, use original bytes
        decompressedBytes = bytes;
      }
    }

    // Check if decompressed data still looks compressed
    if (decompressedBytes.length >= 2 && decompressedBytes[0] == 0x1f && decompressedBytes[1] == 0x8b) {
      debugPrint('Warning: Decompressed data still looks like gzip, attempting second decompression');
      try {
        final beforeSize = decompressedBytes.length;
        decompressedBytes = gzip.decode(decompressedBytes);
        debugPrint('Successfully decompressed second time: $beforeSize -> ${decompressedBytes.length} bytes');
      } catch (e) {
        debugPrint('Second decompression failed: $e');
      }
    }

    // Validate decompressed bytes before decoding
    debugPrint('Decompressed bytes length: ${decompressedBytes.length}');
    if (decompressedBytes.isEmpty) {
      throw Exception('Decompressed data is empty');
    }

    // Check if data looks like text (basic heuristic)
    // Text data should have mostly printable ASCII characters
    int printableCount = 0;
    int sampleSize = decompressedBytes.length > 1000 ? 1000 : decompressedBytes.length;
    for (int i = 0; i < sampleSize; i++) {
      final byte = decompressedBytes[i];
      if ((byte >= 32 && byte <= 126) || byte == 9 || byte == 10 || byte == 13) {
        printableCount++;
      }
    }
    final printableRatio = printableCount / sampleSize;
    debugPrint('Printable character ratio: ${(printableRatio * 100).toStringAsFixed(1)}%');

    if (printableRatio < 0.5 && decompressionAttempted) {
      // Less than 50% printable characters - might still be compressed or binary
      throw Exception('Decompressed data does not appear to be text (printable ratio: ${(printableRatio * 100).toStringAsFixed(1)}%). '
          'Content-Encoding: "$contentEncodingHeader", First 20 bytes: ${decompressedBytes.take(20).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    }

    // Decode to string (UTF-8)
    try {
      html = utf8.decode(decompressedBytes, allowMalformed: false);
      debugPrint('Successfully decoded to UTF-8 string, length: ${html.length}');
    } catch (e) {
      debugPrint('UTF-8 decode failed: $e');
      debugPrint('First 50 bytes (hex): ${decompressedBytes.take(50).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      debugPrint('First 50 bytes (as chars): ${String.fromCharCodes(decompressedBytes.take(50).where((b) => b >= 32 && b <= 126))}');

      // If strict UTF-8 decoding fails, try with allowMalformed
      try {
        html = utf8.decode(decompressedBytes, allowMalformed: true);
        debugPrint('Decoded with allowMalformed: true, length: ${html.length}');
      } catch (e2) {
        throw Exception('Failed to decode response as UTF-8. Original error: $e, Fallback error: $e2. '
            'Data might still be compressed or corrupted. Content-Encoding: "$contentEncodingHeader"');
      }
    }

    // Validate that we got valid HTML/text
    if (html.isEmpty) {
      throw Exception('Received empty response from YouTube');
    }

    // Check if it looks like valid HTML/text (not binary/compressed data)
    final looksLikeText = html.contains('<') || html.contains('{') || html.contains('var ') || html.contains('function') || html.contains('<!DOCTYPE') || html.contains('<html');

    if (!looksLikeText) {
      // Still looks like binary/compressed data
      // Check if it's still compressed
      if (decompressedBytes.length >= 2 && decompressedBytes[0] == 0x1f && decompressedBytes[1] == 0x8b) {
        throw Exception('Response appears to still be compressed after decompression attempt. Content-Encoding: "$contentEncodingHeader", First 100 chars: ${html.substring(0, html.length > 100 ? 100 : html.length)}');
      } else {
        throw Exception('Response does not appear to be valid HTML/text. Content-Encoding: "$contentEncodingHeader", First 100 chars: ${html.substring(0, html.length > 100 ? 100 : html.length)}');
      }
    }

    // Debug: Check if we have the expected content
    if (!html.contains('ytInitialPlayerResponse') && !html.contains('ytInitialData') && !html.contains('var ytInitialPlayerResponse')) {
      // Response might not be the expected HTML page
      // Check if it's an error page or redirect
      if (html.contains('<title>') && html.length < 10000) {
        // Likely an error page, extract title for debugging
        final titleMatch = RegExp(r'<title>(.*?)</title>', caseSensitive: false).firstMatch(html);
        final title = titleMatch?.group(1) ?? 'Unknown error page';
        throw Exception('YouTube returned an error page: $title. The video may be unavailable or restricted.');
      }
    }

    return await _parseVideoInfo(html, videoId, watchUrl);
  }

  /// Parse video information from HTML
  Future<VideoInfo> _parseVideoInfo(String html, String videoId, String webpageUrl) async {
    // Extract initial player response from embedded JSON
    // Try multiple possible prefixes as YouTube may change the format
    Map<String, dynamic>? ytInitialPlayerResponse;

    // Try different patterns (following yt-dlp's approach)
    // yt-dlp uses: r'ytInitialPlayerResponse\s*='
    // Pattern 1: ytInitialPlayerResponse = {...}; (most common, matches yt-dlp's regex)
    // Pattern 2: var ytInitialPlayerResponse = {...};
    // Pattern 3: window["ytInitialPlayerResponse"] = {...};
    // Pattern 4: window['ytInitialPlayerResponse'] = {...};
    // Pattern 5: "ytInitialPlayerResponse":{...} (in JSON)
    final prefixes = [
      'ytInitialPlayerResponse', // Try this first (matches yt-dlp's pattern)
      'var ytInitialPlayerResponse',
      'window["ytInitialPlayerResponse"]',
      'window[\'ytInitialPlayerResponse\']',
      '"ytInitialPlayerResponse"',
    ];
    for (var prefix in prefixes) {
      ytInitialPlayerResponse = _extractJsonFromScript(html, prefix);
      if (ytInitialPlayerResponse != null) {
        // Validate that it contains videoDetails
        if (ytInitialPlayerResponse.containsKey('videoDetails')) {
          break;
        } else {
          // Check if this is an error response
          final playabilityStatus = ytInitialPlayerResponse['playabilityStatus'] as Map?;
          if (playabilityStatus != null) {
            final status = playabilityStatus['status'] as String?;
            if (status == 'ERROR' || status == 'LOGIN_REQUIRED') {
              final reason = playabilityStatus['reason'] as String?;
              debugPrint('Error reason: $reason');
            }
          }

          // The extracted JSON might be incomplete - check if it's too small
          final jsonSize = jsonEncode(ytInitialPlayerResponse).length;
          if (jsonSize < 10000) {
            debugPrint('⚠️  Extracted JSON seems too small. The object might be incomplete or YouTube returned a minimal response.');
            debugPrint('This might indicate the video is unavailable, restricted, or requires additional authentication.');
          }

          // Continue trying other prefixes
          ytInitialPlayerResponse = null;
        }
      } else {
        debugPrint('Failed to extract with prefix: $prefix');
      }
    }

    // Also try to extract ytInitialData
    debugPrint('Attempting to extract ytInitialData...');
    final ytInitialData = _extractJsonFromScript(html, 'var ytInitialData');
    if (ytInitialData != null) {
      debugPrint('Successfully extracted ytInitialData');
    } else {
      debugPrint('Failed to extract ytInitialData');
    }

    if (ytInitialPlayerResponse == null) {
      // Debug: Check if HTML contains the expected strings
      final hasYtInitialPlayerResponse = html.contains('ytInitialPlayerResponse');
      final hasVideoDetails = html.contains('videoDetails');
      final hasStreamingData = html.contains('streamingData');

      debugPrint('Debug info:');
      debugPrint('  HTML contains "ytInitialPlayerResponse": $hasYtInitialPlayerResponse');
      debugPrint('  HTML contains "videoDetails": $hasVideoDetails');
      debugPrint('  HTML contains "streamingData": $hasStreamingData');
      debugPrint('  HTML length: ${html.length}');

      // Try to find any JSON-like structures
      final jsonMatches = RegExp(r'\{[^{}]*"videoDetails"[^{}]*\}', dotAll: true).allMatches(html);
      debugPrint('  Found ${jsonMatches.length} potential JSON matches with "videoDetails"');

      throw Exception('Failed to extract video data from page. YouTube may have changed their page structure. '
          'HTML contains ytInitialPlayerResponse: $hasYtInitialPlayerResponse, '
          'videoDetails: $hasVideoDetails, streamingData: $hasStreamingData. '
          'Please try again or check if the video is available.');
    }

    // Check playability status (matching yt-dlp's behavior)
    final playabilityStatus = ytInitialPlayerResponse['playabilityStatus'] as Map?;
    if (playabilityStatus != null) {
      final status = playabilityStatus['status'] as String?;
      final reason = playabilityStatus['reason'] as String?;

      if (status == 'LOGIN_REQUIRED') {
        debugPrint('⚠️  YouTube requires login or bot verification');
        debugPrint('Reason: $reason');
        debugPrint('This usually means YouTube detected automated access.');
        debugPrint('Solutions:');
        debugPrint('  1. Use cookies from a logged-in browser session');
        debugPrint('  2. Try using a different User-Agent');
        debugPrint('  3. Wait a few minutes and try again');
        throw Exception('YouTube requires login or bot verification: $reason. '
            'Please provide cookies or try again later.');
      } else if (status == 'ERROR') {
        final errorReason = reason ?? 'Unknown error';
        debugPrint('⚠️  YouTube returned an error status');
        debugPrint('Reason: $errorReason');
        throw Exception('YouTube returned an error: $errorReason');
      } else if (status != 'OK') {
        debugPrint('⚠️  Unexpected playability status: $status');
        if (reason != null) {
          debugPrint('Reason: $reason');
        }
        // Don't throw here, as some statuses might still allow extraction
      }
    }

    // Parse video details
    final videoDetails = ytInitialPlayerResponse['videoDetails'] as Map?;
    final microformat = ytInitialPlayerResponse['microformat']?['playerMicroformatRenderer'] as Map?;

    if (videoDetails == null) {
      throw Exception('Video details not found');
    }

    // Extract streaming data
    final streamingData = ytInitialPlayerResponse['streamingData'] as Map?;
    final formats = <VideoFormat>[];

    // Language map for tracking ORIGINAL_LANG_VALUE and DEFAULT_LANG_VALUE
    // Following yt-dlp: language_map = {ORIGINAL_LANG_VALUE: None, DEFAULT_LANG_VALUE: None}
    const int ORIGINAL_LANG_VALUE = 10;
    const int DEFAULT_LANG_VALUE = 5;
    final languageMap = <int, String?>{
      ORIGINAL_LANG_VALUE: null,
      DEFAULT_LANG_VALUE: null,
    };

    if (streamingData != null) {
      // Store all formats (with and without URL) for potential DASH manifest language extraction
      // DASH manifest may have more accurate language information even for formats with URLs
      final allAdaptiveFormats = <VideoFormat>[];
      final formatsWithoutUrl = <VideoFormat>[];

      // Parse adaptive formats (video-only and audio-only)
      final adaptiveFormats = streamingData['adaptiveFormats'] as List?;
      if (adaptiveFormats != null) {
        debugPrint('Found ${adaptiveFormats.length} adaptive formats');
        for (var formatData in adaptiveFormats) {
          try {
            final formatMap = formatData as Map;
            final itag = formatMap['itag'];

            if (formatMap.containsKey('signatureCipher')) {
              final sc = formatMap['signatureCipher'];
              debugPrint('  signatureCipher type: ${sc.runtimeType}');
              debugPrint('  signatureCipher value (first 200 chars): ${sc.toString().substring(0, sc.toString().length > 200 ? 200 : sc.toString().length)}');
            }

            final format = _parseFormat(formatMap, languageMap);
            allAdaptiveFormats.add(format); // Store all formats for DASH manifest matching
            formats.add(format); // Keep every format (even without URL) to match yt-dlp behavior

            if (format.url != null && format.url!.isNotEmpty) {
              debugPrint('  ✓ Format $itag parsed successfully, URL length: ${format.url!.length}');
            } else {
              // Track formats missing URLs for later DASH manifest matching or decryption
              formatsWithoutUrl.add(format);
              debugPrint('  ⚠️  Format $itag has null/empty URL - keeping for manifest/decryption (was previously skipped)');
            }
          } catch (e, stackTrace) {
            debugPrint('Error parsing adaptive format: $e');
            debugPrint('Stack trace: $stackTrace');
            // Continue with other formats
          }
        }
      }

      // Try to extract formats from DASH manifest if available
      // IMPORTANT: Extract from DASH manifest for ALL formats (not just those without URL)
      // because DASH manifest may have more accurate language information
      final dashManifestUrl = streamingData['dashManifestUrl'] as String?;
      if (dashManifestUrl != null && dashManifestUrl.isNotEmpty) {
        debugPrint('Found DASH manifest URL: ${dashManifestUrl.substring(0, dashManifestUrl.length > 100 ? 100 : dashManifestUrl.length)}...');
        debugPrint('Attempting to extract formats from DASH manifest for ${allAdaptiveFormats.length} adaptive formats (${formatsWithoutUrl.length} without URL)...');
        try {
          // Pass ALL formats to DASH manifest extractor, not just those without URL
          // This allows us to update language information for formats that already have URLs
          final dashFormats = await _extractFormatsFromDashManifest(dashManifestUrl, videoId, allAdaptiveFormats);

          // Merge DASH formats with existing formats
          // If a DASH format has the same itag as an existing format, prefer the DASH format (it has URL and better language info)
          final dashFormatMap = <String, VideoFormat>{};
          for (var dashFormat in dashFormats) {
            if (dashFormat.formatId != null) {
              dashFormatMap[dashFormat.formatId.toString()] = dashFormat;
            }
          }

          // Update existing formats with DASH format information (especially language)
          final updatedFormats = <VideoFormat>[];
          for (var format in formats) {
            if (format.formatId != null) {
              final dashFormat = dashFormatMap[format.formatId.toString()];
              if (dashFormat != null) {
                // DASH format has URL and potentially better language info, use it
                updatedFormats.add(dashFormat);
                logger.info('youtube_extractor', 'Replaced format ${format.formatId} with DASH format (language: "${format.language}" -> "${dashFormat.language}")');
              } else {
                updatedFormats.add(format);
              }
            } else {
              updatedFormats.add(format);
            }
          }

          // Add DASH formats that don't match existing formats (shouldn't happen, but just in case)
          final existingFormatIds = formats.map((f) => f.formatId?.toString()).whereType<String>().toSet();
          for (var dashFormat in dashFormats) {
            if (dashFormat.formatId != null && !existingFormatIds.contains(dashFormat.formatId.toString())) {
              updatedFormats.add(dashFormat);
              logger.info('youtube_extractor', 'Added new DASH format ${dashFormat.formatId} (not found in adaptiveFormats)');
            }
          }

          formats.clear();
          formats.addAll(updatedFormats);
          debugPrint('✓ Extracted ${dashFormats.length} formats from DASH manifest, merged with existing formats');
        } catch (e, stackTrace) {
          debugPrint('✗ Failed to extract formats from DASH manifest: $e');
          debugPrint('Stack trace: $stackTrace');
        }
      } else {
        debugPrint('No DASH manifest URL found in streamingData');
      }

      // Parse regular formats (combined video+audio)
      final regularFormats = streamingData['formats'] as List?;
      if (regularFormats != null) {
        debugPrint('Found ${regularFormats.length} regular formats');
        int missingUrlCount = 0;
        for (var formatData in regularFormats) {
          try {
            final format = _parseFormat(formatData as Map, languageMap);
            formats.add(format); // Keep every format even if URL/encryption is unresolved

            if (format.url == null || format.url!.isEmpty) {
              missingUrlCount++;
              if (format.formatNote?.contains('encrypted') == true || format.formatNote?.contains('n challenge') == true) {
                debugPrint('  ⚠️  Regular format ${format.formatId} missing URL due to encrypted signature/challenge - keeping for later decryption');
              } else {
                debugPrint('  ⚠️  Regular format ${format.formatId} has null/empty URL - keeping for completeness');
              }
            }
          } catch (e) {
            debugPrint('Error parsing regular format: $e');
            // Continue with other formats
          }
        }
        if (missingUrlCount > 0) {
          debugPrint('⚠️  Kept $missingUrlCount regular formats without URLs (previously skipped)');
        }
      }

      debugPrint('Total formats parsed: ${formats.length}');

      // Try to decrypt formats that need decryption
      debugPrint('[jsc] Checking JSC Director availability...');
      debugPrint('[jsc] _jscDirector is null: ${_jscDirector == null}');
      if (_jscDirector != null) {
        debugPrint('[jsc] _jscDirector.isAvailable(): ${_jscDirector!.isAvailable()}');
      }

      if (_jscDirector != null && _jscDirector!.isAvailable()) {
        debugPrint('[jsc] ✓ JavaScript solver available, attempting to decrypt encrypted formats...');
        debugPrint('[jsc] Total formats before decryption: ${formats.length}');
        await _decryptFormats(formats, videoId, html);
        debugPrint('[jsc] Decryption process completed. Formats after decryption: ${formats.length}');
      } else {
        debugPrint('[jsc] ⚠️  JavaScript solver not available. Encrypted formats may fail with 403.');
        if (_jscDirector == null) {
          debugPrint('[jsc] Reason: JSC Director is null');
        } else {
          debugPrint('[jsc] Reason: JSC Director.isAvailable() returned false');
        }

        // Check if we have formats with n parameter (always needs decryption)
        final hasNChallenge = formats.any((f) {
          if (f.url == null) return false;
          final uri = Uri.tryParse(f.url!);
          return uri?.queryParameters.containsKey('n') == true;
        });

        if (hasNChallenge) {
          debugPrint('[jsc] ⚠️  WARNING: Formats have n challenge parameter which REQUIRES JS decryption!');
          debugPrint('[jsc] ⚠️  Without JS solver, these formats will fail with 403.');
        }
      }

      if (formats.isEmpty) {
        debugPrint('Warning: No valid formats found. This may indicate signature decryption is required.');
      }

      // Post-process formats: Update language_preference based on language_map
      // Following yt-dlp's logic (lines 3532-3537):
      // if lang_code and lang_code == language_map[ORIGINAL_LANG_VALUE]:
      //     f['language_preference'] = ORIGINAL_LANG_VALUE
      // elif lang_code and lang_code == language_map[DEFAULT_LANG_VALUE]:
      //     f['language_preference'] = DEFAULT_LANG_VALUE
      logger.info('youtube_extractor', 'Post-processing formats: language_map[ORIGINAL_LANG_VALUE]=${languageMap[ORIGINAL_LANG_VALUE]}, language_map[DEFAULT_LANG_VALUE]=${languageMap[DEFAULT_LANG_VALUE]}');
      final updatedFormats = <VideoFormat>[];
      for (var format in formats) {
        final langCode = format.language;
        VideoFormat? updatedFormat;

        if (langCode != null && langCode == languageMap[ORIGINAL_LANG_VALUE]) {
          // Update format_note and language_preference
          final updatedFormatNote = format.formatNote != null ? '${format.formatNote} (original)' : '(original)';
          updatedFormat = format.copyWith(
            formatNote: updatedFormatNote,
            languagePreference: ORIGINAL_LANG_VALUE.toString(),
          );
          logger.info('youtube_extractor', 'Format ${format.formatId}: Updated language_preference to ORIGINAL_LANG_VALUE (language="$langCode")');
        } else if (langCode != null && langCode == languageMap[DEFAULT_LANG_VALUE]) {
          // Update format_note and language_preference
          final updatedFormatNote = format.formatNote != null ? '${format.formatNote} (default)' : '(default)';
          updatedFormat = format.copyWith(
            formatNote: updatedFormatNote,
            languagePreference: DEFAULT_LANG_VALUE.toString(),
          );
          logger.info('youtube_extractor', 'Format ${format.formatId}: Updated language_preference to DEFAULT_LANG_VALUE (language="$langCode")');
        }

        updatedFormats.add(updatedFormat ?? format);
      }
      formats.clear();
      formats.addAll(updatedFormats);
    } else {
      debugPrint('Warning: streamingData is null in ytInitialPlayerResponse');
    }

    // Extract captions/subtitles first (needed for language extraction)
    final captions = ytInitialPlayerResponse['captions']?['playerCaptionsTracklistRenderer']?['captionTracks'] as List?;
    final List<SubtitleInfo> subtitleList = [];
    String? originalLanguageCode; // Extract original language from subtitles

    if (captions != null) {
      // Helper function to get language code from caption track
      // Following yt-dlp's get_lang_code function:
      // return (remove_start(track.get('vssId') or '', '.').replace('.', '-')
      //         or track.get('languageCode'))
      String? getLangCode(Map captionMap) {
        final vssId = captionMap['vssId'] as String?;
        if (vssId != null && vssId.isNotEmpty) {
          // Remove leading '.' and replace '.' with '-'
          var processed = vssId.startsWith('.') ? vssId.substring(1) : vssId;
          processed = processed.replaceAll('.', '-');
          if (processed.isNotEmpty) {
            return processed;
          }
        }
        return captionMap['languageCode'] as String?;
      }

      for (var caption in captions) {
        final captionMap = caption as Map;
        final languageCode = getLangCode(captionMap);
        final languageName = captionMap['name']?['simpleText'] as String?;
        final baseUrl = captionMap['baseUrl'] as String?;
        final isAutoGenerated = captionMap['kind'] == 'asr';
        final isTranslatable = captionMap['isTranslatable'] == true;

        if (languageCode != null) {
          subtitleList.add(SubtitleInfo(
            languageCode: languageCode,
            languageName: languageName,
            url: baseUrl,
            isAutoGenerated: isAutoGenerated,
            format: 'vtt',
          ));

          // Extract original language from non-auto-generated, translatable subtitles
          // Following yt-dlp: if is_manual_subs and isTranslatable, assume this is original audio language
          if (!isAutoGenerated && isTranslatable && originalLanguageCode == null) {
            // Remove 'a-' prefix if present (auto-generated prefix)
            var langCode = languageCode.startsWith('a-') ? languageCode.substring(2) : languageCode;
            // Normalize to ISO 639-1 format (only when setting from subtitles)
            originalLanguageCode = ISO639Utils.normalizeToShort(langCode) ?? langCode;
            logger.info('youtube_extractor', '✓ Found original language from manual translatable subtitles: $originalLanguageCode (from languageCode: $languageCode, vssId: ${captionMap['vssId']})');
          }
        }
      }

      // Also check auto-generated captions if no manual subtitles found
      if (originalLanguageCode == null && captions.isNotEmpty) {
        // Helper function to get language code (same as above)
        String? getLangCode(Map captionMap) {
          final vssId = captionMap['vssId'] as String?;
          if (vssId != null && vssId.isNotEmpty) {
            var processed = vssId.startsWith('.') ? vssId.substring(1) : vssId;
            processed = processed.replaceAll('.', '-');
            if (processed.isNotEmpty) {
              return processed;
            }
          }
          return captionMap['languageCode'] as String?;
        }

        logger.info('youtube_extractor', 'Checking ${captions.length} auto-generated captions for original language...');
        for (var i = 0; i < captions.length; i++) {
          final caption = captions[i];
          final captionMap = caption as Map;
          final languageCode = getLangCode(captionMap);
          final isAutoGenerated = captionMap['kind'] == 'asr';
          final isTranslatable = captionMap['isTranslatable'] == true;
          final vssId = captionMap['vssId'] as String?;

          logger.info('youtube_extractor', '  Caption[$i]: languageCode="$languageCode", vssId="$vssId", isAutoGenerated=$isAutoGenerated, isTranslatable=$isTranslatable');

          // Following yt-dlp logic:
          // 1. First try auto-generated and translatable subtitles
          if (languageCode != null && isAutoGenerated && isTranslatable) {
            // Remove 'a-' prefix if present
            var langCode = languageCode.startsWith('a-') ? languageCode.substring(2) : languageCode;
            // Normalize to ISO 639-1 format (only when setting from subtitles)
            originalLanguageCode = ISO639Utils.normalizeToShort(langCode) ?? langCode;
            logger.info('youtube_extractor', '✓ Found original language from auto-generated subtitles: $originalLanguageCode (from languageCode: $languageCode, vssId: $vssId)');
            break;
          }

          // 2. Also check manual subtitles if they are translatable
          // Following yt-dlp: if caption_track.get('isTranslatable'): set_audio_lang_from_orig_subs_lang(lang_code)
          if (originalLanguageCode == null && languageCode != null && !isAutoGenerated && isTranslatable) {
            // Remove 'a-' prefix if present
            var langCode = languageCode.startsWith('a-') ? languageCode.substring(2) : languageCode;
            // Normalize to ISO 639-1 format (only when setting from subtitles)
            originalLanguageCode = ISO639Utils.normalizeToShort(langCode) ?? langCode;
            logger.info('youtube_extractor', '✓ Found original language from manual translatable subtitles: $originalLanguageCode (from languageCode: $languageCode, vssId: $vssId)');
            break;
          }
        }
        if (originalLanguageCode == null) {
          logger.info('youtube_extractor', '⚠️ No original language found in auto-generated captions');
        }
      }
    }

    // Set language for formats that have audio but no language
    // Following yt-dlp's set_audio_lang_from_orig_subs_lang function
    // Note: This should only set language if format has audio codec (acodec != 'none')
    // and format doesn't already have a language
    // IMPORTANT:
    // 1. This should NOT override language already set from audioTrack.id
    // 2. If language_map[ORIGINAL_LANG_VALUE] is set, prefer it over subtitle language
    //    because it's more accurate (comes from the actual audio track)
    String? languageToUse = originalLanguageCode;

    // Prefer language_map[ORIGINAL_LANG_VALUE] if available (more accurate)
    if (languageMap[ORIGINAL_LANG_VALUE] != null) {
      languageToUse = languageMap[ORIGINAL_LANG_VALUE];
      logger.info('youtube_extractor', 'Using language_map[ORIGINAL_LANG_VALUE]=$languageToUse instead of subtitle language=$originalLanguageCode (more accurate)');
    } else if (languageMap[DEFAULT_LANG_VALUE] != null && originalLanguageCode == null) {
      languageToUse = languageMap[DEFAULT_LANG_VALUE];
      logger.info('youtube_extractor', 'Using language_map[DEFAULT_LANG_VALUE]=$languageToUse (no subtitle language found)');
    }

    if (languageToUse != null) {
      logger.info('youtube_extractor', '═══════════════════════════════════════════════════════════');
      logger.info('youtube_extractor', 'Setting language from ${languageMap[ORIGINAL_LANG_VALUE] != null ? "language_map (ORIGINAL)" : (languageMap[DEFAULT_LANG_VALUE] != null ? "language_map (DEFAULT)" : "subtitles")}: $languageToUse');
      logger.info('youtube_extractor', 'Checking ${formats.length} formats for language assignment...');

      final updatedFormats = <VideoFormat>[];
      int updatedCount = 0;
      int skippedCount = 0;

      for (var i = 0; i < formats.length; i++) {
        final format = formats[i];
        final formatId = format.formatId;

        // Only set language for formats with audio codec and no existing language
        // Following yt-dlp: f.get('acodec') != 'none' and not f.get('language')
        if (format.acodec != null && format.acodec != 'none' && format.language == null) {
          if (format.hasAudio == true) {
            logger.info('youtube_extractor', '  Format $formatId: Setting language to "$languageToUse" (acodec: ${format.acodec}, hasAudio: ${format.hasAudio}, current language: ${format.language})');
          }
          // Create a new VideoFormat with language set (VideoFormat is immutable)
          final updatedFormat = VideoFormat(
            formatId: format.formatId,
            url: format.url,
            manifestUrl: format.manifestUrl,
            ext: format.ext,
            width: format.width,
            height: format.height,
            fps: format.fps,
            vcodec: format.vcodec,
            acodec: format.acodec,
            filesize: format.filesize,
            tbr: format.tbr,
            protocol: format.protocol,
            httpHeaders: format.httpHeaders,
            formatNote: format.formatNote,
            quality: format.quality,
            hasVideo: format.hasVideo,
            hasAudio: format.hasAudio,
            language: languageToUse, // Set language from language_map or subtitles
            languagePreference: format.languagePreference,
            audioSampleRate: format.audioSampleRate,
            audioChannels: format.audioChannels,
            hasDrm: format.hasDrm,
            qualityLabel: format.qualityLabel,
            sourcePreference: format.sourcePreference,
            preference: format.preference,
            isDamaged: format.isDamaged,
          );
          updatedFormats.add(updatedFormat);
          updatedCount++;
        } else {
          // Format already has language or no audio codec - keep as-is
          if (format.language != null) {
            skippedCount++;
            logger.debug('youtube_extractor', 'Format ${format.formatId} already has language "${format.language}", skipping subtitle language');
          }
          updatedFormats.add(format);
        }
      }

      if (updatedCount > 0) {
        formats.clear();
        formats.addAll(updatedFormats);
        logger.debug('youtube_extractor', 'Updated $updatedCount formats with language from subtitles: $originalLanguageCode (skipped $skippedCount with existing language)');
      } else if (skippedCount > 0) {
        logger.debug('youtube_extractor', 'No formats updated (all $skippedCount formats already have language)');
      }
    }

    // Categorize formats
    final videoFormats = formats.where((f) => f.hasVideo == true && f.hasAudio != true).toList();
    final audioFormats = formats.where((f) => f.hasAudio == true && f.hasVideo != true).toList();
    final combinedFormats = formats.where((f) => f.hasVideo == true && f.hasAudio == true).toList();

    // Extract metadata
    final title = videoDetails['title'] as String?;
    final description = videoDetails['shortDescription'] as String?;
    final duration = int.tryParse(videoDetails['lengthSeconds']?.toString() ?? '');
    final viewCount = int.tryParse(videoDetails['viewCount']?.toString() ?? '');
    final author = videoDetails['author'] as String?;
    final channelId = videoDetails['channelId'] as String?;
    final isLiveContent = videoDetails['isLiveContent'] == true;

    // Extract thumbnails
    final thumbnailsData = videoDetails['thumbnail']?['thumbnails'] as List?;
    String? thumbnail;
    List<String>? thumbnails;
    if (thumbnailsData != null && thumbnailsData.isNotEmpty) {
      thumbnails = thumbnailsData.map((t) => (t as Map)['url'] as String).toList();
      final lastThumbnail = thumbnailsData.last as Map;
      thumbnail = lastThumbnail['url'] as String?;
    }

    // Extract upload date from microformat
    DateTime? uploadDate;
    if (microformat != null) {
      final publishDate = microformat['publishDate'] as String?;
      if (publishDate != null) {
        uploadDate = DateTime.tryParse(publishDate);
      }
    }

    // Extract additional metadata from initial data
    List<String>? tags;
    List<String>? categories;
    int? likeCount;
    int? commentCount;
    String? channel;
    int? channelFollowerCount;
    bool? channelIsVerified;

    if (ytInitialData != null) {
      // Try to extract tags from videoPrimaryInfoRenderer
      final videoPrimaryInfo = _extractNestedValue(ytInitialData, [
        'contents',
        'twoColumnWatchNextResults',
        'results',
        'results',
        'contents',
        (v) {
          if (v is! Map) return false;
          return v.containsKey('videoPrimaryInfoRenderer');
        },
        'videoPrimaryInfoRenderer',
      ]);

      // Try to extract like count
      likeCount = _extractLikeCount(videoPrimaryInfo);

      // Try to extract tags
      tags = _extractTags(ytInitialData);

      // Try to extract categories
      categories = _extractCategories(ytInitialData);
    }

    // Note: Captions/subtitles are already extracted above (before format categorization)
    // subtitleList and originalLanguageCode are already populated

    // Extract channel information
    if (ytInitialData != null) {
      final channelInfo = _extractChannelInfo(ytInitialData);
      channel = channelInfo['name'];
      channelFollowerCount = channelInfo['followerCount'];
      channelIsVerified = channelInfo['isVerified'];
    }

    return VideoInfo(
      id: videoId,
      title: title,
      description: description,
      thumbnail: thumbnail,
      thumbnails: thumbnails,
      duration: duration,
      uploader: author,
      uploaderId: channelId,
      uploaderUrl: channelId != null ? '$_baseUrl/channel/$channelId' : null,
      uploadDate: uploadDate,
      viewCount: viewCount,
      likeCount: likeCount,
      commentCount: commentCount,
      tags: tags,
      categories: categories,
      webpageUrl: webpageUrl,
      formats: formats,
      videoFormats: videoFormats,
      audioFormats: audioFormats,
      combinedFormats: combinedFormats,
      subtitleList: subtitleList.isNotEmpty ? subtitleList : null,
      liveStatus: isLiveContent ? 'is_live' : 'not_live',
      isLive: isLiveContent,
      channel: channel ?? author,
      channelId: channelId,
      channelUrl: channelId != null ? '$_baseUrl/channel/$channelId' : null,
      channelFollowerCount: channelFollowerCount,
      channelIsVerified: channelIsVerified,
      mediaType: 'video',
    );
  }

  /// Safe integer conversion helper
  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
    if (value is double) return value.toInt();
    return null;
  }

  /// Parse format from format data map
  /// [languageMap] is used to track ORIGINAL_LANG_VALUE and DEFAULT_LANG_VALUE language codes
  VideoFormat _parseFormat(Map formatData, Map<int, String?> languageMap) {
    final itag = _toInt(formatData['itag']);

    final manifestUrl = (formatData['manifestUrl'] ?? formatData['manifest_url']) as String?;
    // Parse all format fields first (needed for early returns)
    final mimeType = formatData['mimeType'] as String?;
    final bitrate = _toInt(formatData['bitrate']);
    final averageBitrate = _toInt(formatData['averageBitrate']);
    final width = _toInt(formatData['width']);
    final height = _toInt(formatData['height']);
    final fps = _toInt(formatData['fps']);
    final contentLength = formatData['contentLength'];
    final filesize = _toInt(contentLength);
    final qualityLabel = formatData['qualityLabel'] as String?;
    final audioTrack = formatData['audioTrack'] as Map?;
    final hasDrm = formatData['drmFamilies'] != null && (formatData['drmFamilies'] as List).isNotEmpty;

    // Extract codec information from mimeType
    String? vcodec;
    String? acodec;
    if (mimeType != null) {
      final codecMatch = RegExp(r'codecs="([^"]+)"').firstMatch(mimeType);
      if (codecMatch != null) {
        final codecs = codecMatch.group(1)?.split(',');
        if (codecs != null) {
          for (var codec in codecs) {
            codec = codec.trim();
            if (codec.startsWith('avc') || codec.startsWith('vp')) {
              vcodec = codec;
            } else if (codec.startsWith('mp4a') || codec.startsWith('opus')) {
              acodec = codec;
            }
          }
        }
      }
    }

    // Determine extension from mimeType
    String? ext;
    if (mimeType != null) {
      if (mimeType.contains('video/mp4')) {
        ext = 'mp4';
      } else if (mimeType.contains('video/webm')) {
        ext = 'webm';
      } else if (mimeType.contains('audio/mp4')) {
        ext = 'm4a';
      } else if (mimeType.contains('audio/webm')) {
        ext = 'webm';
      }
    }

    // Determine if format has video/audio
    final hasVideo = width != null && height != null;
    final hasAudio = acodec != null || mimeType?.contains('audio') == true;

    // Extract audio track information
    // Following yt-dlp's implementation:
    // 1. Extract language from audioTrack.id (split by '.' and take first part)
    // 2. Check displayName for "descriptive" or "original"
    // 3. Check audioIsDefault for default track
    // 4. Set language_preference values: -10 (descriptive), 10 (original), 5 (default), -1 (other)
    String? language;
    String? languagePreference;

    // Constants matching yt-dlp
    const int ORIGINAL_LANG_VALUE = 10;
    const int DEFAULT_LANG_VALUE = 5;
    const int DESCRIPTIVE_LANG_VALUE = -10;
    const int OTHER_LANG_VALUE = -1;

    // Get audioTrack (following yt-dlp: fmt_stream.get('audioTrack') or {})
    if (audioTrack != null) {
      final audioTrackId = audioTrack['id'] as String?;
      final displayName = audioTrack['displayName'] as String? ?? '';
      final audioIsDefault = audioTrack['audioIsDefault'] as bool?;

      // Log full audioTrack structure for debugging (especially for audio formats)
      // IMPORTANT: Log ALL formats with audioTrack, not just hasAudio formats
      // because audio formats may have multiple language tracks
      if (hasAudio || audioTrackId != null) {
        logger.info('youtube_extractor', '═══════════════════════════════════════════════════════════');
        logger.info('youtube_extractor', 'Format $itag: audioTrack structure - id="$audioTrackId", displayName="$displayName", audioIsDefault=$audioIsDefault');
        logger.info('youtube_extractor', 'Format $itag: audioTrack full data: ${audioTrack.toString()}');
        logger.info('youtube_extractor', 'Format $itag: hasAudio=$hasAudio, acodec=$acodec');
      }

      // Extract language code from audioTrack.id (format: "lang.id" or just "lang")
      // yt-dlp: language_code = audio_track.get('id', '').split('.')[0] or None
      // Note: In Python, ''.split('.')[0] returns '', and '' or None returns None
      // So we need to handle empty strings correctly
      if (audioTrackId != null && audioTrackId.isNotEmpty) {
        final parts = audioTrackId.split('.');
        if (hasAudio) {
          logger.info('youtube_extractor', 'Format $itag: audioTrack.id split result - parts: $parts, parts.length: ${parts.length}');
        }
        if (parts.isNotEmpty) {
          final rawLanguage = parts.first;
          // Only use the language code if it's not empty
          // Following yt-dlp: '' or None returns None
          // yt-dlp: language_code = audio_track.get('id', '').split('.')[0] or None
          // In Python: ''.split('.')[0] returns '', and '' or None returns None
          if (rawLanguage.isNotEmpty) {
            // yt-dlp does NOT normalize the language code from audioTrack.id
            // It uses it as-is, only normalizing when setting from subtitles
            // So we should NOT call normalizeToShort here
            language = rawLanguage;
            if (hasAudio) {
              logger.info('youtube_extractor', 'Format $itag: ✓ Extracted language from audioTrack.id: "$rawLanguage" (raw, not normalized, full id="$audioTrackId", parts: $parts)');
            } else {
              logger.debug('youtube_extractor', 'Format $itag: Extracted language from audioTrack.id: "$rawLanguage" (raw, not normalized)');
            }
          } else {
            // Empty string should result in None/null (matching Python: '' or None)
            language = null;
            if (hasAudio) {
              logger.warning('youtube_extractor', 'Format $itag: ⚠️ audioTrack.id is empty after split, setting language to null (full id="$audioTrackId", parts: $parts)');
            } else {
              logger.debug('youtube_extractor', 'Format $itag: audioTrack.id is empty after split, setting language to null');
            }
          }
        } else {
          if (hasAudio) {
            logger.warning('youtube_extractor', 'Format $itag: ⚠️ audioTrack.id split resulted in empty parts (full id="$audioTrackId")');
          } else {
            logger.debug('youtube_extractor', 'Format $itag: audioTrack.id split resulted in empty parts');
          }
        }
      } else {
        if (hasAudio) {
          logger.warning('youtube_extractor', 'Format $itag: ⚠️ audioTrack.id is null or empty (audioTrack: $audioTrack)');
        } else {
          logger.debug('youtube_extractor', 'Format $itag: audioTrack.id is null or empty');
        }
      }

      // Determine language_preference based on displayName and audioIsDefault
      // Following yt-dlp's get_language_code_and_preference logic:
      final displayNameLower = displayName.toLowerCase();
      int? prefValue;

      if (hasAudio) {
        logger.info('youtube_extractor', 'Format $itag: Checking displayName for language preference - displayName="$displayName", displayNameLower="$displayNameLower", audioIsDefault=$audioIsDefault');
      }

      if (displayNameLower.contains('descriptive')) {
        // Descriptive audio track
        // yt-dlp: return join_nonempty(language_code, 'desc'), -10
        // join_nonempty(None, 'desc') returns 'desc' (filter(None, values) filters out None)
        prefValue = DESCRIPTIVE_LANG_VALUE;
        if (language != null) {
          language = '$language-desc';
        } else {
          // If language_code is None, join_nonempty returns 'desc'
          language = 'desc';
        }
        if (hasAudio) {
          logger.info('youtube_extractor', 'Format $itag: ✓ Descriptive audio track detected (language="$language", preference=$prefValue)');
        }
      } else if (displayNameLower.contains('original')) {
        // Original language track
        // yt-dlp: if language_code and not language_map.get(ORIGINAL_LANG_VALUE):
        //            language_map[ORIGINAL_LANG_VALUE] = language_code
        prefValue = ORIGINAL_LANG_VALUE;
        if (language != null && languageMap[ORIGINAL_LANG_VALUE] == null) {
          languageMap[ORIGINAL_LANG_VALUE] = language;
          logger.info('youtube_extractor', 'Format $itag: Stored language "$language" in language_map[ORIGINAL_LANG_VALUE]');
        }
        if (hasAudio) {
          logger.info('youtube_extractor', 'Format $itag: ✓✓✓ ORIGINAL language track detected (language="$language", preference=$prefValue)');
        }
      } else if (audioIsDefault == true) {
        // Default audio track
        // yt-dlp: if language_code and not language_map.get(DEFAULT_LANG_VALUE):
        //            language_map[DEFAULT_LANG_VALUE] = language_code
        prefValue = DEFAULT_LANG_VALUE;
        if (language != null && languageMap[DEFAULT_LANG_VALUE] == null) {
          languageMap[DEFAULT_LANG_VALUE] = language;
          logger.info('youtube_extractor', 'Format $itag: Stored language "$language" in language_map[DEFAULT_LANG_VALUE]');
        }
        if (hasAudio) {
          logger.info('youtube_extractor', 'Format $itag: ✓✓✓ DEFAULT audio track detected (language="$language", preference=$prefValue, audioIsDefault=true)');
        }
      } else {
        // Other tracks
        prefValue = OTHER_LANG_VALUE;
        if (hasAudio) {
          logger.info('youtube_extractor', 'Format $itag: Other audio track (language="$language", preference=$prefValue)');
        }
      }

      // Convert to string for model compatibility
      languagePreference = prefValue.toString();

      if (hasAudio) {
        logger.info('youtube_extractor', 'Format $itag: ✓ After audioTrack processing - language="$language", preference=$languagePreference');
      }
    } else {
      if (hasAudio) {
        logger.warning('youtube_extractor', 'Format $itag: ⚠️ audioTrack is null (formatData keys: ${formatData.keys.toList()})');
      }
    }

    // Fallback: Try direct language field if audioTrack didn't provide it
    if (language == null && formatData.containsKey('language')) {
      final langValue = formatData['language'];
      if (langValue is String && langValue.isNotEmpty) {
        // Normalize language code to ISO 639-1 format (2-letter)
        language = ISO639Utils.normalizeToShort(langValue) ?? langValue;
      }
    }

    // Fallback: Try direct language_preference field (may be string or int)
    if (languagePreference == null && formatData.containsKey('language_preference')) {
      final langPrefValue = formatData['language_preference'];
      if (langPrefValue is String && langPrefValue.isNotEmpty) {
        languagePreference = langPrefValue;
      } else if (langPrefValue is int) {
        languagePreference = langPrefValue.toString();
      }
    }

    // Debug: Log language extraction for troubleshooting
    // Always log for formats with audio to help debug language extraction issues
    if (hasAudio) {
      logger.info('youtube_extractor', '═══════════════════════════════════════════════════════════');
      logger.info('youtube_extractor', 'Format $itag FINAL RESULT:');
      logger.info('youtube_extractor', '  hasAudio: $hasAudio, acodec: $acodec');
      logger.info('youtube_extractor', '  language: "$language"');
      logger.info('youtube_extractor', '  languagePreference: $languagePreference');
      logger.info('youtube_extractor', '═══════════════════════════════════════════════════════════');
    } else if (language != null || (languagePreference != null && languagePreference.isNotEmpty)) {
      logger.debug('youtube_extractor', 'Format $itag language info: language=$language, preference=$languagePreference');
    }

    // Calculate total bitrate
    final totalBitrate = averageBitrate ?? bitrate;
    final tbr = totalBitrate != null ? (totalBitrate / 1000).round() : null;

    // Build format note
    String? formatNote;
    if (hasVideo && hasAudio) {
      formatNote = qualityLabel ?? '${height}p';
    } else if (hasVideo) {
      formatNote = '${qualityLabel ?? height}p (video only)';
    } else if (hasAudio) {
      final audioQuality = formatData['audioQuality'] as String?;
      formatNote = audioQuality?.replaceAll('audio_quality_', '') ?? 'audio only';
    }

    // Extract HTTP headers if present (for 403 prevention)
    Map<String, dynamic>? httpHeaders;
    if (formatData.containsKey('httpHeaders') && formatData['httpHeaders'] is Map) {
      httpHeaders = Map<String, dynamic>.from(formatData['httpHeaders'] as Map);
    } else {
      // Set default headers to mimic browser requests (following yt-dlp)
      httpHeaders = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'identity', // Disable compression for downloads
        'Referer': 'https://www.youtube.com/',
        'Origin': 'https://www.youtube.com',
        'Sec-Fetch-Mode': 'no-cors',
        'Sec-Fetch-Site': 'cross-site',
        'Sec-Fetch-Dest': 'empty',
      };
    }

    // Handle signatureCipher (encrypted URL with signature)
    String? url = formatData['url'] as String?;

    // Check for signatureCipher (YouTube's encrypted format)
    // signatureCipher format: "url=https://...&s=ENCRYPTED_SIG&sp=signature"
    // The URL and parameters are URL-encoded
    final signatureCipher = formatData['signatureCipher'] as String?;

    if (signatureCipher != null && signatureCipher.isNotEmpty) {
      // Parse signatureCipher - it's a URL-encoded query string
      // Example: "url=https%3A%2F%2Fr1---sn-xxx.googlevideo.com%2F...&s=ENCRYPTED&sp=sig"
      try {
        debugPrint('Parsing signatureCipher for format $itag (length: ${signatureCipher.length})');
        // The signatureCipher is already a query string, parse it directly
        // But the values inside are URL-encoded, so we need to decode them
        final params = <String, String>{};

        // Split by & to get key=value pairs
        final pairs = signatureCipher.split('&');
        debugPrint('  Found ${pairs.length} key-value pairs in signatureCipher');
        for (var pair in pairs) {
          final equalIndex = pair.indexOf('=');
          if (equalIndex > 0) {
            final key = Uri.decodeComponent(pair.substring(0, equalIndex));
            final value = Uri.decodeComponent(pair.substring(equalIndex + 1));
            params[key] = value;
            if (key == 'url') {
              debugPrint('  Found url parameter (length: ${value.length})');
            } else if (key == 's') {
              debugPrint('  Found encrypted signature s parameter (length: ${value.length})');
            } else if (key == 'sp') {
              debugPrint('  Found signature parameter name: $value');
            }
          }
        }

        url = params['url'];
        final s = params['s']; // Encrypted signature
        final sp = params['sp'] ?? 'signature'; // Signature parameter name (usually 'sig' or 'signature')

        if (url != null && url.isNotEmpty) {
          if (s != null && s.isNotEmpty) {
            // Encrypted signature detected
            debugPrint('⚠️  Format $itag has encrypted signature (signatureCipher detected)');
            debugPrint('  Base URL: ${url.contains('?') ? url.substring(0, url.indexOf('?')) : (url.length > 100 ? url.substring(0, 100) : url)}');
            debugPrint('  Signature param name: $sp');
            debugPrint('  ⚠️  WARNING: Encrypted signature requires JavaScript decryption');
            debugPrint('  ⚠️  This format may result in 403 Forbidden without decryption');
            debugPrint('  ⚠️  Will try to use this format if no unencrypted alternatives are available');

            // Add the encrypted signature to the URL (even if encrypted, we include it)
            // The downloader will try it, and if it fails with 403, we can retry with decryption
            // IMPORTANT: We use 's' as parameter name for encrypted signature (following yt-dlp convention)
            // The actual parameter name (sp, usually 'sig') will be used after decryption
            try {
              final uri = Uri.parse(url);
              final queryParams = Map<String, String>.from(uri.queryParameters);
              // Use 's' as parameter name for encrypted signature (standard convention)
              queryParams['s'] = s; // Add encrypted signature (may need decryption later)
              url = uri.replace(queryParameters: queryParams).toString();

              // Save sp value in httpHeaders for use during decryption
              // This allows us to use the correct parameter name after decryption
              // Note: httpHeaders is already initialized in lines 1396-1412 (either from formatData or defaults)
              httpHeaders['_sp_param'] = sp; // Save sp parameter name for decryption

              debugPrint('  ✓ Successfully constructed URL with encrypted signature (s parameter)');
              debugPrint('  ✓ Saved sp parameter name "$sp" for decryption');
            } catch (e) {
              debugPrint('  ✗ Failed to parse URL from signatureCipher: $e');
              url = null; // Reset to null if parsing fails
            }

            // Mark in format note that it needs decryption
            formatNote = '${formatNote ?? 'unknown'} (encrypted - may need JS decryption)';
          } else {
            // URL exists but no signature - use as-is
            debugPrint('Extracted URL from signatureCipher (no signature found, using as-is)');
          }
        } else {
          debugPrint('⚠️  signatureCipher parsing failed: url parameter is null or empty');
          debugPrint('  Available params: ${params.keys.join(', ')}');
          // Fall back to direct url field if available
        }
      } catch (e, stackTrace) {
        debugPrint('✗ Failed to parse signatureCipher: $e');
        debugPrint('  signatureCipher preview: ${signatureCipher.substring(0, signatureCipher.length > 200 ? 200 : signatureCipher.length)}...');
        debugPrint('  Stack trace: $stackTrace');
        // Fall back to direct url field if available
      }
    }

    // Also check if url field exists but signatureCipher was not used
    if (url == null || url.isEmpty) {
      url = formatData['url'] as String?;
      if (url != null && url.isNotEmpty) {
        debugPrint('Using direct url field for format $itag (no signatureCipher)');
      }
    }

    // Check if URL has 'n' parameter (n challenge - also needs decryption)
    // Similar to signatureCipher, we'll include it but mark it as needing decryption
    if (url != null) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.queryParameters.containsKey('n')) {
        debugPrint('⚠️  Format has n challenge parameter - may require JavaScript decryption');
        debugPrint('  ⚠️  This format may result in 403 Forbidden without decryption');
        debugPrint('  ⚠️  Will try to use this format if no alternatives are available');

        // Mark in format note that it needs decryption
        formatNote = '${formatNote ?? 'unknown'} (n challenge - may need JS decryption)';
        // Keep the URL - let the downloader try it first
      }
    }

    // Validate URL
    if (url == null || url.isEmpty) {
      debugPrint('⚠️  Format URL is null or empty - skipping format (itag: $itag)');
      // Return format with null URL instead of throwing - allows other formats to be used
      return VideoFormat(
        formatId: itag,
        url: null,
        manifestUrl: manifestUrl,
        ext: ext,
        width: width,
        height: height,
        fps: fps,
        vcodec: vcodec,
        acodec: acodec,
        filesize: filesize,
        tbr: tbr,
        protocol: null,
        hasVideo: hasVideo,
        hasAudio: hasAudio,
        formatNote: formatNote,
        qualityLabel: qualityLabel,
        language: language,
        languagePreference: languagePreference,
        audioSampleRate: _toInt(formatData['audioSampleRate']),
        audioChannels: _toInt(formatData['audioChannels']),
        hasDrm: hasDrm,
        httpHeaders: httpHeaders,
      );
    }

    return VideoFormat(
      formatId: itag,
      url: url,
      manifestUrl: manifestUrl,
      ext: ext,
      width: width,
      height: height,
      fps: fps,
      vcodec: vcodec,
      acodec: acodec,
      filesize: filesize,
      tbr: tbr,
      protocol: url.startsWith('http') ? 'https' : null,
      hasVideo: hasVideo,
      hasAudio: hasAudio,
      formatNote: formatNote,
      qualityLabel: qualityLabel,
      language: language,
      languagePreference: languagePreference,
      audioSampleRate: _toInt(formatData['audioSampleRate']),
      audioChannels: _toInt(formatData['audioChannels']),
      hasDrm: hasDrm,
      httpHeaders: httpHeaders,
    );
  }

  /// Extract nested value from map using path
  dynamic _extractNestedValue(Map? data, List path) {
    if (data == null) return null;
    dynamic current = data;
    for (var segment in path) {
      if (segment is bool Function(dynamic)) {
        if (current is List) {
          try {
            current = current.firstWhere(segment, orElse: () => null);
          } catch (e) {
            return null;
          }
        } else {
          return null;
        }
      } else if (current is Map) {
        current = current[segment];
      } else {
        return null;
      }
      if (current == null) return null;
    }
    return current;
  }

  /// Extract like count from video primary info
  int? _extractLikeCount(Map? videoPrimaryInfo) {
    if (videoPrimaryInfo == null) return null;

    // Try to find like button
    final videoActions = videoPrimaryInfo['videoActions'] as Map?;
    final menuRenderer = videoActions?['menuRenderer'] as Map?;
    final topLevelButtons = menuRenderer?['topLevelButtons'] as List?;

    if (topLevelButtons != null) {
      for (var button in topLevelButtons) {
        final buttonMap = button as Map?;
        final toggleButton = buttonMap?['toggleButtonRenderer'] as Map?;
        if (toggleButton != null) {
          final defaultText = toggleButton['defaultText'] as Map?;
          final simpleText = defaultText?['simpleText'] as String?;
          if (simpleText != null) {
            // Extract number from text like "1.2K" or "1,234"
            final cleaned = simpleText.replaceAll(RegExp(r'[^\d.]'), '');
            final number = double.tryParse(cleaned);
            if (number != null) {
              // Handle K, M suffixes
              if (simpleText.contains('K')) {
                return (number * 1000).round();
              } else if (simpleText.contains('M')) {
                return (number * 1000000).round();
              }
              return number.round();
            }
          }
        }
      }
    }
    return null;
  }

  /// Extract tags from initial data
  List<String>? _extractTags(Map? initialData) {
    if (initialData == null) return null;

    // Simplified tag extraction - YouTube structure is complex
    // This is a basic implementation
    // Tags are typically in videoSecondaryInfoRenderer but the structure is complex
    return null;
  }

  /// Extract categories from initial data
  List<String>? _extractCategories(Map? initialData) {
    // Categories are typically in microformat
    return null;
  }

  /// Extract channel information
  Map<String, dynamic> _extractChannelInfo(Map? initialData) {
    final result = <String, dynamic>{};

    if (initialData != null) {
      final channelInfo = _extractNestedValue(initialData, [
        'contents',
        'twoColumnWatchNextResults',
        'results',
        'results',
        'contents',
        (v) {
          if (v is! Map) return false;
          return v.containsKey('videoSecondaryInfoRenderer');
        },
        'videoSecondaryInfoRenderer',
        'owner',
        'videoOwnerRenderer',
      ]);

      if (channelInfo is Map) {
        result['name'] = channelInfo['title']?['runs']?[0]?['text'] as String?;
        result['followerCount'] = null; // Complex to extract
        result['isVerified'] = channelInfo['badges'] != null;
      }
    }

    return result;
  }

  /// Extract JSON from script tag
  /// Following yt-dlp's pattern: r'ytInitialPlayerResponse\s*='
  Map<String, dynamic>? _extractJsonFromScript(String html, String prefix) {
    // Find the start position of the JSON
    // yt-dlp uses: r'ytInitialPlayerResponse\s*=' which matches "ytInitialPlayerResponse" followed by optional whitespace and "="
    int prefixIndex = -1;
    String? matchedPrefix;

    // Try patterns matching yt-dlp's regex: prefix\s*=
    // Pattern 1: prefix = (with space)
    // Pattern 2: prefix= (without space)
    // Pattern 3: var prefix =
    // Pattern 4: let prefix =
    // Pattern 5: const prefix =
    final patterns = [
      RegExp('${RegExp.escape(prefix)}\\s*=', caseSensitive: false), // Matches yt-dlp's pattern exactly
      RegExp('var\\s+${RegExp.escape(prefix)}\\s*=', caseSensitive: false),
      RegExp('let\\s+${RegExp.escape(prefix)}\\s*=', caseSensitive: false),
      RegExp('const\\s+${RegExp.escape(prefix)}\\s*=', caseSensitive: false),
      RegExp('window\\["${RegExp.escape(prefix)}"\\]\\s*=', caseSensitive: false),
      RegExp("window\\['${RegExp.escape(prefix)}'\\]\\s*=", caseSensitive: false),
    ];

    for (var i = 0; i < patterns.length; i++) {
      final pattern = patterns[i];
      final match = pattern.firstMatch(html);
      if (match != null) {
        prefixIndex = match.start;
        matchedPrefix = match.group(0);
        debugPrint('  ✓ Found prefix pattern $i: "$matchedPrefix" at position $prefixIndex');
        break;
      } else {
        debugPrint('  ✗ Pattern $i did not match');
      }
    }

    // If still not found, try simple indexOf as fallback
    if (prefixIndex == -1) {
      debugPrint('  Trying simple indexOf for "$prefix"...');
      prefixIndex = html.indexOf(prefix);
      if (prefixIndex != -1) {
        debugPrint('  ✓ Found prefix "$prefix" at position $prefixIndex (simple match)');
        // Try to find the assignment operator after the prefix
        int afterPrefix = prefixIndex + prefix.length;
        int maxSearch = (afterPrefix + 100).clamp(0, html.length);
        final afterText = html.substring(afterPrefix, maxSearch);
        debugPrint('  Text after prefix (first 100 chars): ${afterText.substring(0, afterText.length > 100 ? 100 : afterText.length)}');
      } else {
        debugPrint('  ✗ Prefix "$prefix" not found even with simple indexOf');
      }
    }

    if (prefixIndex == -1) {
      debugPrint('  ✗ Prefix "$prefix" not found in HTML');
      // Try to find similar strings for debugging
      final similarMatches = RegExp(prefix.substring(0, prefix.length > 10 ? 10 : prefix.length), caseSensitive: false).allMatches(html);
      debugPrint('  Found ${similarMatches.length} similar matches (first 10 chars of prefix)');
      return null;
    }

    // Find the opening brace after the prefix
    // Skip whitespace and potential assignment operators
    // Use matchedPrefix length if available, otherwise use prefix length
    final prefixLength = matchedPrefix?.length ?? prefix.length;
    int searchStart = prefixIndex + prefixLength;
    while (searchStart < html.length && (html[searchStart] == ' ' || html[searchStart] == '\t' || html[searchStart] == '\n' || html[searchStart] == '\r' || html[searchStart] == '=')) {
      searchStart++;
    }

    debugPrint('  Starting search for opening brace at position $searchStart');

    // Show context around the search start
    final contextStart = (searchStart - 50).clamp(0, html.length);
    final contextEnd = (searchStart + 200).clamp(0, html.length);
    final context = html.substring(contextStart, contextEnd);
    debugPrint('  Context around search start: ${context.replaceAll('\n', '\\n').replaceAll('\r', '\\r')}');

    final startIndex = html.indexOf('{', searchStart);
    if (startIndex == -1) {
      debugPrint('  ✗ Could not find opening brace "{" after position $searchStart');
      // Show more context
      final moreContext = html.substring(searchStart, (searchStart + 500).clamp(0, html.length));
      debugPrint('  Next 500 chars: ${moreContext.substring(0, moreContext.length > 200 ? 200 : moreContext.length)}');
      return null;
    }

    debugPrint('  ✓ Found opening brace at position $startIndex');

    // Parse JSON by finding matching braces
    // Note: YouTube's JSON can be very large (several MB), so we need to be careful
    int braceCount = 0;
    int endIndex = startIndex;
    bool inString = false;
    bool escaped = false;
    int maxSearchLength = 5000000; // Increased limit to 5MB to handle large JSON objects
    int searchLength = (html.length - startIndex).clamp(0, maxSearchLength);

    debugPrint('  Searching for closing brace, max search length: $searchLength');

    for (int i = startIndex; i < startIndex + searchLength; i++) {
      final char = html[i];

      if (escaped) {
        escaped = false;
        continue;
      }

      if (char == '\\') {
        escaped = true;
        continue;
      }

      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (!inString) {
        if (char == '{') {
          braceCount++;
        } else if (char == '}') {
          braceCount--;
          if (braceCount == 0) {
            endIndex = i + 1;
            debugPrint('  Found matching closing brace at position $endIndex (searched ${i - startIndex} chars)');
            break;
          }
        }
      }

      // Progress indicator for very large JSON
      if ((i - startIndex) % 100000 == 0 && i > startIndex) {
        debugPrint('  Progress: searched ${i - startIndex} chars, braceCount: $braceCount');
      }
    }

    // If we reached the end without finding the closing brace, the JSON might be incomplete
    if (braceCount != 0 && endIndex == startIndex) {
      debugPrint('  ⚠️  Reached search limit without finding closing brace. braceCount: $braceCount');
      debugPrint('  This might indicate the JSON object is larger than $maxSearchLength bytes');
    }

    if (braceCount != 0) {
      // JSON not properly closed, try simpler approach
      debugPrint('  ✗ JSON not properly closed (braceCount: $braceCount), trying simpler approach');
      return _extractJsonSimple(html, prefix);
    }

    debugPrint('  ✓ Found complete JSON object from position $startIndex to $endIndex (length: ${endIndex - startIndex})');

    try {
      final jsonStr = html.substring(startIndex, endIndex);
      debugPrint('  Extracted JSON string length: ${jsonStr.length}');
      debugPrint('  First 200 chars: ${jsonStr.substring(0, jsonStr.length > 200 ? 200 : jsonStr.length)}');

      // Remove any trailing semicolon or whitespace
      var cleaned = jsonStr.trim();

      // Remove trailing semicolon if present
      if (cleaned.endsWith(';')) {
        cleaned = cleaned.substring(0, cleaned.length - 1).trim();
      }

      // Validate JSON string is not empty and starts/ends correctly
      if (cleaned.isEmpty || !cleaned.startsWith('{') || !cleaned.endsWith('}')) {
        debugPrint('  ✗ JSON string validation failed: empty=${cleaned.isEmpty}, startsWith{=${cleaned.startsWith('{')}, endsWith}=${cleaned.endsWith('}')}');
        return _extractJsonSimple(html, prefix);
      }

      debugPrint('  Attempting to decode JSON...');
      // Try to decode JSON
      final decoded = json.decode(cleaned) as Map<String, dynamic>;
      debugPrint('  ✓ Successfully decoded JSON with ${decoded.length} top-level keys');
      debugPrint('  Keys: ${decoded.keys.take(10).toList()}');
      return decoded;
    } catch (e) {
      // If decoding fails, try simpler extraction method
      if (e is FormatException) {
        // FormatException - check if it's a UTF-8 issue
        final errorMsg = e.toString();
        if (errorMsg.contains('extension byte') || errorMsg.contains('Invalid UTF-8')) {
          // Try to clean the JSON string of invalid characters
          try {
            final jsonStr = html.substring(startIndex, endIndex);
            var cleaned = jsonStr.trim();
            if (cleaned.endsWith(';')) {
              cleaned = cleaned.substring(0, cleaned.length - 1).trim();
            }
            // Remove invalid UTF-8 characters
            final bytes = utf8.encode(cleaned);
            final cleanedStr = utf8.decode(bytes, allowMalformed: true);
            return json.decode(cleanedStr) as Map<String, dynamic>;
          } catch (e2) {
            // Still failed, try simpler method
            return _extractJsonSimple(html, prefix);
          }
        }
        // Other FormatException, try simpler method
        return _extractJsonSimple(html, prefix);
      }
      // For other exceptions, also try simpler method
      return _extractJsonSimple(html, prefix);
    }
  }

  /// Simple JSON extraction using regex (fallback)
  Map<String, dynamic>? _extractJsonSimple(String html, String prefix) {
    // Try multiple regex patterns
    final patterns = [
      // Standard pattern: prefix followed by JSON object ending with semicolon
      RegExp(
        '${RegExp.escape(prefix)}\\s*=\\s*(\\{.*?\\});',
        dotAll: true,
        caseSensitive: false,
      ),
      // Pattern without assignment operator
      RegExp(
        '${RegExp.escape(prefix)}\\s*(\\{.*?\\});',
        dotAll: true,
        caseSensitive: false,
      ),
      // Pattern with quotes
      RegExp(
        '${RegExp.escape(prefix)}\\s*[=:]\\s*["\']?(\\{.*?\\})["\']?;',
        dotAll: true,
        caseSensitive: false,
      ),
    ];

    for (var pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match == null) continue;

      try {
        final jsonStrNullable = match.group(1);
        if (jsonStrNullable == null) continue;

        // Clean up the JSON string - now we know it's not null
        String jsonStr = jsonStrNullable.trim();

        // Remove trailing semicolon if present
        while (jsonStr.isNotEmpty && (jsonStr.endsWith(';') || jsonStr.endsWith(','))) {
          jsonStr = jsonStr.substring(0, jsonStr.length - 1).trim();
        }

        // Validate JSON string
        if (jsonStr.isEmpty || !jsonStr.startsWith('{') || !jsonStr.endsWith('}')) {
          continue;
        }

        // Try to decode
        try {
          return json.decode(jsonStr) as Map<String, dynamic>;
        } catch (e) {
          // If FormatException with UTF-8 issue, try to clean
          if (e is FormatException && e.toString().contains('extension byte')) {
            try {
              final bytes = utf8.encode(jsonStr);
              final cleanedStr = utf8.decode(bytes, allowMalformed: true);
              return json.decode(cleanedStr) as Map<String, dynamic>;
            } catch (e2) {
              continue; // Try next pattern
            }
          }
          continue; // Try next pattern
        }
      } catch (e) {
        continue; // Try next pattern
      }
    }

    // If all patterns fail, try advanced extraction
    return _extractJsonAdvanced(html, prefix);
  }

  /// Advanced JSON extraction with better error handling
  Map<String, dynamic>? _extractJsonAdvanced(String html, String prefix) {
    final prefixIndex = html.indexOf(prefix);
    if (prefixIndex == -1) return null;

    // Look for the JSON object more carefully
    // Find all possible JSON objects after the prefix
    final startPos = prefixIndex + prefix.length;
    final endPos = startPos + 100000 > html.length ? html.length : startPos + 100000;
    final searchArea = html.substring(startPos, endPos);

    // Try to find JSON by matching braces more carefully
    int startBrace = searchArea.indexOf('{');
    if (startBrace == -1) return null;

    // Count braces to find the matching closing brace
    int braceCount = 0;
    bool inString = false;
    bool escaped = false;
    int? endBrace;

    for (int i = startBrace; i < searchArea.length; i++) {
      final char = searchArea[i];

      if (escaped) {
        escaped = false;
        continue;
      }

      if (char == '\\') {
        escaped = true;
        continue;
      }

      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (!inString) {
        if (char == '{') {
          braceCount++;
        } else if (char == '}') {
          braceCount--;
          if (braceCount == 0) {
            endBrace = i + 1;
            break;
          }
        }
      }
    }

    if (endBrace == null) return null;

    try {
      final jsonStr = searchArea.substring(startBrace, endBrace);
      final cleaned = jsonStr.trim();

      // Validate
      if (cleaned.isEmpty || !cleaned.startsWith('{') || !cleaned.endsWith('}')) {
        return null;
      }

      final decoded = json.decode(cleaned) as Map<String, dynamic>;
      // Check if it looks like a valid YouTube response
      if (decoded.containsKey('videoDetails') || decoded.containsKey('streamingData') || decoded.containsKey('responseContext') || decoded.containsKey('playabilityStatus')) {
        return decoded;
      }
    } catch (e) {
      // If still fails, return null
      return null;
    }

    return null;
  }

  /// Decrypt formats that need JavaScript decryption
  Future<void> _decryptFormats(
    List<VideoFormat> formats,
    String videoId,
    String html,
  ) async {
    if (_jscDirector == null) {
      debugPrint('[jsc] JSC Director is null, skipping decryption');
      return;
    }

    // Try to ensure solver is available (may need to wait for initialization)
    if (!_jscDirector!.isAvailable()) {
      debugPrint('[jsc] JSC Director not available yet, attempting to wait for initialization...');
      // Give it a moment to initialize (async initialization may be in progress)
      await Future.delayed(Duration(milliseconds: 500));
      if (!_jscDirector!.isAvailable()) {
        debugPrint('[jsc] JSC Director still not available after waiting, skipping decryption');
        return;
      }
    }

    // Extract player URL from HTML or ytcfg
    String? playerUrl = _extractPlayerUrl(html);
    if (playerUrl == null) {
      debugPrint('[jsc] Could not extract player URL, skipping decryption');
      return;
    }

    debugPrint('[jsc] Player URL: $playerUrl');

    // Collect formats that need decryption
    final sigChallenges = <String, List<VideoFormat>>{};
    final nChallenges = <String, List<VideoFormat>>{};

    debugPrint('[jsc] Scanning ${formats.length} formats for decryption requirements...');

    for (final format in formats) {
      if (format.url == null) {
        debugPrint('[jsc] Format ${format.formatId} has null URL, skipping');
        continue;
      }

      final uri = Uri.tryParse(format.url!);
      if (uri == null) {
        debugPrint('[jsc] Format ${format.formatId} has invalid URL, skipping');
        continue;
      }

      // Check for encrypted signature
      // YouTube may use 's' parameter (encrypted) or 'sig' parameter (may need decryption)
      final sParam = uri.queryParameters['s'];
      final sigParam = uri.queryParameters['sig'];

      // If we have 's' parameter, it's definitely encrypted
      // If we have 'sig' but format note says encrypted, it may still need decryption
      if (sParam != null) {
        // 's' parameter is encrypted, needs decryption
        sigChallenges.putIfAbsent(sParam, () => []).add(format);
        final preview = sParam.length > 20 ? '${sParam.substring(0, 20)}...' : sParam;
        debugPrint('[jsc] Format ${format.formatId} has encrypted signature (s parameter): $preview');
      } else if (sigParam != null && format.formatNote?.contains('encrypted') == true) {
        // 'sig' parameter exists but format note indicates it may be encrypted
        // Try to decrypt it (though it might already be decrypted)
        sigChallenges.putIfAbsent(sigParam, () => []).add(format);
        final preview = sigParam.length > 20 ? '${sigParam.substring(0, 20)}...' : sigParam;
        debugPrint('[jsc] Format ${format.formatId} has sig parameter marked as encrypted: $preview');
      }

      // Check for n challenge - always needs decryption if present
      final nParam = uri.queryParameters['n'];
      if (nParam != null) {
        // n parameter always needs decryption, regardless of format note
        nChallenges.putIfAbsent(nParam, () => []).add(format);
        final preview = nParam.length > 20 ? '${nParam.substring(0, 20)}...' : nParam;
        debugPrint('[jsc] Format ${format.formatId} has n challenge parameter: $preview');
      }
    }

    debugPrint('[jsc] Found ${sigChallenges.length} unique signature challenges and ${nChallenges.length} unique n challenges');

    // Solve signature challenges
    if (sigChallenges.isNotEmpty) {
      debugPrint('[jsc] Found ${sigChallenges.length} unique signature challenges');
      try {
        final requests = [
          JsChallengeRequest(
            type: JsChallengeType.sig,
            videoId: videoId,
            input: SigChallengeInput(
              playerUrl: playerUrl,
              challenges: sigChallenges.keys.toList(),
            ),
          ),
        ];

        final responses = await _jscDirector!.bulkSolve(requests);
        for (final response in responses) {
          if (response.error != null) {
            debugPrint('[jsc] Error decrypting signature: ${response.error}');
            continue;
          }

          if (response.response?.type == JsChallengeType.sig) {
            final output = response.response!.output as SigChallengeOutput;
            for (final entry in output.results.entries) {
              final encryptedSig = entry.key;
              final decryptedSig = entry.value;
              final formatsToUpdate = sigChallenges[encryptedSig] ?? [];

              for (var i = 0; i < formatsToUpdate.length; i++) {
                final format = formatsToUpdate[i];

                // Find format in current formats list by formatId (not by object reference)
                // This is necessary because formats may have been updated by DASH manifest
                final formatId = format.formatId;
                if (formatId == null) {
                  debugPrint('[jsc] ⚠️  Format has null formatId, skipping signature decryption');
                  continue;
                }

                final formatIndex = formats.indexWhere((f) => f.formatId == formatId);
                if (formatIndex < 0) {
                  debugPrint('[jsc] ⚠️  Format $formatId not found in formats list, skipping signature decryption');
                  continue;
                }

                final currentFormat = formats[formatIndex];
                if (currentFormat.url == null || currentFormat.url!.isEmpty) {
                  debugPrint('[jsc] ⚠️  Format $formatId has null/empty URL, skipping signature decryption');
                  continue;
                }

                final uri = Uri.tryParse(currentFormat.url!);
                if (uri == null) {
                  debugPrint('[jsc] ⚠️  Format $formatId has invalid URL, skipping signature decryption');
                  continue;
                }

                final queryParams = Map<String, String>.from(uri.queryParameters);

                // Get the signature parameter name (sp) from httpHeaders
                // This was saved during signatureCipher parsing
                // Default to 'sig' if not found (matches yt-dlp's default)
                final spParam = currentFormat.httpHeaders?['_sp_param'] as String? ?? 'sig';

                // Replace encrypted signature with decrypted one
                // Remove 's' if present (encrypted), also remove any existing sig/signature
                if (queryParams.containsKey('s')) {
                  // Remove encrypted 's' parameter
                  queryParams.remove('s');
                }
                // Remove any existing signature parameters (might be from previous attempts)
                queryParams.remove('sig');
                queryParams.remove('signature');

                // Use the correct parameter name (sp) from signatureCipher
                queryParams[spParam] = decryptedSig;

                debugPrint('[jsc] Using signature parameter name "$spParam" (from signatureCipher sp)');

                final newUrl = uri.replace(queryParameters: queryParams).toString();
                // Update format note to clearly indicate decryption was successful
                String? newFormatNote;
                if (currentFormat.formatNote != null) {
                  newFormatNote = currentFormat.formatNote!.replaceAll('encrypted - may need JS decryption', 'decrypted').replaceAll('(encrypted', '(decrypted').replaceAll('encrypted', 'decrypted');
                  // Ensure it's marked as decrypted
                  if (!newFormatNote.contains('decrypted')) {
                    newFormatNote = '${newFormatNote} (decrypted)';
                  }
                } else {
                  newFormatNote = 'decrypted';
                }

                // Replace format in list with new one
                formats[formatIndex] = VideoFormat(
                  formatId: currentFormat.formatId,
                  url: newUrl,
                  manifestUrl: currentFormat.manifestUrl,
                  ext: currentFormat.ext,
                  width: currentFormat.width,
                  height: currentFormat.height,
                  fps: currentFormat.fps,
                  vcodec: currentFormat.vcodec,
                  acodec: currentFormat.acodec,
                  filesize: currentFormat.filesize,
                  tbr: currentFormat.tbr,
                  protocol: currentFormat.protocol,
                  hasVideo: currentFormat.hasVideo,
                  hasAudio: currentFormat.hasAudio,
                  formatNote: newFormatNote,
                  qualityLabel: currentFormat.qualityLabel,
                  language: currentFormat.language,
                  languagePreference: currentFormat.languagePreference,
                  audioSampleRate: currentFormat.audioSampleRate,
                  audioChannels: currentFormat.audioChannels,
                  hasDrm: currentFormat.hasDrm,
                  httpHeaders: currentFormat.httpHeaders,
                );

                debugPrint('[jsc] ✓ Decrypted signature for format $formatId');
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[jsc] Failed to decrypt signatures: $e');
      }
    }

    // Solve n challenges
    if (nChallenges.isNotEmpty) {
      debugPrint('[jsc] Found ${nChallenges.length} unique n challenges');
      try {
        final requests = [
          JsChallengeRequest(
            type: JsChallengeType.n,
            videoId: videoId,
            input: NChallengeInput(
              playerUrl: playerUrl,
              challenges: nChallenges.keys.toList(),
            ),
          ),
        ];

        debugPrint('[jsc] Calling bulkSolve for ${nChallenges.length} n challenges...');
        final responses = await _jscDirector!.bulkSolve(requests);
        debugPrint('[jsc] Received ${responses.length} responses from bulkSolve');

        for (final response in responses) {
          if (response.error != null) {
            debugPrint('[jsc] ✗ Error decrypting n challenge: ${response.error}');
            continue;
          }

          if (response.response?.type == JsChallengeType.n) {
            final output = response.response!.output as NChallengeOutput;
            debugPrint('[jsc] ✓ Got n challenge response with ${output.results.length} results');

            for (final entry in output.results.entries) {
              final encryptedN = entry.key;
              final decryptedN = entry.value;
              debugPrint('[jsc] Decrypting n challenge: ${encryptedN.substring(0, encryptedN.length > 20 ? 20 : encryptedN.length)}... -> ${decryptedN.substring(0, decryptedN.length > 20 ? 20 : decryptedN.length)}...');

              final formatsToUpdate = nChallenges[encryptedN] ?? [];
              debugPrint('[jsc] Updating ${formatsToUpdate.length} formats with decrypted n challenge');

              for (var i = 0; i < formatsToUpdate.length; i++) {
                final format = formatsToUpdate[i];

                // Find format in current formats list by formatId (not by object reference)
                // This is necessary because formats may have been updated by DASH manifest
                final formatId = format.formatId;
                if (formatId == null) {
                  debugPrint('[jsc] ⚠️  Format has null formatId, skipping n challenge decryption');
                  continue;
                }

                final formatIndex = formats.indexWhere((f) => f.formatId == formatId);
                if (formatIndex < 0) {
                  debugPrint('[jsc] ⚠️  Format $formatId not found in formats list, skipping n challenge decryption');
                  continue;
                }

                final currentFormat = formats[formatIndex];
                if (currentFormat.url == null || currentFormat.url!.isEmpty) {
                  debugPrint('[jsc] ⚠️  Format $formatId has null/empty URL, skipping n challenge decryption');
                  continue;
                }

                final uri = Uri.tryParse(currentFormat.url!);
                if (uri == null) {
                  debugPrint('[jsc] ⚠️  Format $formatId has invalid URL, skipping n challenge decryption');
                  continue;
                }

                final queryParams = Map<String, String>.from(uri.queryParameters);
                final oldN = queryParams['n'];

                // Check if current URL has n parameter that matches the encrypted one
                // If not, the format may have been updated by DASH manifest, but we still need to decrypt
                if (oldN != null && oldN == encryptedN) {
                  // Direct match - update it
                  queryParams['n'] = decryptedN;
                } else if (oldN != null && oldN != encryptedN) {
                  // n parameter exists but doesn't match - this means it might have been updated
                  // Check if URL contains the encrypted n parameter (might be URL encoded)
                  final encodedEncryptedN = Uri.encodeComponent(encryptedN);
                  if (currentFormat.url!.contains(encryptedN) || currentFormat.url!.contains(encodedEncryptedN)) {
                    // URL still contains encrypted n, update it
                    queryParams['n'] = decryptedN;
                    debugPrint('[jsc] ⚠️  Format $formatId n parameter mismatch but URL contains encrypted n, updating anyway');
                  } else {
                    // URL doesn't contain encrypted n, might have been updated already or is a different challenge
                    debugPrint('[jsc] ⚠️  Format $formatId n parameter mismatch: expected "${encryptedN.substring(0, encryptedN.length > 20 ? 20 : encryptedN.length)}...", got "${oldN.substring(0, oldN.length > 20 ? 20 : oldN.length)}..."');
                    debugPrint('[jsc] ⚠️  URL does not contain encrypted n parameter, skipping decryption for this format');
                    continue;
                  }
                } else {
                  // n parameter doesn't exist - check if URL contains encrypted n (might be from original format)
                  final encodedEncryptedN = Uri.encodeComponent(encryptedN);
                  if (currentFormat.url!.contains(encryptedN) || currentFormat.url!.contains(encodedEncryptedN)) {
                    // URL contains encrypted n even though it's not in query params (might be URL-encoded differently)
                    // Add decrypted n to query params
                    queryParams['n'] = decryptedN;
                    debugPrint('[jsc] ⚠️  Format $formatId n parameter missing from query but found in URL, adding decrypted n');
                  } else {
                    // Format doesn't have n parameter at all - might have been updated by DASH manifest
                    debugPrint('[jsc] ⚠️  Format $formatId does not have n parameter, skipping (may have been updated by DASH manifest)');
                    continue;
                  }
                }

                final newUrl = uri.replace(queryParameters: queryParams).toString();
                final oldNPreview = oldN != null && oldN.length > 20 ? '${oldN.substring(0, 20)}...' : oldN ?? 'null';
                final decryptedNPreview = decryptedN.length > 20 ? '${decryptedN.substring(0, 20)}...' : decryptedN;
                debugPrint('[jsc] Updated URL for format $formatId: n=$oldNPreview -> n=$decryptedNPreview');

                // Update format note to clearly indicate n challenge decryption was successful
                String? newFormatNote;
                if (currentFormat.formatNote != null) {
                  newFormatNote = currentFormat.formatNote!.replaceAll('n challenge - may need JS decryption', 'n challenge decrypted').replaceAll('n challenge', 'n challenge decrypted');
                  // Ensure it's marked as decrypted
                  if (!newFormatNote.contains('decrypted')) {
                    newFormatNote = '${newFormatNote} (n challenge decrypted)';
                  }
                } else {
                  newFormatNote = 'n challenge decrypted';
                }

                // Replace format in list with new one
                formats[formatIndex] = VideoFormat(
                  formatId: currentFormat.formatId,
                  url: newUrl,
                  manifestUrl: currentFormat.manifestUrl,
                  ext: currentFormat.ext,
                  width: currentFormat.width,
                  height: currentFormat.height,
                  fps: currentFormat.fps,
                  vcodec: currentFormat.vcodec,
                  acodec: currentFormat.acodec,
                  filesize: currentFormat.filesize,
                  tbr: currentFormat.tbr,
                  protocol: currentFormat.protocol,
                  hasVideo: currentFormat.hasVideo,
                  hasAudio: currentFormat.hasAudio,
                  formatNote: newFormatNote,
                  qualityLabel: currentFormat.qualityLabel,
                  language: currentFormat.language,
                  languagePreference: currentFormat.languagePreference,
                  audioSampleRate: currentFormat.audioSampleRate,
                  audioChannels: currentFormat.audioChannels,
                  hasDrm: currentFormat.hasDrm,
                  httpHeaders: currentFormat.httpHeaders,
                );

                debugPrint('[jsc] ✓ Decrypted n challenge for format $formatId');
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[jsc] Failed to decrypt n challenges: $e');
      }
    }
  }

  /// Extract player JavaScript URL from HTML
  String? _extractPlayerUrl(String html) {
    // Try to extract from ytcfg
    final ytcfgPattern = RegExp(r'ytcfg\.set\(({[^}]+})\)', dotAll: true);
    final ytcfgMatch = ytcfgPattern.firstMatch(html);
    if (ytcfgMatch != null) {
      try {
        final ytcfgJson = json.decode(ytcfgMatch.group(1)!) as Map;
        final playerUrl = ytcfgJson['PLAYER_JS_URL'] as String?;
        if (playerUrl != null) {
          return playerUrl.startsWith('http') ? playerUrl : 'https://www.youtube.com$playerUrl';
        }
      } catch (e) {
        // Continue to other methods
      }
    }

    // Try to extract from embedded JSON
    final playerUrlPattern = RegExp(r'"PLAYER_JS_URL"\s*:\s*"([^"]+)"');
    final playerUrlMatch = playerUrlPattern.firstMatch(html);
    if (playerUrlMatch != null) {
      final playerUrl = playerUrlMatch.group(1)!;
      return playerUrl.startsWith('http') ? playerUrl : 'https://www.youtube.com$playerUrl';
    }

    return null;
  }

  /// Extract formats from DASH manifest (MPD XML)
  /// This method downloads the MPD manifest and extracts format information,
  /// matching it with formats that don't have URLs from adaptiveFormats
  Future<List<VideoFormat>> _extractFormatsFromDashManifest(
    String dashManifestUrl,
    String videoId,
    List<VideoFormat> formatsWithoutUrl,
  ) async {
    final dashFormats = <VideoFormat>[];

    // Use RetryManager for DASH manifest download
    for (final retry in RetryManager(
      retries: extractorRetries,
      sleepFunction: retrySleepFunction ?? RetryManager.exponentialBackoff,
      fatal: false, // Don't throw, return empty list on failure
    ).iterable) {
      try {
        logger.info('youtube_extractor', 'Downloading DASH manifest from: $dashManifestUrl');
        final response = await _client.get(Uri.parse(dashManifestUrl), headers: _defaultHeaders);

        if (response.statusCode != 200) {
          // Retry on 5xx errors and some 4xx errors (but not 403, 404, 429)
          if (response.statusCode >= 500 || (response.statusCode >= 400 && response.statusCode != 403 && response.statusCode != 404 && response.statusCode != 429)) {
            retry.error = Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
            continue;
          }
          // Non-retryable HTTP error
          logger.warning('youtube_extractor', 'Failed to download DASH manifest: HTTP ${response.statusCode}');
          return dashFormats;
        }

        final mpdXml = response.body;
        logger.info('youtube_extractor', 'Downloaded DASH manifest (${mpdXml.length} bytes)');

        // Parse MPD XML to extract format information (break out of retry loop on success)
        return await _parseDashManifest(mpdXml, formatsWithoutUrl, dashManifestUrl);
      } catch (e) {
        if (_shouldRetryError(e)) {
          retry.error = e;
          continue;
        }
        // Non-retryable error, return empty list
        logger.warning('youtube_extractor', 'Failed to download DASH manifest: $e');
        return dashFormats;
      }
    }

    // Retries exhausted, return empty list
    logger.warning('youtube_extractor', 'Failed to download DASH manifest after $extractorRetries retries');
    return dashFormats;
  }

  /// Parse DASH manifest XML and extract format information
  Future<List<VideoFormat>> _parseDashManifest(
    String mpdXml,
    List<VideoFormat> formatsWithoutUrl,
    String dashManifestUrl,
  ) async {
    final dashFormats = <VideoFormat>[];

    try {
      // Parse MPD XML to extract format information
      // We need to extract both itag (from Representation id or URL) and language (from Representation lang attribute)
      // Following yt-dlp's approach: extract lang from Representation element's lang attribute

      // Create a map of itag -> format info from formatsWithoutUrl
      final formatMap = <String, VideoFormat>{};
      for (var format in formatsWithoutUrl) {
        if (format.formatId != null) {
          formatMap[format.formatId.toString()] = format;
        }
      }

      // Parse MPD XML to extract Representation elements with id and lang attributes
      // MPD structure: <Representation id="251" lang="en">...</Representation>
      // Following yt-dlp: representation_id is the itag, lang is the language

      // Pattern to match BaseURL elements
      final baseUrlPattern = RegExp(r'<BaseURL>([^<]+)</BaseURL>');

      // Pattern to match Representation elements (with their content)
      // We'll extract id and lang from the Representation opening tag
      final representationBlockPattern = RegExp(
        r'<Representation[^>]*>.*?</Representation>',
        dotAll: true,
      );

      // Find all Representation blocks
      final representationBlocks = representationBlockPattern.allMatches(mpdXml);

      for (var blockMatch in representationBlocks) {
        final block = blockMatch.group(0);
        if (block == null) continue;

        // Extract id attribute (itag) - can be single or double quotes
        // Try double quotes first, then single quotes
        String? itag;
        var idMatch = RegExp(r'id="(\d+)"').firstMatch(block);
        if (idMatch != null) {
          itag = idMatch.group(1);
        } else {
          idMatch = RegExp(r"id='(\d+)'").firstMatch(block);
          if (idMatch != null) {
            itag = idMatch.group(1);
          }
        }
        if (itag == null) continue;

        // Extract lang attribute (language code) - can be single or double quotes
        // Following yt-dlp: lang = representation_attrib.get('lang')
        // Filter out invalid language codes: 'mul', 'und', 'zxx', 'mis'
        String? langFromMpd;
        var langMatch = RegExp(r'lang="([^"]+)"').firstMatch(block);
        if (langMatch != null) {
          final rawLang = langMatch.group(1);
          if (rawLang != null && rawLang != 'mul' && rawLang != 'und' && rawLang != 'zxx' && rawLang != 'mis') {
            langFromMpd = rawLang;
            logger.debug('youtube_extractor', 'Extracted language from MPD Representation (double quotes): "$langFromMpd" for itag $itag');
          }
        } else {
          langMatch = RegExp(r"lang='([^']+)'").firstMatch(block);
          if (langMatch != null) {
            final rawLang = langMatch.group(1);
            if (rawLang != null && rawLang != 'mul' && rawLang != 'und' && rawLang != 'zxx' && rawLang != 'mis') {
              langFromMpd = rawLang;
              logger.debug('youtube_extractor', 'Extracted language from MPD Representation (single quotes): "$langFromMpd" for itag $itag');
            }
          }
        }

        // Extract BaseURL from this Representation block
        final baseUrlMatch = baseUrlPattern.firstMatch(block);
        if (baseUrlMatch == null) continue;
        final baseUrl = baseUrlMatch.group(1);
        if (baseUrl == null) continue;

        // Find matching format from formatsWithoutUrl
        final originalFormat = formatMap[itag];

        if (originalFormat != null) {
          // Use language from MPD if available, otherwise fall back to originalFormat
          // yt-dlp prioritizes MPD language over adaptiveFormats language
          // IMPORTANT: If MPD has language, use it even if originalFormat already has language
          // This is because MPD language is more accurate (it's the actual stream language)
          final finalLanguage = langFromMpd ?? originalFormat.language;

          logger.info('youtube_extractor', 'DASH manifest format matching for itag $itag: MPD lang="$langFromMpd", originalFormat lang="${originalFormat.language}", final lang="$finalLanguage"');

          if (langFromMpd != null && originalFormat.language != null && langFromMpd != originalFormat.language) {
            logger.warning('youtube_extractor', '⚠️ Language mismatch for itag $itag: MPD has "$langFromMpd" but adaptiveFormat has "${originalFormat.language}". Using MPD language (more accurate).');
          } else if (langFromMpd != null) {
            logger.info('youtube_extractor', '✓ Using language "$langFromMpd" from MPD for itag $itag (originalFormat had: "${originalFormat.language}")');
          } else if (originalFormat.language != null) {
            logger.info('youtube_extractor', '⚠️ No language in MPD for itag $itag, using language "${originalFormat.language}" from adaptiveFormat');
          } else {
            logger.warning('youtube_extractor', '⚠️ No language found for itag $itag (neither in MPD nor in adaptiveFormat)');
          }

          // Create a new format with the URL and language from DASH manifest
          final dashFormat = VideoFormat(
            formatId: originalFormat.formatId,
            url: baseUrl,
            manifestUrl: dashManifestUrl,
            ext: originalFormat.ext,
            width: originalFormat.width,
            height: originalFormat.height,
            fps: originalFormat.fps,
            vcodec: originalFormat.vcodec,
            acodec: originalFormat.acodec,
            filesize: originalFormat.filesize,
            tbr: originalFormat.tbr,
            protocol: 'https',
            hasVideo: originalFormat.hasVideo,
            hasAudio: originalFormat.hasAudio,
            formatNote: originalFormat.formatNote,
            qualityLabel: originalFormat.qualityLabel,
            language: finalLanguage,
            languagePreference: originalFormat.languagePreference,
            audioSampleRate: originalFormat.audioSampleRate,
            audioChannels: originalFormat.audioChannels,
            hasDrm: originalFormat.hasDrm,
            httpHeaders: originalFormat.httpHeaders,
          );
          dashFormats.add(dashFormat);
          logger.info('youtube_extractor', '✓ Extracted format $itag from DASH manifest - URL: ${baseUrl.substring(0, baseUrl.length > 100 ? 100 : baseUrl.length)}..., language from MPD: ${langFromMpd ?? "null (using original: ${originalFormat.language})"}, final language: $finalLanguage');
        }
      }

      logger.info('youtube_extractor', 'Extracted ${dashFormats.length} formats from DASH manifest');
    } catch (e, stackTrace) {
      logger.error('youtube_extractor', 'Error parsing DASH manifest: $e');
      logger.debug('youtube_extractor', 'Stack trace: $stackTrace');
      // Return empty list on parse error
    }

    return dashFormats;
  }

  void dispose() {
    _client.close();
  }
}
