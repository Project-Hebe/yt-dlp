/// Main YouTube downloader class
library yt_dlp;

import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'extractor/youtube_extractor.dart';
import 'downloader/http_downloader.dart';
import 'models/video_info.dart';
import 'utils/format_selector.dart';
import 'utils/logger.dart';

/// Simplified progress callback for backward compatibility
typedef SimpleProgressCallback = void Function({
  required int downloadedBytes,
  int? totalBytes,
  required double progress,
  double? speed,
});

/// Main YouTube downloader class
class YtDlp {
  final YouTubeExtractor _extractor;
  final HttpDownloader _downloader;
  final Map<String, String> _options;

  YtDlp({
    Map<String, String>? options,
    http.Client? httpClient,
    bool verbose = false,
    LogLevel? logLevel,
    LogHandler? logHandler,
  })  : _options = options ?? {},
        _extractor = YouTubeExtractor(client: httpClient),
        _downloader = HttpDownloader(
          client: httpClient,
          options: DownloadOptions(verbose: verbose),
        ) {
    // Configure logger
    if (logLevel != null) {
      logger.setLevel(logLevel);
    } else if (verbose) {
      logger.setLevel(LogLevel.debug);
    }
    
    if (logHandler != null) {
      logger.setHandler(logHandler);
    }
  }

  /// Extract video information without downloading
  Future<VideoInfo> extractInfo(String url) async {
    return await _extractor.extractInfo(url);
  }

  /// Download a specific VideoFormat directly without extracting video info again
  /// This is useful when you already have a VideoFormat object from a previous extractInfo call
  /// 
  /// Example:
  /// ```dart
  /// final videoInfo = await ytDlp.extractInfo(url);
  /// final format = videoInfo.formats.first;
  /// await ytDlp.downloadFormat(format, outputPath: 'output.mp4');
  /// // Or with title for auto-generated filename
  /// await ytDlp.downloadFormat(format, title: videoInfo.title);
  /// ```
  Future<void> downloadFormat(
    VideoFormat format, {
    String? outputPath,
    String? title,
    SimpleProgressCallback? onProgress,
  }) async {
    // Validate format
    if (format.url == null || format.url!.isEmpty) {
      throw Exception('Format URL is null or empty. Cannot download this format.');
    }

    // Determine output path
    String finalOutputPath;
    if (outputPath != null) {
      finalOutputPath = outputPath;
    } else {
      // Generate default output path using format extension and optional title
      final ext = format.ext ?? 'mp4';
      final dir = _options['output'] ?? Directory.current.path;
      
      if (title != null && title.isNotEmpty) {
        final sanitizedTitle = _sanitizeFilename(title);
        finalOutputPath = path.join(dir, '$sanitizedTitle.$ext');
      } else {
        // Fallback to timestamp-based filename
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        finalOutputPath = path.join(dir, 'video_$timestamp.$ext');
      }
    }

    // Ensure directory exists
    final dir = path.dirname(finalOutputPath);
    if (dir.isNotEmpty) {
      await Directory(dir).create(recursive: true);
    }

    // Convert simple progress callback to full progress callback
    ProgressCallback? fullProgressCallback;
    if (onProgress != null) {
      fullProgressCallback = ({
        required int downloadedBytes,
        int? totalBytes,
        required double progress,
        double? speed,
        double? eta,
        double? elapsed,
        required DownloadStatus status,
        String? tmpfilename,
        String? filename,
      }) {
        // Call the simple callback with only the basic parameters
        onProgress(
          downloadedBytes: downloadedBytes,
          totalBytes: totalBytes,
          progress: progress,
          speed: speed,
        );
      };
    }

    // Download directly using the format
    await _downloader.downloadFormat(
      format,
      finalOutputPath,
      onProgress: fullProgressCallback,
    );
  }

  /// Download video from URL
  Future<void> download(
    String url, {
    String? outputPath,
    VideoFormat? format,
    int? formatId,
    int? maxHeight,
    String? preferredExtension,
    SimpleProgressCallback? onProgress,
  }) async {
    // Extract video information
    final videoInfo = await extractInfo(url);

    if (videoInfo.formats.isEmpty) {
      throw Exception('No formats available for this video');
    }

    // Select format
    VideoFormat? selectedFormat = format;
    if (selectedFormat == null) {
      if (formatId != null) {
        try {
          selectedFormat = FormatSelector.selectByFormatId(
              videoInfo.formats, formatId);
        } catch (e) {
          throw Exception('Format ID $formatId not found: $e');
        }
      } else {
        selectedFormat = FormatSelector.selectBestFormat(
          videoInfo.formats,
          maxHeight: maxHeight,
          preferredExtension: preferredExtension,
        );
      }
    }

    if (selectedFormat == null || selectedFormat.url == null) {
      throw Exception('No suitable format found');
    }

    // Determine output path
    String finalOutputPath;
    if (outputPath != null) {
      finalOutputPath = outputPath;
    } else {
      final sanitizedTitle = _sanitizeFilename(videoInfo.title ?? 'video');
      final ext = selectedFormat.ext ?? 'mp4';
      final dir = _options['output'] ?? Directory.current.path;
      finalOutputPath = path.join(dir, '$sanitizedTitle.$ext');
    }

    // Ensure directory exists
    final dir = path.dirname(finalOutputPath);
    if (dir.isNotEmpty) {
      await Directory(dir).create(recursive: true);
    }

    // Download
    // Convert simple progress callback to full progress callback
    ProgressCallback? fullProgressCallback;
    if (onProgress != null) {
      fullProgressCallback = ({
        required int downloadedBytes,
        int? totalBytes,
        required double progress,
        double? speed,
        double? eta,
        double? elapsed,
        required DownloadStatus status,
        String? tmpfilename,
        String? filename,
      }) {
        // Call the simple callback with only the basic parameters
        onProgress(
          downloadedBytes: downloadedBytes,
          totalBytes: totalBytes,
          progress: progress,
          speed: speed,
        );
      };
    }

    await _downloader.downloadFormat(
      selectedFormat,
      finalOutputPath,
      onProgress: fullProgressCallback,
    );
  }

  /// List available formats for a video
  Future<List<VideoFormat>> listFormats(String url) async {
    final videoInfo = await extractInfo(url);
    return FormatSelector.listFormats(videoInfo.formats);
  }

  /// List video-only formats
  Future<List<VideoFormat>> listVideoFormats(String url) async {
    final videoInfo = await extractInfo(url);
    return videoInfo.videoFormats;
  }

  /// List audio-only formats
  Future<List<VideoFormat>> listAudioFormats(String url) async {
    final videoInfo = await extractInfo(url);
    return videoInfo.audioFormats;
  }

  /// List combined formats (video + audio)
  Future<List<VideoFormat>> listCombinedFormats(String url) async {
    final videoInfo = await extractInfo(url);
    return videoInfo.combinedFormats;
  }

  /// Get detailed video information with all metadata
  Future<VideoInfo> getDetailedInfo(String url) async {
    return await extractInfo(url);
  }

  /// Get video information as JSON
  Future<Map<String, dynamic>> extractInfoJson(String url) async {
    final videoInfo = await extractInfo(url);
    return videoInfo.toJson();
  }

  /// Sanitize filename
  String _sanitizeFilename(String filename) {
    // Remove invalid characters
    return filename
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Dispose resources
  void dispose() {
    _extractor.dispose();
    _downloader.dispose();
  }
}

