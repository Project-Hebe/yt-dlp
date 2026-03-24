/// Format selection utilities
library format_selector;

import '../models/video_info.dart';

/// Format selector class
class FormatSelector {
  /// Select best format based on criteria
  static VideoFormat? selectBestFormat(
    List<VideoFormat> formats, {
    bool preferVideo = true,
    bool preferAudio = false,
    int? maxHeight,
    String? preferredExtension,
  }) {
    if (formats.isEmpty) return null;

    // Filter formats
    var filtered = formats.where((f) {
      if (preferVideo && f.hasVideo != true) return false;
      if (preferAudio && f.hasAudio != true) return false;
      if (maxHeight != null && (f.height ?? 0) > maxHeight) return false;
      if (preferredExtension != null && f.ext != preferredExtension) {
        return false;
      }
      return f.url != null;
    }).toList();

    if (filtered.isEmpty) {
      // Fallback to any format with URL
      filtered = formats.where((f) => f.url != null).toList();
    }

    if (filtered.isEmpty) return null;

    // Sort formats by quality
    filtered.sort((a, b) {
      // First priority: Prefer formats without encryption markers
      // (formats that don't mention "encrypted" or "decryption" in formatNote)
      final aNeedsDecryption = a.formatNote?.contains('encrypted') == true ||
          a.formatNote?.contains('decryption') == true ||
          a.formatNote?.contains('n challenge') == true;
      final bNeedsDecryption = b.formatNote?.contains('encrypted') == true ||
          b.formatNote?.contains('decryption') == true ||
          b.formatNote?.contains('n challenge') == true;
      
      if (aNeedsDecryption && !bNeedsDecryption) {
        return 1; // b is better (no decryption needed)
      }
      if (!aNeedsDecryption && bNeedsDecryption) {
        return -1; // a is better (no decryption needed)
      }
      
      // Prefer formats with both video and audio
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

      return 0;
    });

    return filtered.first;
  }

  /// Select format by format ID
  static VideoFormat? selectByFormatId(
    List<VideoFormat> formats,
    int formatId,
  ) {
    return formats.firstWhere(
      (f) => f.formatId == formatId,
      orElse: () => throw Exception('Format ID $formatId not found'),
    );
  }

  /// Get all available formats
  static List<VideoFormat> listFormats(List<VideoFormat> formats) {
    // Expose every parsed format, even those lacking direct URLs,
    // so the caller can decide how to handle/decrypt them.
    return List<VideoFormat>.from(formats);
  }
}

