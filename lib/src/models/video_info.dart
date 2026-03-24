/// Video information model
library video_info;

/// Represents video format information
class VideoFormat {
  final int? formatId;
  final String? url;
  final String? manifestUrl;
  final String? ext;
  final int? width;
  final int? height;
  final int? fps;
  final String? vcodec;
  final String? acodec;
  final int? filesize;
  final int? tbr; // Total bitrate
  final String? protocol;
  final Map<String, dynamic>? httpHeaders;
  final String? formatNote;
  final int? quality;
  final bool? hasVideo;
  final bool? hasAudio;
  final String? language;
  final String? languagePreference;
  final int? audioSampleRate;
  final int? audioChannels;
  final bool? hasDrm;
  final String? qualityLabel;
  final int? sourcePreference;
  final int? preference;
  final bool? isDamaged;

  VideoFormat({
    this.formatId,
    this.url,
    this.manifestUrl,
    this.ext,
    this.width,
    this.height,
    this.fps,
    this.vcodec,
    this.acodec,
    this.filesize,
    this.tbr,
    this.protocol,
    this.httpHeaders,
    this.formatNote,
    this.quality,
    this.hasVideo,
    this.hasAudio,
    this.language,
    this.languagePreference,
    this.audioSampleRate,
    this.audioChannels,
    this.hasDrm,
    this.qualityLabel,
    this.sourcePreference,
    this.preference,
    this.isDamaged,
  });

  factory VideoFormat.fromJson(Map<String, dynamic> json) {
    return VideoFormat(
      formatId: json['format_id'] as int?,
      url: json['url'] as String?,
      manifestUrl: (json['manifest_url'] ?? json['manifestUrl']) as String?,
      ext: json['ext'] as String?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      fps: json['fps'] as int?,
      vcodec: json['vcodec'] as String?,
      acodec: json['acodec'] as String?,
      filesize: json['filesize'] as int?,
      tbr: json['tbr'] as int?,
      protocol: json['protocol'] as String?,
      httpHeaders: json['http_headers'] as Map<String, dynamic>?,
      formatNote: json['format_note'] as String?,
      quality: json['quality'] as int?,
      hasVideo: json['has_video'] as bool?,
      hasAudio: json['has_audio'] as bool?,
      language: json['language'] as String?,
      languagePreference: json['language_preference'] as String?,
      audioSampleRate: json['audio_sample_rate'] as int?,
      audioChannels: json['audio_channels'] as int?,
      hasDrm: json['has_drm'] as bool?,
      qualityLabel: json['quality_label'] as String?,
      sourcePreference: json['source_preference'] as int?,
      preference: json['preference'] as int?,
      isDamaged: json['is_damaged'] as bool?,
    );
  }
  VideoFormat copyWith({
    int? formatId,
    String? url,
    String? manifestUrl,
    String? ext,
    int? width,
    int? height,
    int? fps,
    String? vcodec,
    String? acodec,
    int? filesize,
    int? tbr,
    String? protocol,
    Map<String, dynamic>? httpHeaders,
    String? formatNote,
    int? quality,
    bool? hasVideo,
    bool? hasAudio,
    String? language,
    String? languagePreference,
    int? audioSampleRate,
    int? audioChannels,
    bool? hasDrm,
    String? qualityLabel,
    int? sourcePreference,
    int? preference,
    bool? isDamaged,
  }) {
    return VideoFormat(
      formatId: formatId ?? this.formatId,
      url: url ?? this.url,
      manifestUrl: manifestUrl ?? this.manifestUrl,
      ext: ext ?? this.ext,
      width: width ?? this.width,
      height: height ?? this.height,
      fps: fps ?? this.fps,
      vcodec: vcodec ?? this.vcodec,
      acodec: acodec ?? this.acodec,
      filesize: filesize ?? this.filesize,
      tbr: tbr ?? this.tbr,
      protocol: protocol ?? this.protocol,
      httpHeaders: httpHeaders ?? this.httpHeaders,
      formatNote: formatNote ?? this.formatNote,
      quality: quality ?? this.quality,
      hasVideo: hasVideo ?? this.hasVideo,
      hasAudio: hasAudio ?? this.hasAudio,
      language: language ?? this.language,
      languagePreference: languagePreference ?? this.languagePreference,
      audioSampleRate: audioSampleRate ?? this.audioSampleRate,
      audioChannels: audioChannels ?? this.audioChannels,
      hasDrm: hasDrm ?? this.hasDrm,
      qualityLabel: qualityLabel ?? this.qualityLabel,
      sourcePreference: sourcePreference ?? this.sourcePreference,
      preference: preference ?? this.preference,
      isDamaged: isDamaged ?? this.isDamaged,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'format_id': formatId,
      'url': url,
      'manifest_url': manifestUrl,
      'manifestUrl': manifestUrl,
      'ext': ext,
      'width': width,
      'height': height,
      'fps': fps,
      'vcodec': vcodec,
      'acodec': acodec,
      'filesize': filesize,
      'tbr': tbr,
      'protocol': protocol,
      'http_headers': httpHeaders,
      'format_note': formatNote,
      'quality': quality,
      'has_video': hasVideo,
      'has_audio': hasAudio,
      'language': language,
      'language_preference': languagePreference,
      'audio_sample_rate': audioSampleRate,
      'audio_channels': audioChannels,
      'has_drm': hasDrm,
      'quality_label': qualityLabel,
      'source_preference': sourcePreference,
      'preference': preference,
      'is_damaged': isDamaged,
    };
  }
}

class VideoInfo {
  final String id;
  final String? title;
  final String? description;
  final String? thumbnail;
  final List<String>? thumbnails;
  final int? duration;
  final String? uploader;
  final String? uploaderId;
  final String? uploaderUrl;
  final DateTime? uploadDate;
  final int? viewCount;
  final int? likeCount;
  final int? commentCount;
  final List<String>? tags;
  final List<String>? categories;
  final String? webpageUrl;
  final List<VideoFormat> formats;
  final List<VideoFormat> videoFormats; // Video-only formats
  final List<VideoFormat> audioFormats; // Audio-only formats
  final List<VideoFormat> combinedFormats; // Video + Audio formats
  final Map<String, dynamic>? subtitles;
  final List<SubtitleInfo>? subtitleList; // Structured subtitle info
  final String? ageLimit;
  final String? availability;
  final String? liveStatus;
  final bool? isLive;
  final String? channel;
  final String? channelId;
  final String? channelUrl;
  final int? channelFollowerCount;
  final bool? channelIsVerified;
  final String? mediaType;
  final String? playlistId;
  final int? playlistIndex;

  VideoInfo({
    required this.id,
    this.title,
    this.description,
    this.thumbnail,
    this.thumbnails,
    this.duration,
    this.uploader,
    this.uploaderId,
    this.uploaderUrl,
    this.uploadDate,
    this.viewCount,
    this.likeCount,
    this.commentCount,
    this.tags,
    this.categories,
    this.webpageUrl,
    this.formats = const [],
    this.videoFormats = const [],
    this.audioFormats = const [],
    this.combinedFormats = const [],
    this.subtitles,
    this.subtitleList,
    this.ageLimit,
    this.availability,
    this.liveStatus,
    this.isLive,
    this.channel,
    this.channelId,
    this.channelUrl,
    this.channelFollowerCount,
    this.channelIsVerified,
    this.mediaType,
    this.playlistId,
    this.playlistIndex,
  });

  factory VideoInfo.fromJson(Map<String, dynamic> json) {
    return VideoInfo(
      id: json['id'] as String,
      title: json['title'] as String?,
      description: json['description'] as String?,
      thumbnail: json['thumbnail'] as String?,
      duration: json['duration'] as int?,
      uploader: json['uploader'] as String?,
      uploaderId: json['uploader_id'] as String?,
      uploaderUrl: json['uploader_url'] as String?,
      uploadDate: json['upload_date'] != null ? DateTime.tryParse(json['upload_date'] as String) : null,
      viewCount: json['view_count'] as int?,
      likeCount: json['like_count'] as int?,
      tags: json['tags'] != null ? List<String>.from(json['tags'] as List) : null,
      categories: json['categories'] != null ? List<String>.from(json['categories'] as List) : null,
      webpageUrl: json['webpage_url'] as String?,
      formats: json['formats'] != null ? (json['formats'] as List).map((f) => VideoFormat.fromJson(f as Map<String, dynamic>)).toList() : [],
      videoFormats: json['video_formats'] != null ? (json['video_formats'] as List).map((f) => VideoFormat.fromJson(f as Map<String, dynamic>)).toList() : [],
      audioFormats: json['audio_formats'] != null ? (json['audio_formats'] as List).map((f) => VideoFormat.fromJson(f as Map<String, dynamic>)).toList() : [],
      combinedFormats: json['combined_formats'] != null ? (json['combined_formats'] as List).map((f) => VideoFormat.fromJson(f as Map<String, dynamic>)).toList() : [],
      subtitles: json['subtitles'] as Map<String, dynamic>?,
      subtitleList: json['subtitle_list'] != null ? (json['subtitle_list'] as List).map((s) => SubtitleInfo.fromJson(s as Map<String, dynamic>)).toList() : null,
      ageLimit: json['age_limit']?.toString(),
      availability: json['availability'] as String?,
      liveStatus: json['live_status'] as String?,
      isLive: json['is_live'] as bool?,
      channel: json['channel'] as String?,
      channelId: json['channel_id'] as String?,
      channelUrl: json['channel_url'] as String?,
      channelFollowerCount: json['channel_follower_count'] as int?,
      channelIsVerified: json['channel_is_verified'] as bool?,
      mediaType: json['media_type'] as String?,
      playlistId: json['playlist_id'] as String?,
      playlistIndex: json['playlist_index'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'thumbnail': thumbnail,
      'duration': duration,
      'uploader': uploader,
      'uploader_id': uploaderId,
      'uploader_url': uploaderUrl,
      'upload_date': uploadDate?.toIso8601String(),
      'view_count': viewCount,
      'like_count': likeCount,
      'tags': tags,
      'categories': categories,
      'webpage_url': webpageUrl,
      'formats': formats.map((f) => f.toJson()).toList(),
      'video_formats': videoFormats.map((f) => f.toJson()).toList(),
      'audio_formats': audioFormats.map((f) => f.toJson()).toList(),
      'combined_formats': combinedFormats.map((f) => f.toJson()).toList(),
      'subtitles': subtitles,
      'subtitle_list': subtitleList?.map((s) => s.toJson()).toList(),
      'age_limit': ageLimit,
      'availability': availability,
      'live_status': liveStatus,
      'is_live': isLive,
      'channel': channel,
      'channel_id': channelId,
      'channel_url': channelUrl,
      'channel_follower_count': channelFollowerCount,
      'channel_is_verified': channelIsVerified,
      'media_type': mediaType,
      'playlist_id': playlistId,
      'playlist_index': playlistIndex,
    };
  }
}

/// Subtitle information
class SubtitleInfo {
  final String languageCode;
  final String? languageName;
  final String? url;
  final bool isAutoGenerated;
  final String? format;

  SubtitleInfo({
    required this.languageCode,
    this.languageName,
    this.url,
    this.isAutoGenerated = false,
    this.format,
  });

  factory SubtitleInfo.fromJson(Map<String, dynamic> json) {
    return SubtitleInfo(
      languageCode: json['language_code'] as String,
      languageName: json['language_name'] as String?,
      url: json['url'] as String?,
      isAutoGenerated: json['is_auto_generated'] as bool? ?? false,
      format: json['format'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'language_code': languageCode,
      'language_name': languageName,
      'url': url,
      'is_auto_generated': isAutoGenerated,
      'format': format,
    };
  }
}
