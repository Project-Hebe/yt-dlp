// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'single_track_entity.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SingleTrack _$SingleTrackFromJson(Map<String, dynamic> json) => SingleTrack(
      (json['id'] as num).toInt(),
      json['icon'] as String,
      json['path'] as String,
      json['title'] as String,
      json['size'] as String,
      (json['totalSize'] as num).toInt(),
      $enumDecodeNullable(_$StreamTypeEnumMap, json['streamType']) ??
          StreamType.video,
      videoId: json['videoId'] as String,
      language: json['language'] as String? ?? '',
      des: json['des'] as String?,
    )
      ..exportedAudioPath = json['exportedAudioPath'] as String?
      ..exportedAudioSize = (json['exportedAudioSize'] as num?)?.toInt()
      ..exportedAudioFormat = json['exportedAudioFormat'] as String?
      ..exportedAudioSegments =
          (json['exportedAudioSegments'] as List<dynamic>?)
              ?.map((e) => AudioSegment.fromJson(e as Map<String, dynamic>))
              .toList()
      ..exportedAudioDuration =
          (json['exportedAudioDuration'] as num?)?.toDouble()
      ..downloadPerc = (json['downloadPerc'] as num).toInt()
      ..downloadStatus =
          $enumDecode(_$DownloadStatusEnumMap, json['downloadStatus'])
      ..downloadedBytes = (json['downloadedBytes'] as num).toInt()
      ..error = json['error'] as String;

Map<String, dynamic> _$SingleTrackToJson(SingleTrack instance) =>
    <String, dynamic>{
      'id': instance.id,
      'videoId': instance.videoId,
      'title': instance.title,
      'icon': instance.icon,
      'size': instance.size,
      'totalSize': instance.totalSize,
      'streamType': _$StreamTypeEnumMap[instance.streamType]!,
      'language': instance.language,
      'des': instance.des,
      'exportedAudioPath': instance.exportedAudioPath,
      'exportedAudioSize': instance.exportedAudioSize,
      'exportedAudioFormat': instance.exportedAudioFormat,
      'exportedAudioSegments': instance.exportedAudioSegments,
      'exportedAudioDuration': instance.exportedAudioDuration,
      'path': instance.path,
      'downloadPerc': instance.downloadPerc,
      'downloadStatus': _$DownloadStatusEnumMap[instance.downloadStatus]!,
      'downloadedBytes': instance.downloadedBytes,
      'error': instance.error,
    };

const _$StreamTypeEnumMap = {
  StreamType.audio: 'audio',
  StreamType.video: 'video',
};

const _$DownloadStatusEnumMap = {
  DownloadStatus.querying: 'querying',
  DownloadStatus.downloading: 'downloading',
  DownloadStatus.success: 'success',
  DownloadStatus.failed: 'failed',
  DownloadStatus.muxing: 'muxing',
  DownloadStatus.canceled: 'canceled',
  DownloadStatus.paused: 'paused',
  DownloadStatus.waiting: 'waiting',
  DownloadStatus.exporting: 'exporting',
  DownloadStatus.retrying: 'retrying',
  DownloadStatus.uploading: 'uploading',
  DownloadStatus.uploaded: 'uploaded',
};

MuxedTrack _$MuxedTrackFromJson(Map<String, dynamic> json) => MuxedTrack(
      (json['id'] as num).toInt(),
      json['icon'] as String,
      json['path'] as String,
      json['title'] as String,
      json['size'] as String,
      (json['totalSize'] as num).toInt(),
      SingleTrack.fromJson(json['audio'] as Map<String, dynamic>),
      SingleTrack.fromJson(json['video'] as Map<String, dynamic>),
      streamType:
          $enumDecodeNullable(_$StreamTypeEnumMap, json['streamType']) ??
              StreamType.video,
      language: json['language'] as String? ?? '',
      des: json['des'] as String?,
    )
      ..exportedAudioPath = json['exportedAudioPath'] as String?
      ..exportedAudioSize = (json['exportedAudioSize'] as num?)?.toInt()
      ..exportedAudioFormat = json['exportedAudioFormat'] as String?
      ..exportedAudioSegments =
          (json['exportedAudioSegments'] as List<dynamic>?)
              ?.map((e) => AudioSegment.fromJson(e as Map<String, dynamic>))
              .toList()
      ..exportedAudioDuration =
          (json['exportedAudioDuration'] as num?)?.toDouble()
      ..downloadPerc = (json['downloadPerc'] as num).toInt()
      ..downloadStatus =
          $enumDecode(_$DownloadStatusEnumMap, json['downloadStatus'])
      ..downloadedBytes = (json['downloadedBytes'] as num).toInt()
      ..error = json['error'] as String;

Map<String, dynamic> _$MuxedTrackToJson(MuxedTrack instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'icon': instance.icon,
      'size': instance.size,
      'totalSize': instance.totalSize,
      'language': instance.language,
      'des': instance.des,
      'exportedAudioPath': instance.exportedAudioPath,
      'exportedAudioSize': instance.exportedAudioSize,
      'exportedAudioFormat': instance.exportedAudioFormat,
      'exportedAudioSegments': instance.exportedAudioSegments,
      'exportedAudioDuration': instance.exportedAudioDuration,
      'path': instance.path,
      'downloadPerc': instance.downloadPerc,
      'downloadStatus': _$DownloadStatusEnumMap[instance.downloadStatus]!,
      'downloadedBytes': instance.downloadedBytes,
      'error': instance.error,
      'audio': instance.audio,
      'video': instance.video,
      'streamType': _$StreamTypeEnumMap[instance.streamType]!,
    };
