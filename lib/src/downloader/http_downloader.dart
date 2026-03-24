/// HTTP file downloader
library http_downloader;

import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import '../models/video_info.dart';
import '../utils/logger.dart';

/// Download status
enum DownloadStatus {
  downloading,
  finished,
  error,
}

/// Enhanced progress callback type (matching yt-dlp)
typedef ProgressCallback = void Function({
  required int downloadedBytes,
  int? totalBytes,
  required double progress,
  double? speed,
  double? eta, // Estimated time remaining in seconds
  double? elapsed, // Elapsed time in seconds
  required DownloadStatus status,
  String? tmpfilename,
  String? filename,
});

/// Download options (matching yt-dlp params)
class DownloadOptions {
  final int? retries;
  final bool continuedl; // Continue downloads
  final int? minFilesize;
  final int? maxFilesize;
  final int? rateLimit; // Rate limit in bytes/sec
  final int? throttledRateLimit; // Assume throttled below this speed
  final int buffersize; // Buffer size in bytes
  final bool noresizebuffer; // Don't auto-resize buffer
  final bool updatetime; // Use Last-modified header
  final bool test; // Test mode (download only first bytes)
  final int? testFileSize; // Size for test mode
  final bool verbose; // Enable verbose logging

  const DownloadOptions({
    this.retries = 10,
    this.continuedl = true,
    this.minFilesize,
    this.maxFilesize,
    this.rateLimit,
    this.throttledRateLimit,
    this.buffersize = 1024,
    this.noresizebuffer = false,
    this.updatetime = false,
    this.test = false,
    this.testFileSize,
    this.verbose = false,
  });
}

/// Retry manager (matching yt-dlp's RetryManager)
class RetryManager implements Iterable<RetryManager> {
  final int retries;
  final Function(dynamic error, int count, int retries)? errorCallback;
  int attempt = 0;
  dynamic _error;

  RetryManager(this.retries, [this.errorCallback]);

  dynamic get error => _error;
  set error(dynamic value) => _error = value;

  bool _shouldRetry() {
    // First attempt: attempt is 0, should always try
    // After first attempt: only retry if there was an error and we haven't exceeded retries
    return attempt == 0 || (_error != null && attempt <= retries);
  }

  @override
  Iterator<RetryManager> get iterator {
    return _RetryManagerIterator(this);
  }

  @override
  bool any(bool Function(RetryManager element) test) {
    throw UnimplementedError();
  }

  @override
  Iterable<R> cast<R>() {
    throw UnimplementedError();
  }

  @override
  bool contains(Object? element) {
    throw UnimplementedError();
  }

  @override
  RetryManager elementAt(int index) {
    throw UnimplementedError();
  }

  @override
  bool every(bool Function(RetryManager element) test) {
    throw UnimplementedError();
  }

  @override
  Iterable<T> expand<T>(Iterable<T> Function(RetryManager element) toElements) {
    throw UnimplementedError();
  }

  @override
  RetryManager get first => throw UnimplementedError();

  @override
  RetryManager firstWhere(bool Function(RetryManager element) test, {RetryManager Function()? orElse}) {
    throw UnimplementedError();
  }

  @override
  T fold<T>(T initialValue, T Function(T previousValue, RetryManager element) combine) {
    throw UnimplementedError();
  }

  @override
  Iterable<RetryManager> followedBy(Iterable<RetryManager> other) {
    throw UnimplementedError();
  }

  @override
  void forEach(void Function(RetryManager element) action) {
    throw UnimplementedError();
  }

  @override
  bool get isEmpty => throw UnimplementedError();

  @override
  bool get isNotEmpty => throw UnimplementedError();

  @override
  String join([String separator = '']) {
    throw UnimplementedError();
  }

  @override
  RetryManager get last => throw UnimplementedError();

  @override
  RetryManager lastWhere(bool Function(RetryManager element) test, {RetryManager Function()? orElse}) {
    throw UnimplementedError();
  }

  @override
  int get length => throw UnimplementedError();

  @override
  Iterable<T> map<T>(T Function(RetryManager e) toElement) {
    throw UnimplementedError();
  }

  @override
  RetryManager reduce(RetryManager Function(RetryManager value, RetryManager element) combine) {
    throw UnimplementedError();
  }

  @override
  RetryManager get single => throw UnimplementedError();

  @override
  RetryManager singleWhere(bool Function(RetryManager element) test, {RetryManager Function()? orElse}) {
    throw UnimplementedError();
  }

  @override
  Iterable<RetryManager> skip(int count) {
    throw UnimplementedError();
  }

  @override
  Iterable<RetryManager> skipWhile(bool Function(RetryManager value) test) {
    throw UnimplementedError();
  }

  @override
  Iterable<RetryManager> take(int count) {
    throw UnimplementedError();
  }

  @override
  Iterable<RetryManager> takeWhile(bool Function(RetryManager value) test) {
    throw UnimplementedError();
  }

  @override
  List<RetryManager> toList({bool growable = true}) {
    throw UnimplementedError();
  }

  @override
  Set<RetryManager> toSet() {
    throw UnimplementedError();
  }

  @override
  Iterable<RetryManager> where(bool Function(RetryManager element) test) {
    throw UnimplementedError();
  }

  @override
  Iterable<T> whereType<T>() {
    throw UnimplementedError();
  }
}

class _RetryManagerIterator implements Iterator<RetryManager> {
  final RetryManager _manager;
  RetryManager? _current;
  bool _firstCall = true;

  _RetryManagerIterator(this._manager);

  @override
  RetryManager get current => _current!;

  @override
  bool moveNext() {
    // First call: always yield (attempt 0 -> 1)
    if (_firstCall) {
      _firstCall = false;
      _manager._error = null;
      _manager.attempt = 1;
      _current = _manager;
      return true;
    }

    // Subsequent calls: check if we should retry
    if (!_manager._shouldRetry()) {
      return false;
    }
    
    _manager._error = null;
    _manager.attempt++;
    _current = _manager;
    return true;
  }
}

/// HTTP file downloader
class HttpDownloader {
  final http.Client _client;
  final DownloadOptions _options;

  HttpDownloader({
    http.Client? client,
    DownloadOptions? options,
  })  : _client = client ?? http.Client(),
        _options = options ?? const DownloadOptions();

  /// Log message (using unified logger)
  void _log(String message, {String level = 'info'}) {
    final logLevel = level == 'error'
        ? LogLevel.error
        : level == 'warning'
            ? LogLevel.warning
            : level == 'debug'
                ? LogLevel.debug
                : LogLevel.info;
    
    if (_options.verbose || logLevel >= LogLevel.warning) {
      logger.log(logLevel, message, tag: 'download');
    }
  }

  /// Log error
  void _logError(String message) => _log(message, level: 'error');

  /// Log warning
  void _logWarning(String message) => _log(message, level: 'warning');

  /// Log debug
  void _logDebug(String message) => _log(message, level: 'debug');

  /// Calculate download speed (bytes/sec)
  static double? calcSpeed(double start, double now, int bytes) {
    final diff = now - start;
    if (bytes == 0 || diff < 0.001) {
      return null;
    }
    return bytes / diff;
  }

  /// Calculate ETA (estimated time remaining in seconds)
  static double? calcEta(double start, double now, int? total, int current) {
    if (total == null) {
      return null;
    }
    final rate = calcSpeed(start, now, current);
    if (rate == null || rate == 0) {
      return null;
    }
    final remaining = total - current;
    if (remaining <= 0) {
      return 0.0;
    }
    return remaining / rate;
  }

  /// Format bytes
  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KiB';
    } else {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
    }
  }

  /// Format speed string
  static String formatSpeed(double? speed) {
    if (speed == null) {
      return 'Unknown B/s';
    }
    if (speed < 1024) {
      return '${speed.toStringAsFixed(0)} B/s';
    } else if (speed < 1024 * 1024) {
      return '${(speed / 1024).toStringAsFixed(2)} KiB/s';
    } else {
      return '${(speed / (1024 * 1024)).toStringAsFixed(2)} MiB/s';
    }
  }

  /// Format ETA string
  static String formatEta(double? eta) {
    if (eta == null) {
      return 'Unknown';
    }
    final etaInt = eta.round();
    if (etaInt < 0) {
      return '--:--';
    }
    final hours = etaInt ~/ 3600;
    final minutes = (etaInt % 3600) ~/ 60;
    final seconds = etaInt % 60;
    if (hours > 99) {
      return '--:--:--';
    }
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Format seconds to time string
  static String formatSeconds(double? seconds) {
    if (seconds == null) {
      return 'Unknown';
    }
    final hours = (seconds ~/ 3600).toInt();
    final minutes = ((seconds % 3600) ~/ 60).toInt();
    final secs = (seconds % 60).toInt();
    if (hours > 99) {
      return '--:--:--';
    }
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  /// Slow down if rate limit exceeded
  Future<void> _slowDown(double startTime, double now, int byteCounter) async {
    final rateLimit = _options.rateLimit;
    if (rateLimit == null || byteCounter == 0) {
      return;
    }
    final elapsed = now - startTime;
    if (elapsed <= 0.0) {
      return;
    }
    final speed = byteCounter / elapsed;
    if (speed > rateLimit) {
      final sleepTime = (byteCounter / rateLimit) - elapsed;
      if (sleepTime > 0) {
        await Future.delayed(Duration(milliseconds: (sleepTime * 1000).round()));
      }
    }
  }

  /// Get temp filename
  String _tempName(String filename) {
    if (filename == '-') {
      return filename;
    }
    final file = File(filename);
    if (file.existsSync()) {
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) {
        return filename;
      }
    }
    return '$filename.part';
  }

  /// Undo temp name
  String _undoTempName(String filename) {
    if (filename.endsWith('.part')) {
      return filename.substring(0, filename.length - 5);
    }
    return filename;
  }

  /// Download file from URL to local path
  Future<void> download(
    String url,
    String outputPath, {
    ProgressCallback? onProgress,
    Map<String, String>? headers,
    bool? resume,
  }) async {
    final actualResume = resume ?? _options.continuedl;
    final file = File(outputPath);
    final tempFile = File(_tempName(outputPath));

    // Check if we can resume
    int startByte = 0;
    if (actualResume && tempFile.existsSync()) {
      startByte = await tempFile.length();
      if (startByte > 0) {
        _log('Resuming download at byte $startByte');
      }
    }

    _log('Starting download: $url');
    _logDebug('Output path: $outputPath');
    _logDebug('Resume: $actualResume, Start byte: $startByte');

    // Create request headers
    // Following yt-dlp's approach: HTTPHeaderDict({'Accept-Encoding': 'identity'}, info_dict.get('http_headers'))
    // This means: first set Accept-Encoding: identity, then merge format's http_headers
    final requestHeaders = <String, String>{
      // First, set Accept-Encoding: identity (disable compression for downloads)
      'Accept-Encoding': 'identity',
    };
    
    // Then merge provided headers (from format.httpHeaders) - these may override defaults
    // This matches Python's HTTPHeaderDict merge behavior
    if (headers != null) {
      requestHeaders.addAll(headers);
    }
    
    // Set default headers only if not already provided by format
    // This ensures format-specific headers take precedence
    requestHeaders.putIfAbsent('User-Agent', () =>
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
    requestHeaders.putIfAbsent('Accept', () => '*/*');
    requestHeaders.putIfAbsent('Accept-Language', () => 'en-US,en;q=0.9');
    requestHeaders.putIfAbsent('Connection', () => 'keep-alive');
    
    // For googlevideo.com URLs, ensure we have proper headers
    if (url.contains('googlevideo.com')) {
      requestHeaders.putIfAbsent('Referer', () => 'https://www.youtube.com/');
      requestHeaders.putIfAbsent('Origin', () => 'https://www.youtube.com');
      requestHeaders.putIfAbsent('Sec-Fetch-Mode', () => 'no-cors');
      requestHeaders.putIfAbsent('Sec-Fetch-Site', () => 'cross-site');
      requestHeaders.putIfAbsent('Sec-Fetch-Dest', () => 'empty');
    }
    
    // Ensure Accept-Encoding is always 'identity' (yt-dlp always sets this first)
    requestHeaders['Accept-Encoding'] = 'identity';

    // Retry manager
    for (final retry in RetryManager(_options.retries ?? 10)) {
      try {
        // Set Range header if resuming (matching yt-dlp's format)
        if (startByte > 0) {
          requestHeaders['Range'] = 'bytes=$startByte-';
          _logDebug('Setting Range header: bytes=$startByte-');
        } else {
          // Remove Range header if not resuming
          requestHeaders.remove('Range');
        }

        _logDebug('Sending HTTP request (attempt ${retry.attempt}/${_options.retries ?? 10})');
        _logDebug('Request URL: $url');
        _logDebug('Request headers: ${requestHeaders.keys.join(', ')}');
        if (_options.verbose) {
          requestHeaders.forEach((key, value) {
            // Truncate long values for logging
            final displayValue = value.length > 100 ? '${value.substring(0, 100)}...' : value;
            _logDebug('  $key: $displayValue');
          });
        }

        final request = http.Request('GET', Uri.parse(url));
        // Clear any existing headers first
        request.headers.clear();
        request.headers.addAll(requestHeaders);

        final requestStartTime = DateTime.now();
        final streamedResponse = await _client.send(request);
        final requestDuration = DateTime.now().difference(requestStartTime).inMilliseconds;
        final statusCode = streamedResponse.statusCode;

        _logDebug('HTTP response: $statusCode ${streamedResponse.reasonPhrase} (${requestDuration}ms)');
        _logDebug('Response headers: ${streamedResponse.headers.keys.join(', ')}');

        // Handle 416 Range Not Satisfiable (matching yt-dlp)
        if (statusCode == 416) {
          // Unable to resume (requested range not satisfiable)
          try {
            // Open the connection again without the range header
            final retryRequest = http.Request('GET', Uri.parse(url));
            retryRequest.headers.addAll(requestHeaders);
            retryRequest.headers.remove('Range');
            
            final retryResponse = await _client.send(retryRequest);
            final contentLength = retryResponse.contentLength;
            
            if (contentLength != null) {
              // Examine the reported length
              // YouTube sometimes adds or removes a few bytes from the end of the file
              // Consider the file completely downloaded if the file size differs less than 100 bytes
              if (startByte - 100 < contentLength && contentLength < startByte + 100) {
                // The file had already been fully downloaded
                _log('File already downloaded');
                if (file.existsSync()) {
                  await file.delete();
                }
                await tempFile.rename(outputPath);
                
                if (onProgress != null) {
                  onProgress(
                    downloadedBytes: startByte,
                    totalBytes: startByte,
                    progress: 100.0,
                    speed: null,
                    eta: 0,
                    elapsed: 0.0,
                    status: DownloadStatus.finished,
                    tmpfilename: tempFile.path,
                    filename: outputPath,
                  );
                }
                return;
              } else {
                // The length does not match, we start the download over
                _logWarning('Unable to resume');
                if (tempFile.existsSync()) {
                  await tempFile.delete();
                }
                startByte = 0;
                requestHeaders.remove('Range');
                continue;
              }
            }
          } catch (e) {
            if (statusCode < 500 || statusCode >= 600) {
              rethrow;
            }
            retry.error = e;
            continue;
          }
        }

        // Handle 403 Forbidden (matching yt-dlp's approach)
        if (statusCode == 403) {
          _logError('403 Forbidden - analyzing URL and headers');
          
          // Check if URL contains googlevideo.com (YouTube CDN)
          if (url.contains('googlevideo.com')) {
            final uri = Uri.tryParse(url);
            if (uri != null) {
              final queryParams = uri.queryParameters;
              final hasId = queryParams.containsKey('id');
              final hasItag = queryParams.containsKey('itag');
              final hasSig = queryParams.containsKey('sig');
              final hasSignature = queryParams.containsKey('signature');
              final hasS = queryParams.containsKey('s');
              final hasN = queryParams.containsKey('n');
              final hasSignatureParam = hasSig || hasSignature || hasS;

              _logError('URL parameter analysis:');
              _logError('  - id: $hasId ${hasId ? "(value: ${queryParams['id']?.substring(0, queryParams['id']!.length > 20 ? 20 : queryParams['id']!.length)}...)" : ""}');
              _logError('  - itag: $hasItag ${hasItag ? "(value: ${queryParams['itag']})" : ""}');
              _logError('  - sig: $hasSig ${hasSig ? "(decrypted signature present)" : ""}');
              _logError('  - signature: $hasSignature');
              _logError('  - s (encrypted): $hasS ${hasS ? "⚠️ ENCRYPTED - needs decryption" : ""}');
              _logError('  - n (challenge): $hasN ${hasN ? "⚠️ ENCRYPTED - needs decryption" : ""}');
              _logError('  - Has signature param: $hasSignatureParam');
              
              // Log first 200 chars of URL for debugging
              final urlPreview = url.length > 200 ? '${url.substring(0, 200)}...' : url;
              _logError('URL preview: $urlPreview');
              
              // Check for encrypted parameters that need decryption
              if (hasS || hasN) {
                _logError('⚠️ URL contains encrypted parameters (s or n) that require JavaScript decryption');
                _logError('This usually means the format extraction did not properly decrypt the signature.');
                _logError('The URL should have been decrypted during format extraction using JavaScript player code.');
                throw Exception(
                    'Download failed with 403 Forbidden. The URL contains encrypted parameters (${hasS ? "s" : ""}${hasS && hasN ? " and " : ""}${hasN ? "n" : ""}) '
                    'that require JavaScript decryption. This should have been handled during format extraction. '
                    'Please ensure JavaScript solver is available and format decryption completed successfully.');
              } else if (!hasSignatureParam) {
                _logError('Missing signature parameter in URL - this is likely the cause of 403');
                _logError('The URL needs a decrypted signature. This requires JavaScript player code execution.');
                throw Exception(
                    'Download failed with 403 Forbidden. The video URL is missing a signature parameter. '
                    'This usually means the URL needs to be decrypted using YouTube\'s player JavaScript code. '
                    'The signatureCipher format was detected but could not be properly decrypted.');
              } else {
                _logError('URL has signature parameter but still getting 403');
                _logError('Possible causes: 1) Signature expired, 2) Invalid signature, 3) Rate limiting, 4) Geographic restrictions');
              }
            } else {
              _logError('Failed to parse URL: $url');
            }
          } else {
            _logError('403 Forbidden on non-googlevideo.com URL: ${Uri.tryParse(url)?.host ?? "unknown"}');
          }

          // Try with additional headers (only on first retry attempt)
          // This matches yt-dlp's behavior of trying enhanced headers before giving up
          if (retry.attempt == 1) {
            _log('First attempt failed with 403, retrying with enhanced headers');
            final enhancedHeaders = Map<String, String>.from(requestHeaders);
            enhancedHeaders.addAll({
              'X-Requested-With': 'XMLHttpRequest',
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
            });

            final retryRequest = http.Request('GET', Uri.parse(url));
            retryRequest.headers.addAll(enhancedHeaders);
            if (startByte > 0) {
              retryRequest.headers['Range'] = 'bytes=$startByte-';
            }

            final retryResponse = await _client.send(retryRequest);
            _logDebug('Retry response: ${retryResponse.statusCode} ${retryResponse.reasonPhrase}');
            
            if (retryResponse.statusCode == 403) {
              _logError('403 Forbidden persists after retry with enhanced headers');
              // If it's a signature issue, don't continue retrying
              if (url.contains('googlevideo.com')) {
                final uri = Uri.tryParse(url);
                if (uri != null) {
                  final queryParams = uri.queryParameters;
                  if (queryParams.containsKey('s') || queryParams.containsKey('n')) {
                    throw Exception(
                        'Download failed with 403 Forbidden. The video URL contains encrypted parameters that require decryption. '
                        'Please ensure the format was properly decrypted during extraction using JavaScript player code.');
                  }
                }
              }
              retry.error = Exception(
                  'Download failed with 403 Forbidden after retry. YouTube may be blocking the request.');
              continue;
            } else if (retryResponse.statusCode >= 200 && retryResponse.statusCode < 300) {
              // Use retry response if successful
              _log('Retry successful with enhanced headers, proceeding with download');
              return await _processResponse(
                  retryResponse, url, outputPath, onProgress, headers, actualResume, startByte, file, tempFile);
            } else {
              // Other error status, continue with normal retry logic
              retry.error = Exception('Retry with enhanced headers returned: ${retryResponse.statusCode}');
              continue;
            }
          } else {
            _logError('403 Forbidden persists after ${retry.attempt} attempts');
            retry.error = Exception(
                'Download failed with 403 Forbidden after ${retry.attempt} attempts. '
                'Possible causes: 1) Missing/invalid signature, 2) Rate limiting, '
                '3) Geographic restrictions, or 4) YouTube detecting automated access.');
            continue;
          }
        }

        // Handle different status codes (matching yt-dlp's logic)
        if (statusCode == 206) {
          _log('206 Partial Content - server supports range requests');
          // Partial Content - server supports range requests
          // Verify Content-Range matches requested Range (matching yt-dlp's validation)
          final contentRange = streamedResponse.headers['content-range'] ??
              streamedResponse.headers['Content-Range'];
          if (contentRange != null) {
            _logDebug('Content-Range: $contentRange');
            // Parse Content-Range: bytes start-end/total
            final rangeMatch = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+)').firstMatch(contentRange);
            if (rangeMatch != null) {
              final rangeStart = int.tryParse(rangeMatch.group(1) ?? '');
              final totalSize = int.tryParse(rangeMatch.group(3) ?? '');
              
              // Verify Content-Range matches requested Range (matching yt-dlp)
              // This is important because some servers don't support resuming and serve whole file
              if (rangeStart != null && startByte > 0 && rangeStart != startByte) {
                // Content-Range doesn't match requested Range, can't resume
                _logWarning('Content-Range mismatch: requested start=$startByte, got start=$rangeStart');
                _logWarning('Server may not support resume, restarting download');
                if (tempFile.existsSync()) {
                  await tempFile.delete();
                }
                startByte = 0;
                requestHeaders.remove('Range');
                continue;
              }
              
              if (totalSize != null) {
                _logDebug('Content-Range indicates total size: ${_formatBytes(totalSize)}');
              }
            }
          } else if (startByte > 0) {
            // Content-Range header missing but we requested a range
            // Some servers don't support resuming and serve whole file with no Content-Range
            _logWarning('Content-Range header missing for range request - server may not support resume');
            if (tempFile.existsSync()) {
              await tempFile.delete();
            }
            startByte = 0;
            requestHeaders.remove('Range');
            continue;
          }
        } else if (statusCode < 200 || statusCode >= 300) {
          _logError('HTTP error: $statusCode ${streamedResponse.reasonPhrase}');
          // If we tried to resume but got non-206 response, server doesn't support it
          if (startByte > 0 && statusCode != 416) {
            _logWarning('Server doesn\'t support resume (got $statusCode instead of 206), restarting download');
            if (tempFile.existsSync()) {
              await tempFile.delete();
            }
            startByte = 0;
            requestHeaders.remove('Range');
            continue;
          }
          // For 5xx errors, retry; for other errors, retry if retries available
          if (statusCode >= 500 && statusCode < 600) {
            _logWarning('Server error ($statusCode), will retry');
            retry.error = Exception('Server error: $statusCode ${streamedResponse.reasonPhrase}');
            continue;
          } else {
            retry.error = Exception(
                'Download failed with status code: $statusCode ${streamedResponse.reasonPhrase}');
            continue;
          }
        } else if (startByte > 0 && statusCode == 200) {
          _logWarning('Server returned full file (200) instead of partial content (206)');
          // Server returned full file instead of partial content
          // This means server doesn't support Range requests properly
          if (tempFile.existsSync()) {
            await tempFile.delete();
          }
          startByte = 0;
          // Don't set Range header for next attempt
          requestHeaders.remove('Range');
        }

        // Process response
        _log('Processing response, starting download');
        return await _processResponse(
            streamedResponse, url, outputPath, onProgress, headers, actualResume, startByte, file, tempFile);
      } catch (e, stackTrace) {
        _logError('Exception during download attempt ${retry.attempt}: $e');
        _logDebug('Stack trace: $stackTrace');
        retry.error = e;
        continue;
      }
    }

    // All retries exhausted
    _logError('All retries exhausted (${_options.retries} attempts)');
    throw Exception('Download failed after ${_options.retries} retries');
  }

  /// Process HTTP response and download content
  Future<void> _processResponse(
    http.StreamedResponse streamedResponse,
    String url,
    String outputPath,
    ProgressCallback? onProgress,
    Map<String, String>? headers,
    bool resume,
    int startByte,
    File file,
    File tempFile,
  ) async {
    final statusCode = streamedResponse.statusCode;

    // Check Content-Encoding and Content-Length (matching yt-dlp's logic)
    int? totalBytes;
    final contentLength = streamedResponse.contentLength;
    final contentEncoding = streamedResponse.headers['content-encoding'] ??
        streamedResponse.headers['Content-Encoding'];
    
    _logDebug('Content-Length: $contentLength');
    _logDebug('Content-Encoding: $contentEncoding');
    
    // If Content-Encoding is present, Content-Length is not reliable anymore
    // as we are doing auto decompression (matching yt-dlp comment)
    if (contentEncoding != null && contentEncoding.isNotEmpty) {
      _logDebug('Content-Encoding present, ignoring Content-Length (auto decompression)');
      totalBytes = null;
    } else if (contentLength != null) {
      if (statusCode == 206) {
        // Partial content (206) - total size should come from Content-Range
        final contentRange = streamedResponse.headers['content-range'] ??
            streamedResponse.headers['Content-Range'];
        if (contentRange != null) {
          // Parse Content-Range: bytes start-end/total
          final rangeMatch = RegExp(r'bytes\s+\d+-\d+/(\d+)').firstMatch(contentRange);
          if (rangeMatch != null) {
            totalBytes = int.tryParse(rangeMatch.group(1) ?? '');
            _logDebug('Total size from Content-Range: ${_formatBytes(totalBytes ?? 0)}');
          }
        }
        // Fallback: if Content-Range parsing failed, use startByte + contentLength
        if (totalBytes == null) {
          totalBytes = startByte + contentLength;
          _logDebug('Total size calculated from startByte + contentLength: ${_formatBytes(totalBytes)}');
        }
      } else {
        // Full content (200) - use Content-Length directly
        totalBytes = contentLength;
        _logDebug('Total size from Content-Length: ${_formatBytes(totalBytes)}');
      }
    } else {
      _logDebug('Content-Length not available - streaming download');
    }

    // Validate file size (matching yt-dlp)
    if (totalBytes != null) {
      final dataLen = totalBytes;
      final minFilesize = _options.minFilesize;
      final maxFilesize = _options.maxFilesize;
      
      _log('File size: ${_formatBytes(dataLen)}');
      
      if (minFilesize != null && dataLen < minFilesize) {
        _logError('File is smaller than min-filesize ($dataLen bytes < $minFilesize bytes)');
        throw Exception(
            'File is smaller than min-filesize ($dataLen bytes < $minFilesize bytes). Aborting.');
      }
      if (maxFilesize != null && dataLen > maxFilesize) {
        _logError('File is larger than max-filesize ($dataLen bytes > $maxFilesize bytes)');
        throw Exception(
            'File is larger than max-filesize ($dataLen bytes > $maxFilesize bytes). Aborting.');
      }
    } else {
      _log('File size: Unknown (streaming or Content-Encoding present)');
    }

    // Open file for writing (append if resuming)
    final sink = tempFile.openWrite(mode: startByte > 0 ? FileMode.append : FileMode.write);
    _log('Destination: ${_undoTempName(tempFile.path)}');

    int downloadedBytes = startByte;
    final startTime = DateTime.now().millisecondsSinceEpoch / 1000.0;
    int lastReportedBytes = startByte;
    DateTime lastReportTime = DateTime.now();
    DateTime? throttleStart;

    // Test mode: limit download size
    final testMode = _options.test;
    final testFileSize = _options.testFileSize ?? 10240; // Default 10KB
    
    if (testMode) {
      _log('Test mode: will download only ${_formatBytes(testFileSize)}');
    }

    _log('Starting to download data...');
    int chunkCount = 0;

    try {
      await for (var chunk in streamedResponse.stream) {
        chunkCount++;
        // Test mode: limit chunk size
        if (testMode && downloadedBytes >= testFileSize) {
          break;
        }

        sink.add(chunk);
        downloadedBytes += chunk.length;

        // Apply rate limit (matching yt-dlp)
        final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
        await _slowDown(startTime, now, downloadedBytes - startByte);

        // Check throttled rate limit (matching yt-dlp)
        final speed = calcSpeed(startTime, now, downloadedBytes - startByte);
        final throttledRateLimit = _options.throttledRateLimit;
        if (speed != null && throttledRateLimit != null && speed < throttledRateLimit) {
          if (throttleStart == null) {
            throttleStart = DateTime.now();
          } else {
            final throttleDuration = DateTime.now().difference(throttleStart).inSeconds;
            if (throttleDuration > 3) {
              // The speed must stay below the limit for 3 seconds
              await sink.flush();
              await sink.close();
              throw Exception('Download speed is being throttled (${formatSpeed(speed)} < ${formatSpeed(throttledRateLimit.toDouble())})');
            }
          }
        } else if (speed != null) {
          throttleStart = null;
        }

        // Report progress (throttle updates)
        if (onProgress != null) {
          final reportNow = DateTime.now();
          final timeSinceLastReport = reportNow.difference(lastReportTime).inMilliseconds;

          // Report at most once per 200ms or every 64KB
          if (timeSinceLastReport >= 200 ||
              (downloadedBytes - lastReportedBytes) >= 65536) {
            final elapsed = now - startTime;
            final eta = calcEta(startTime, now, totalBytes, downloadedBytes - startByte);

            onProgress(
              downloadedBytes: downloadedBytes,
              totalBytes: totalBytes,
              progress: totalBytes != null
                  ? ((downloadedBytes / totalBytes) * 100).clamp(0.0, 100.0)
                  : 0.0,
              speed: speed,
              eta: eta,
              elapsed: elapsed,
              status: DownloadStatus.downloading,
              tmpfilename: tempFile.path,
              filename: outputPath,
            );

            lastReportedBytes = downloadedBytes;
            lastReportTime = reportNow;
          }
        }
      }

      await sink.flush();
      await sink.close();

      _logDebug('Downloaded $chunkCount chunks, total: ${_formatBytes(downloadedBytes)}');

      // Validate download completeness (matching yt-dlp)
      if (totalBytes != null && downloadedBytes != totalBytes) {
        _logError('Download incomplete: got ${_formatBytes(downloadedBytes)}, expected ${_formatBytes(totalBytes)}');
        throw Exception(
            'Download incomplete: got $downloadedBytes bytes, expected $totalBytes bytes');
      }

      // Final progress report
      if (onProgress != null) {
        final elapsed = (DateTime.now().millisecondsSinceEpoch / 1000.0) - startTime;
        final finalSpeed = elapsed > 0 ? downloadedBytes / elapsed : null;
        onProgress(
          downloadedBytes: downloadedBytes,
          totalBytes: totalBytes ?? downloadedBytes,
          progress: 100.0,
          speed: finalSpeed,
          eta: 0.0,
          elapsed: elapsed,
          status: DownloadStatus.finished,
          tmpfilename: tempFile.path,
          filename: outputPath,
        );
      }

      // Rename temp file to final file
      _log('Renaming temp file to final file');
      if (file.existsSync()) {
        await file.delete();
      }
      await tempFile.rename(outputPath);
      _log('Download completed: ${_formatBytes(downloadedBytes)}');

      // Update file modification time (matching yt-dlp)
      if (_options.updatetime) {
        final lastModified = streamedResponse.headers['last-modified'] ??
            streamedResponse.headers['Last-Modified'];
        if (lastModified != null) {
          try {
            // Parse RFC 2822 date
            final date = HttpDate.parse(lastModified);
            await File(outputPath).setLastModified(date);
          } catch (e) {
            // Ignore date parsing errors
          }
        }
      }
    } catch (e) {
      await sink.flush();
      await sink.close();
      // Don't delete temp file on error - allows resume on retry
      rethrow;
    }
  }

  /// Download video format
  Future<void> downloadFormat(
    VideoFormat format,
    String outputPath, {
    ProgressCallback? onProgress,
  }) async {
    if (format.url == null) {
      throw Exception('Format URL is null');
    }

    final url = format.url!;
    
    // Validate URL before downloading (check for encrypted parameters)
    // This helps catch issues early if decryption didn't work properly
    if (url.contains('googlevideo.com')) {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        final queryParams = uri.queryParameters;
        final hasS = queryParams.containsKey('s');
        final hasN = queryParams.containsKey('n');
        
        if (hasS || hasN) {
          _logWarning('⚠️  Format URL contains encrypted parameters (${hasS ? "s" : ""}${hasS && hasN ? " and " : ""}${hasN ? "n" : ""})');
          _logWarning('This format should have been decrypted during extraction.');
          _logWarning('The download may fail with 403 Forbidden.');
          _logWarning('Format ID: ${format.formatId}, Format Note: ${format.formatNote ?? "N/A"}');
          
          // Check if format note indicates it was decrypted
          if (format.formatNote?.contains('decrypted') != true) {
            _logError('Format note does not indicate decryption was successful');
            throw Exception(
                'Format URL contains encrypted parameters that require JavaScript decryption. '
                'Please ensure JavaScript solver is available and format decryption completed successfully.');
          } else {
            _logWarning('Format note indicates decryption, but URL still has encrypted parameters - this may be a bug');
          }
        } else {
          // Check if we have a proper signature
          final hasSig = queryParams.containsKey('sig') || queryParams.containsKey('signature');
          if (hasSig) {
            _logDebug('✓ Format URL has decrypted signature parameter');
          } else {
            _logWarning('Format URL does not have signature parameter - may fail with 403');
          }
        }
      }
    }

    // Convert httpHeaders from Map<String, dynamic> to Map<String, String>
    // This matches yt-dlp's approach of extracting headers from format
    Map<String, String>? headers;
    if (format.httpHeaders != null) {
      headers = <String, String>{};
      format.httpHeaders!.forEach((key, value) {
        headers![key] = value.toString();
      });
      _logDebug('Using format-specific headers: ${headers.keys.join(', ')}');
    }

    _log('Downloading format ${format.formatId} (${format.formatNote ?? "unknown"})');
    await download(
      url,
      outputPath,
      onProgress: onProgress,
      headers: headers,
      resume: _options.continuedl,
    );
  }

  void dispose() {
    _client.close();
  }
}
