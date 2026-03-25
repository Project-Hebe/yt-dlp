import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:json_annotation/json_annotation.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../utils/json_processor.dart';
import '../audio_export_manager.dart';
part 'single_track_entity.g.dart';

enum DownloadStatus { querying, downloading, success, failed, muxing, canceled, paused, waiting, exporting, retrying, uploading, uploaded }

enum StreamType { audio, video }

@JsonSerializable()
class SingleTrack extends ChangeNotifier {
  final int id;
  final String videoId; // YouTube video ID
  final String title;
  final String icon;
  final String size;
  final int totalSize;
  @JsonKey(required: false, defaultValue: StreamType.video)
  final StreamType streamType;

  @JsonKey(required: false, defaultValue: '')
  String language; // 下载的语言代码

  @JsonKey(required: false)
  String? des; // 视频描述信息

  String _path; // 保存相对路径（相对于 Documents 目录）

  int _downloadPerc = 0;
  DownloadStatus _downloadStatus = DownloadStatus.downloading;
  int _downloadedBytes = 0;
  String _error = '';

  // 导出音频信息（使用公共字段，json_serializable 需要访问字段）
  @JsonKey(required: false)
  String? exportedAudioPath; // 导出的音频文件路径（相对路径）

  @JsonKey(required: false)
  int? exportedAudioSize; // 导出的音频文件大小（字节）

  @JsonKey(required: false)
  String? exportedAudioFormat; // 导出的音频格式（mp3, m4a, opus 等）

  @JsonKey(required: false)
  List<AudioSegment>? exportedAudioSegments; // 导出的音频分段信息（如果分段了）

  @JsonKey(required: false)
  double? exportedAudioDuration; // 导出的音频总时长（秒）

  /// 获取实际的文件路径（绝对路径）
  /// 将保存的相对路径与当前 Documents 目录拼接
  Future<String> getAbsolutePath() async {
    if (_path.isEmpty) return '';
    if (p.isAbsolute(_path)) {
      // 如果已经是绝对路径（旧数据兼容），直接返回
      return _path;
    }
    // 相对路径，拼接当前 Documents 目录
    final documentsDir = await getApplicationDocumentsDirectory();
    return p.join(documentsDir.path, _path);
  }

  /// 获取路径（返回保存的相对路径，用于显示）
  String get path => _path;

  int get downloadPerc => _downloadPerc;

  DownloadStatus get downloadStatus => _downloadStatus;

  int get downloadedBytes => _downloadedBytes;

  String get error => _error;

  set path(String path) {
    _path = path;
    _scheduleSave();
    _scheduleNotify();
  }

  set downloadPerc(int value) {
    _downloadPerc = value;
    _scheduleSave();
    _scheduleNotify();
  }

  set downloadStatus(DownloadStatus value) {
    _downloadStatus = value;
    _scheduleSave();
    _scheduleNotify();
  }

  set downloadedBytes(int value) {
    _downloadedBytes = value;
    _scheduleSave();
    _scheduleNotify();
  }

  set error(String value) {
    _error = value;
    _scheduleSave();
    _scheduleNotify();
  }

  /// 更新导出音频信息（批量更新，只保存一次）
  void updateExportedAudioInfo({
    String? path,
    int? size,
    String? format,
    List<AudioSegment>? segments,
    double? duration,
  }) {
    bool changed = false;
    if (path != null && exportedAudioPath != path) {
      exportedAudioPath = path;
      _scheduleSave();
      _scheduleNotify();
      changed = true;
    }
    if (size != null && exportedAudioSize != size) {
      exportedAudioSize = size;
      if (!changed) {
        _scheduleSave();
        _scheduleNotify();
      }
      changed = true;
    }
    if (format != null && exportedAudioFormat != format) {
      exportedAudioFormat = format;
      if (!changed) {
        _scheduleSave();
        _scheduleNotify();
      }
      changed = true;
    }
    if (segments != null && exportedAudioSegments != segments) {
      exportedAudioSegments = segments;
      if (!changed) {
        _scheduleSave();
        _scheduleNotify();
      }
      changed = true;
    }
    if (duration != null && exportedAudioDuration != duration) {
      exportedAudioDuration = duration;
      if (!changed) {
        _scheduleSave();
        _scheduleNotify();
      }
      changed = true;
    }
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  VoidCallback? cancelCallback;

  @JsonKey(includeFromJson: false, includeToJson: false)
  final SharedPreferences? _prefs;

  // 性能优化：批量更新和异步保存
  Timer? _saveTimer;
  bool _hasPendingSave = false;
  bool _hasPendingNotify = false;
  static final JsonProcessor _jsonProcessor = JsonProcessor();

  SingleTrack(this.id, this.icon, String path, this.title, this.size, this.totalSize, this.streamType, {SharedPreferences? prefs, required this.videoId, required this.language, this.des})
      : _path = path,
        _prefs = prefs;

  factory SingleTrack.fromJson(Map<String, dynamic> json) => _$SingleTrackFromJson(json);

  Map<String, dynamic> toJson() => _$SingleTrackToJson(this);

  void cancelDownload() {
    if (cancelCallback == null) {
      debugPrint('Tried to cancel an uncancellable video');
      return;
    }
    cancelCallback!();
  }

  /// 调度异步保存，使用 Isolate 处理 JSON 编码
  void _scheduleSave() {
    if (_prefs == null) return;

    _hasPendingSave = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 200), () {
      if (_hasPendingSave) {
        _hasPendingSave = false;
        _saveToPreferences();
      }
    });
  }

  /// 异步保存到 SharedPreferences，使用 Isolate 处理 JSON
  Future<void> _saveToPreferences() async {
    final prefs = _prefs;
    if (prefs == null) return;

    try {
      // 先转换为 JSON Map，然后使用 Isolate 编码，避免发送整个对象（包含 Timer 等不可序列化字段）
      final jsonMap = toJson();
      // 清理 null 值，避免序列化错误
      final cleanedMap = _cleanJsonMap(jsonMap);
      final jsonString = await _jsonProcessor.encode(cleanedMap);
      await prefs.setString('video_$id', jsonString);
    } catch (e) {
      debugPrint('Error saving SingleTrack $id: $e');
      // 如果 Isolate 失败，降级到同步编码
      try {
        final prefs2 = _prefs;
        if (prefs2 == null) return;
        final jsonMap = toJson();
        // 清理 null 值，避免序列化错误
        final cleanedMap = _cleanJsonMap(jsonMap);
        final jsonString = json.encode(cleanedMap);
        await prefs2.setString('video_$id', jsonString);
      } catch (e2) {
        debugPrint('Error in fallback save: $e2');
      }
    }
  }

  /// 清理 JSON Map 中的 null 值
  Map<String, dynamic> _cleanJsonMap(Map<String, dynamic> map) {
    final cleaned = <String, dynamic>{};
    for (final entry in map.entries) {
      if (entry.value != null) {
        if (entry.value is Map) {
          cleaned[entry.key] = _cleanJsonMap(entry.value as Map<String, dynamic>);
        } else if (entry.value is List) {
          cleaned[entry.key] = (entry.value as List).map((e) {
            if (e is Map) {
              return _cleanJsonMap(e as Map<String, dynamic>);
            }
            return e;
          }).toList();
        } else {
          cleaned[entry.key] = entry.value;
        }
      }
    }
    return cleaned;
  }

  /// 调度通知，批量更新避免频繁重建 UI
  void _scheduleNotify() {
    _hasPendingNotify = true;
    // 使用微任务批量处理通知
    Future.microtask(() {
      if (_hasPendingNotify) {
        _hasPendingNotify = false;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // 确保所有待保存的数据都被保存
    if (_hasPendingSave) {
      _saveToPreferences();
    }
    super.dispose();
  }
}

@JsonSerializable()
class MuxedTrack extends SingleTrack {
  final SingleTrack audio;
  final SingleTrack video;

  @JsonKey()
  @override
  final StreamType streamType;

  MuxedTrack(int id, String icon, String path, String title, String size, int totalSize, this.audio, this.video, {SharedPreferences? prefs, this.streamType = StreamType.video, required String language, String? des}) : super(id, icon, path, title, size, totalSize, streamType, prefs: prefs, videoId: video.videoId, language: language, des: des);

  factory MuxedTrack.fromJson(Map<String, dynamic> json) => _$MuxedTrackFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$MuxedTrackToJson(this);
}
