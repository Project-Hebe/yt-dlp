/// Enhanced format utilities for better format display and filtering
library format_utils_enhanced;

import '../models/video_info.dart';

class FormatUtilsEnhanced {
  /// Get all video formats (video-only and combined)
  static List<VideoFormat> getVideoFormats(List<VideoFormat> formats) {
    return formats.where((f) => f.hasVideo == true).toList();
  }

  /// Get all audio formats (audio-only and combined)
  static List<VideoFormat> getAudioFormats(List<VideoFormat> formats) {
    return formats.where((f) => f.hasAudio == true).toList();
  }

  /// Get video-only formats
  static List<VideoFormat> getVideoOnlyFormats(List<VideoFormat> formats) {
    return formats.where((f) => f.hasVideo == true && f.hasAudio != true).toList();
  }

  /// Get audio-only formats
  static List<VideoFormat> getAudioOnlyFormats(List<VideoFormat> formats) {
    return formats.where((f) => f.hasAudio == true && f.hasVideo != true).toList();
  }

  /// Get combined formats (video + audio)
  static List<VideoFormat> getCombinedFormats(List<VideoFormat> formats) {
    return formats.where((f) => f.hasVideo == true && f.hasAudio == true).toList();
  }

  /// Sort formats by quality (best first)
  static List<VideoFormat> sortByQuality(List<VideoFormat> formats) {
    final sorted = List<VideoFormat>.from(formats);
    sorted.sort((a, b) {
      // Prefer combined formats
      if (a.hasVideo == true && a.hasAudio == true &&
          !(b.hasVideo == true && b.hasAudio == true)) {
        return -1;
      }
      if (b.hasVideo == true && b.hasAudio == true &&
          !(a.hasVideo == true && a.hasAudio == true)) {
        return 1;
      }

      // Sort by height (resolution)
      final heightA = a.height ?? 0;
      final heightB = b.height ?? 0;
      if (heightA != heightB) {
        return heightB.compareTo(heightA);
      }

      // Sort by bitrate
      final tbrA = a.tbr ?? 0;
      final tbrB = b.tbr ?? 0;
      if (tbrA != tbrB) {
        return tbrB.compareTo(tbrA);
      }

      // Sort by FPS
      final fpsA = a.fps ?? 0;
      final fpsB = b.fps ?? 0;
      if (fpsA != fpsB) {
        return fpsB.compareTo(fpsA);
      }

      return 0;
    });
    return sorted;
  }

  /// Filter formats by resolution
  static List<VideoFormat> filterByResolution(
    List<VideoFormat> formats,
    int? maxHeight,
    int? minHeight,
  ) {
    return formats.where((f) {
      if (f.height == null) return false;
      if (maxHeight != null && f.height! > maxHeight) return false;
      if (minHeight != null && f.height! < minHeight) return false;
      return true;
    }).toList();
  }

  /// Filter formats by extension
  static List<VideoFormat> filterByExtension(
    List<VideoFormat> formats,
    String extension,
  ) {
    return formats.where((f) => f.ext?.toLowerCase() == extension.toLowerCase()).toList();
  }

  /// Get best format for video
  static VideoFormat? getBestVideoFormat(List<VideoFormat> formats) {
    final videoFormats = getVideoFormats(formats);
    if (videoFormats.isEmpty) return null;
    final sorted = sortByQuality(videoFormats);
    return sorted.first;
  }

  /// Get best format for audio
  static VideoFormat? getBestAudioFormat(List<VideoFormat> formats) {
    final audioFormats = getAudioFormats(formats);
    if (audioFormats.isEmpty) return null;
    
    // Sort by bitrate (higher is better)
    final sorted = List<VideoFormat>.from(audioFormats);
    sorted.sort((a, b) {
      final tbrA = a.tbr ?? 0;
      final tbrB = b.tbr ?? 0;
      return tbrB.compareTo(tbrA);
    });
    return sorted.first;
  }

  /// Get format summary statistics
  static Map<String, dynamic> getFormatSummary(List<VideoFormat> formats) {
    final videoFormats = getVideoFormats(formats);
    final audioFormats = getAudioFormats(formats);
    final videoOnly = getVideoOnlyFormats(formats);
    final audioOnly = getAudioOnlyFormats(formats);
    final combined = getCombinedFormats(formats);

    final resolutions = videoFormats
        .where((f) => f.height != null)
        .map((f) => f.height!)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));

    final extensions = formats
        .where((f) => f.ext != null)
        .map((f) => f.ext!)
        .toSet()
        .toList();

    return {
      'total': formats.length,
      'video_formats': videoFormats.length,
      'audio_formats': audioFormats.length,
      'video_only': videoOnly.length,
      'audio_only': audioOnly.length,
      'combined': combined.length,
      'resolutions': resolutions,
      'extensions': extensions,
    };
  }

  /// Format format details for display
  static String formatFormatDetails(VideoFormat format) {
    final parts = <String>[];

    if (format.qualityLabel != null) {
      parts.add(format.qualityLabel!);
    } else if (format.width != null && format.height != null) {
      parts.add('${format.width}x${format.height}');
    }

    if (format.fps != null && format.fps! > 1) {
      parts.add('${format.fps}fps');
    }

    if (format.vcodec != null) {
      parts.add('Video: ${format.vcodec}');
    }

    if (format.acodec != null) {
      parts.add('Audio: ${format.acodec}');
    }

    if (format.tbr != null) {
      parts.add('${format.tbr} kbps');
    }

    if (format.audioSampleRate != null) {
      parts.add('${(format.audioSampleRate! / 1000).toStringAsFixed(1)} kHz');
    }

    if (format.hasDrm == true) {
      parts.add('DRM');
    }

    if (format.language != null) {
      parts.add('Lang: ${format.language}');
    }

    return parts.isEmpty ? 'No details' : parts.join(' • ');
  }
}

