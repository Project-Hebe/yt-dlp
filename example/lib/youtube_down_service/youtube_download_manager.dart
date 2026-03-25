import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yt_dlp_dart/yt_dlp.dart' hide DownloadStatus;
import 'audio_export_manager.dart';
import 'preferences_service.dart';
import 'task_entity/single_track_entity.dart';
import 'utils/json_processor.dart';
import 'utils/youtube_download_settings.dart';
import 'video_post_processor.dart';
import 'youtube_download_help.dart';

/// 下载失败事件
class DownloadFailureEvent {
  final SingleTrack track;
  final String error;

  DownloadFailureEvent({
    required this.track,
    required this.error,
  });
}

/// 等待下载的任务信息
class _PendingDownloadTask {
  final VideoInfo videoInfo;
  final VideoFormat format;
  final String saveDir;
  final int id;
  final StreamType type;
  final SingleTrack track;

  _PendingDownloadTask({
    required this.videoInfo,
    required this.format,
    required this.saveDir,
    required this.id,
    required this.type,
    required this.track,
  });
}

class DownloadManager extends ChangeNotifier {
  DownloadManager();
  Future<void> downloadFormat(VideoInfo videoInfo, VideoFormat format, Settings settings, StreamType type) => throw UnimplementedError();

  Future<void> removeVideo(SingleTrack video) => throw UnimplementedError();

  Future<void> retryDownload(SingleTrack video) => throw UnimplementedError();

  Future<void> resumeDownload(SingleTrack video) => throw UnimplementedError();

  List<SingleTrack> get videos => throw UnimplementedError();

  /// 根据视频ID判断是否正在处理中（包括下载中、等待中、混流中、导出中）
  bool isVideoProcessing(String videoId) => throw UnimplementedError();
}

class DownloadManagerImpl extends ChangeNotifier implements DownloadManager {
  static final invalidChars = RegExp(r'[\\\/:*?"<>|]');
  final SharedPreferences _prefs = PreferencesService().getPrex();
  @override
  final List<SingleTrack> videos;
  final List<String> videoIds;

  final Map<int, bool> cancelTokens = {};
  // 用于检查重复下载的映射：videoId -> SingleTrack
  final Map<String, SingleTrack> _videoIdToTrack = {};

  // yt_dlp 实例
  final YtDlp _ytDlp = YtDlp(verbose: false);

  // 存储视频信息：videoId -> VideoInfo
  final Map<String, VideoInfo> _videoInfoCache = {};

  // 音频导出管理器
  final AudioExportManager _audioExportManager = AudioExportManager.instance;

  // 是否自动导出音频（默认启用）
  bool _autoExportEnabled = false;

  // 导出任务状态监听器映射：trackId -> StreamSubscription
  final Map<int, StreamSubscription<AudioExportTask>> _exportTaskListeners = {};

  // 下载失败事件 StreamController
  final StreamController<DownloadFailureEvent> _failureEventController = StreamController<DownloadFailureEvent>.broadcast();

  /// 下载失败事件 Stream，供外部监听
  Stream<DownloadFailureEvent> get failureEvents => _failureEventController.stream;

  /// 是否启用自动导出
  bool get autoExportEnabled => _autoExportEnabled;

  /// 设置是否启用自动导出
  void setAutoExportEnabled(bool enabled) {
    _autoExportEnabled = enabled;
    _prefs.setBool('auto_export_enabled', enabled);
  }

  // 并发下载限制相关
  /// 最大同时下载数量，默认值为 3
  int maxConcurrent = 3;

  /// 正在运行的下载任务集合
  final Set<SingleTrack> _runningDownloads = {};

  /// 等待下载的任务队列
  final List<_PendingDownloadTask> _waitingDownloads = [];

  /// 正在处理中的视频ID集合（用于防止重复请求）
  final Set<String> _processingVideoIds = {};

  // 性能优化相关
  /// 进度更新节流定时器
  Timer? _progressUpdateTimer;
  bool _hasPendingProgressUpdate = false;

  /// 最小入队间隔，避免阻塞消息循环
  static const Duration _minEnqueueInterval = Duration(milliseconds: 20);
  DateTime? _lastEnqueueTime;

  /// 批量保存定时器
  Timer? _batchSaveTimer;
  final Set<String> _pendingSaveIds = {};

  int _nextId;

  int get nextId {
    _prefs.setInt('next_id', ++_nextId);
    return _nextId;
  }

  DownloadManagerImpl._(this._nextId, this.videoIds, this.videos);

  void addVideo(SingleTrack video) {
    final id = 'video_${video.id}';
    videoIds.add(id);

    // 异步保存，不阻塞主线程
    _prefs.setStringList('video_list', videoIds);
    _scheduleBatchSave(id);

    notifyListeners();
  }

  /// 批量保存视频数据，避免频繁写入
  void _scheduleBatchSave(String id) {
    _pendingSaveIds.add(id);

    _batchSaveTimer?.cancel();
    _batchSaveTimer = Timer(const Duration(milliseconds: 300), () {
      _flushBatchSave();
    });
  }

  /// 执行批量保存
  Future<void> _flushBatchSave() async {
    if (_pendingSaveIds.isEmpty) return;

    final idsToSave = List<String>.from(_pendingSaveIds);
    _pendingSaveIds.clear();

    // 在后台 isolate 或异步执行 JSON 编码和保存
    await Future.microtask(() async {
      for (final id in idsToSave) {
        SingleTrack? video;
        for (final v in videos) {
          if ('video_${v.id}' == id) {
            video = v;
            break;
          }
        }
        if (video == null) {
          debugPrint('_flushBatchSave: skip save, video not in list for $id');
          continue;
        }
        try {
          // 先转换为 JSON Map，避免序列化不可序列化的字段（如 Timer）
          final jsonMap = video.toJson();
          final jsonString = json.encode(jsonMap);
          await _prefs.setString(id, jsonString);
        } catch (e) {
          debugPrint('Error saving video $id: $e');
        }
      }
    });
  }

  @override
  Future<void> removeVideo(SingleTrack video) async {
    final id = 'video_${video.id}';
    videoIds.remove(id);
    videos.removeWhere((e) => e.id == video.id);

    // 从映射中移除对应的videoId，同时从处理集合中移除
    _videoIdToTrack.removeWhere((videoId, track) {
      if (track.id == video.id) {
        _processingVideoIds.remove(videoId);
        return true;
      }
      return false;
    });

    // 从运行列表移除
    _runningDownloads.remove(video);

    // 从等待队列移除
    _waitingDownloads.removeWhere((task) => task.track.id == video.id);

    _prefs.setStringList('video_list', videoIds);
    _prefs.remove(id);

    final filePath = await video.getAbsolutePath();
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }

    // 推进队列，启动下一个等待的任务
    _advanceQueue();

    notifyListeners();
  }

  /// 根据 videoId 删除所有匹配的任务
  ///
  /// 删除所有匹配指定 videoId 的下载任务
  Future<void> removeVideoByVideoId(String videoId) async {
    if (videoId.isEmpty) {
      return;
    }

    // 查找所有匹配该 videoId 的 track
    final tracksToRemove = videos.where((track) => track.videoId == videoId).toList();

    if (tracksToRemove.isEmpty) {
      return;
    }

    // 对每个 track 调用 removeVideo 方法
    for (final track in tracksToRemove) {
      await removeVideo(track);
    }
  }

  Future<String> getValidPath(String strPath) async {
    final file = File(strPath);
    if (!(await file.exists())) {
      return strPath;
    }
    final basename = path.withoutExtension(strPath).replaceFirst(RegExp(r' \([0-9]+\)$'), '');
    final ext = path.extension(strPath);

    var count = 0;

    while (true) {
      final newPath = '$basename (${++count})$ext';
      final file = File(newPath);
      if (await file.exists()) {
        continue;
      }
      return newPath;
    }
  }

  @override
  Future<void> downloadFormat(VideoInfo videoInfo, VideoFormat format, Settings settings, StreamType type) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final req = await Permission.storage.request();
      if (!req.isGranted) {
        return;
      }
    }

    final id = nextId;
    final saveDir = settings.downloadPath;
    // 从格式中获取语言信息，如果没有则使用空字符串
    final language = format.language ?? '';
    await processSingleTrack(videoInfo, format, saveDir, id, type, language);
  }

  Future<void> processSingleTrack(
    VideoInfo videoInfo,
    VideoFormat format,
    String saveDir,
    int id,
    StreamType type,
    String language, {
    String? customTitle,
    String? customCover,
    String? customDes,
  }) async {
    final ext = format.ext ?? 'mp4';
    final videoId = videoInfo.id;
    // 如果提供了自定义标题，优先使用；否则使用 videoInfo 的标题
    final title = customTitle ?? videoInfo.title ?? 'video';
    // 使用 videoId 作为文件名，避免 title 中的编码问题和特殊字符
    final downloadPath = await getValidPath('${path.join(saveDir, videoId)}.$ext');

    // 将绝对路径转换为相对路径（相对于 Documents 目录）以便保存
    // 总是保存相对路径，这样即使沙盒路径变化也能正常工作
    final relativePath = await _getRelativePath(downloadPath);
    // 如果无法计算相对路径（不在 Documents 目录下），保存完整绝对路径
    // 这样可以确保 retryDownload 时能找到文件
    final pathToSave = relativePath ?? downloadPath;

    final totalSize = format.filesize ?? 0;
    // 如果提供了自定义封面，优先使用；否则使用 videoInfo 的缩略图
    final thumbnail = customCover ?? videoInfo.thumbnail ?? '';
    final downloadVideo = SingleTrack(
      id,
      thumbnail,
      pathToSave, // 总是保存相对路径或文件名
      title,
      YoutubeDownloadHelp.bytesToString(totalSize),
      totalSize,
      type,
      prefs: _prefs,
      videoId: videoId,
      language: language,
      des: customDes,
    );

    addVideo(downloadVideo);
    videos.add(downloadVideo);

    // 更新videoId到track的映射
    _videoIdToTrack[videoId] = downloadVideo;

    // 检查文件是否存在，如果存在则获取已下载的字节数（断点续传）
    final file = File(downloadPath);
    int startByte = 0;
    if (await file.exists()) {
      startByte = await file.length();
      if (startByte > 0) {
        downloadVideo.downloadedBytes = startByte;
        downloadVideo.downloadPerc = totalSize > 0 ? (startByte / totalSize * 100).floor() : 0;
      }
    }

    // 检查并发下载数量限制
    if (_runningDownloads.length >= maxConcurrent) {
      // 达到最大并发数，加入等待队列
      downloadVideo.downloadStatus = DownloadStatus.waiting; // 标记为等待中
      _waitingDownloads.add(_PendingDownloadTask(
        videoInfo: videoInfo,
        format: format,
        saveDir: saveDir,
        id: id,
        type: type,
        track: downloadVideo,
      ));
      notifyListeners();
      return;
    }

    // 没有达到限制，立即开始下载
    await _startDownload(downloadVideo, videoInfo, format, downloadPath, title, totalSize, videoId);
  }

  /// 开始下载任务
  Future<void> _startDownload(
    SingleTrack downloadVideo,
    VideoInfo videoInfo,
    VideoFormat format,
    String downloadPath,
    String title,
    int totalSize,
    String videoId,
  ) async {
    // 添加到运行列表
    _runningDownloads.add(downloadVideo);
    downloadVideo.downloadStatus = DownloadStatus.downloading;
    notifyListeners();

    // 存储取消标志
    bool isCanceled = false;
    downloadVideo.cancelCallback = () {
      isCanceled = true;
      downloadVideo.downloadStatus = DownloadStatus.canceled;
      _videoIdToTrack.remove(videoId);
      // 从运行列表移除
      _runningDownloads.remove(downloadVideo);
      // 推进队列
      _advanceQueue();
      notifyListeners();
    };

    try {
      // 使用 yt_dlp 下载
      await _ytDlp.downloadFormat(
        format,
        outputPath: downloadPath,
        title: title,
        onProgress: ({
          required int downloadedBytes,
          int? totalBytes,
          required double progress,
          double? speed,
        }) {
          if (isCanceled) return;
          downloadVideo.downloadedBytes = downloadedBytes;
          downloadVideo.downloadPerc = progress.floor();
          // 使用节流更新，避免过于频繁的 UI 刷新
          _throttledNotifyListeners();
        },
      );

      if (!isCanceled) {
        downloadVideo.downloadStatus = DownloadStatus.success;
        downloadVideo.downloadedBytes = totalSize;
        downloadVideo.downloadPerc = 100;

        // 如果启用自动导出，且是音频或视频类型，自动触发导出
        if (_autoExportEnabled) {
          _triggerAutoExport(downloadVideo);
        }
      }
    } catch (error) {
      if (!isCanceled) {
        downloadVideo.downloadStatus = DownloadStatus.failed;
        downloadVideo.error = error.toString();
        debugPrint('Download Failed: $error');
        // 失败时从映射中移除，允许重新下载
        _videoIdToTrack.remove(videoId);
        // 发送失败事件
        _failureEventController.add(DownloadFailureEvent(
          track: downloadVideo,
          error: error.toString(),
        ));
      }
    } finally {
      // 从运行列表移除
      _runningDownloads.remove(downloadVideo);
      // 推进队列，启动下一个等待的任务
      _advanceQueue();
      notifyListeners();
    }
  }

  /// 推进等待队列，启动下一个可以下载的任务
  void _advanceQueue() async {
    // 检查最小入队间隔
    final now = DateTime.now();
    if (_lastEnqueueTime != null) {
      final elapsed = now.difference(_lastEnqueueTime!);
      if (elapsed < _minEnqueueInterval) {
        await Future.delayed(_minEnqueueInterval - elapsed);
      }
    }
    _lastEnqueueTime = DateTime.now();

    while (_runningDownloads.length < maxConcurrent && _waitingDownloads.isNotEmpty) {
      final pendingTask = _waitingDownloads.removeAt(0);
      // 检查任务是否已被取消或移除
      if (!videos.contains(pendingTask.track) || pendingTask.track.downloadStatus == DownloadStatus.canceled) {
        continue;
      }
      // 开始下载
      _startDownload(
        pendingTask.track,
        pendingTask.videoInfo,
        pendingTask.format,
        await pendingTask.track.getAbsolutePath(),
        pendingTask.track.title,
        pendingTask.track.totalSize,
        pendingTask.videoInfo.id,
      );
    }
  }

  /// 节流通知监听器，避免过于频繁的 UI 更新
  void _throttledNotifyListeners() {
    _hasPendingProgressUpdate = true;
    _progressUpdateTimer?.cancel();
    _progressUpdateTimer = Timer(const Duration(milliseconds: 100), () {
      if (_hasPendingProgressUpdate) {
        _hasPendingProgressUpdate = false;
        notifyListeners();
      }
    });
  }

  /// 根据视频ID判断是否正在处理中（包括下载中、等待中、混流中、导出中）
  ///
  /// 返回 true 表示视频正在处理中，false 表示未在处理中或不存在
  @override
  bool isVideoProcessing(String videoId) {
    if (videoId.isEmpty) {
      return false;
    }

    // 优先从映射中查找对应的 track（性能更好）
    final track = _videoIdToTrack[videoId];
    if (track != null) {
      return _isStatusProcessing(track.downloadStatus);
    }

    // 如果映射中没有，尝试从 videos 列表中查找（兼容性检查）
    try {
      final existingTrack = videos.firstWhere(
        (t) => t.videoId == videoId,
      );
      return _isStatusProcessing(existingTrack.downloadStatus);
    } catch (e) {
      // 没有找到对应的 track
      return false;
    }
  }

  /// 判断状态是否在处理中
  bool _isStatusProcessing(DownloadStatus status) {
    return status == DownloadStatus.querying || status == DownloadStatus.downloading || status == DownloadStatus.waiting || status == DownloadStatus.muxing || status == DownloadStatus.exporting || status == DownloadStatus.retrying || status == DownloadStatus.uploading;
  }

  @override
  void dispose() {
    _progressUpdateTimer?.cancel();
    _batchSaveTimer?.cancel();
    // 取消所有导出任务监听
    for (final subscription in _exportTaskListeners.values) {
      subscription.cancel();
    }
    _exportTaskListeners.clear();
    // 关闭失败事件 StreamController
    _failureEventController.close();
    // 确保所有待保存的数据都被保存
    _flushBatchSave();
    super.dispose();
  }

  static Future<DownloadManagerImpl> init() async {
    await PreferencesService().init();
    final prefs = PreferencesService().getPrex();
    var videoIds = prefs.getStringList('video_list');
    var nextId = prefs.getInt('next_id');
    if (videoIds == null) {
      prefs.setStringList('video_list', const []);
      videoIds = <String>[];
    }
    if (nextId == null) {
      prefs.setInt('next_id', 0);
      nextId = 1;
    }
    final videos = <SingleTrack>[];
    final instance = DownloadManagerImpl._(nextId, videoIds, videos);

    // 加载自动导出设置
    instance._autoExportEnabled = prefs.getBool('auto_export_enabled') ?? true;

    // 初始化音频导出管理器
    AudioExportManager.instance.initialize();

    // 设置导出状态同步监听
    _setupExportStatusSync(instance);

    // 异步加载任务，不阻塞初始化
    _loadTracksAsync(instance, prefs, videoIds, videos);

    return instance;
  }

  /// 设置导出状态同步监听
  /// 监听所有导出任务的状态变化，并同步到对应的 SingleTrack
  static void _setupExportStatusSync(DownloadManagerImpl instance) {
    // 监听 AudioExportManager 的所有任务更新
    // 当有新的导出任务创建时，自动设置监听
    AudioExportManager.instance.addListener(() {
      // 当 AudioExportManager 状态变化时，检查所有任务
      _syncAllExportStatuses(instance).catchError((e) {
        debugPrint('_setupExportStatusSync: Error syncing export statuses: $e');
      });
    });

    // 立即同步一次已存在的任务
    _syncAllExportStatuses(instance).catchError((e) {
      debugPrint('_setupExportStatusSync: Error syncing export statuses: $e');
    });
  }

  /// 同步所有导出任务的状态到对应的 SingleTrack
  static Future<void> _syncAllExportStatuses(DownloadManagerImpl instance) async {
    final audioManager = AudioExportManager.instance;
    final exportTasks = audioManager.exportTasks;

    for (final exportTask in exportTasks) {
      final trackId = exportTask.trackId;

      // 查找对应的 SingleTrack
      SingleTrack? track;
      try {
        track = instance.videos.firstWhere((t) => t.id == trackId);
      } catch (e) {
        // Track 不存在，跳过
        continue;
      }

      // 根据导出状态更新 SingleTrack 状态
      switch (exportTask.status) {
        case ExportStatus.pending:
          // 如果 track 是成功状态，设置为导出中
          if (track.downloadStatus == DownloadStatus.success) {
            track.downloadStatus = DownloadStatus.exporting;
            track.downloadPerc = 0;
          }
          break;
        case ExportStatus.processing:
          track.downloadStatus = DownloadStatus.exporting;
          track.downloadPerc = (exportTask.progress * 100).floor().clamp(0, 100);
          break;
        case ExportStatus.completed:
          track.downloadStatus = DownloadStatus.success;
          track.downloadPerc = 100;
          track.error = '';
          await _updateTrackExportedAudioInfo(track, exportTask);
          break;
        case ExportStatus.failed:
          // 导出失败不影响下载成功状态
          track.downloadStatus = DownloadStatus.success;
          track.error = exportTask.error ?? 'Export failed';
          break;
      }

      // 为每个任务设置独立的监听（如果还没有设置）
      if (!instance._exportTaskListeners.containsKey(trackId)) {
        _setupTaskStatusListener(instance, trackId, track);
      }
    }

    instance.notifyListeners();
  }

  /// 为单个导出任务设置状态监听
  static void _setupTaskStatusListener(DownloadManagerImpl instance, int trackId, SingleTrack track) {
    final taskStream = AudioExportManager.instance.watchTask(trackId);
    if (taskStream == null) return;

    // 记录监听器，避免重复设置
    instance._exportTaskListeners[trackId] = taskStream.listen((task) async {
      // 更新导出进度
      track.downloadPerc = (task.progress * 100).floor().clamp(0, 100);

      // 根据导出状态更新 SingleTrack 状态
      switch (task.status) {
        case ExportStatus.pending:
          if (track.downloadStatus == DownloadStatus.success) {
            track.downloadStatus = DownloadStatus.exporting;
          }
          break;
        case ExportStatus.processing:
          track.downloadStatus = DownloadStatus.exporting;
          break;
        case ExportStatus.completed:
          track.downloadStatus = DownloadStatus.success;
          track.downloadPerc = 100;
          track.error = '';
          await _updateTrackExportedAudioInfo(track, task);
          break;
        case ExportStatus.failed:
          // 导出失败不影响下载成功状态
          track.downloadStatus = DownloadStatus.success;
          track.error = task.error ?? 'Export failed';
          break;
      }

      instance.notifyListeners();
    });
  }

  /// 异步加载任务列表，使用 Isolate 处理 JSON 解码
  static Future<void> _loadTracksAsync(
    DownloadManagerImpl instance,
    SharedPreferences prefs,
    List<String> videoIds,
    List<SingleTrack> videos,
  ) async {
    final jsonProcessor = JsonProcessor();

    // 批量解码，使用 Isolate 避免阻塞主线程
    for (final id in videoIds) {
      try {
        final jsonVideo = prefs.getString(id);
        if (jsonVideo == null) continue;

        // 使用 Isolate 异步解码 JSON
        final jsonMap = await jsonProcessor.decode(jsonVideo);
        final track = SingleTrack.fromJson(jsonMap);

        // 检查临时文件是否存在，如果存在则标记为暂停状态，可以恢复下载
        if (track.downloadStatus == DownloadStatus.downloading || track.downloadStatus == DownloadStatus.muxing) {
          final absolutePath = await track.getAbsolutePath();
          final tempFile = File(absolutePath);
          if (await tempFile.exists()) {
            // 更新已下载的字节数（使用异步方法）
            final fileSize = await tempFile.length();
            track.downloadedBytes = fileSize;
            track.downloadPerc = track.totalSize > 0 ? (fileSize / track.totalSize * 100).floor() : 0;
            track.downloadStatus = DownloadStatus.paused;
            track.error = '';
          } else {
            track.downloadStatus = DownloadStatus.failed;
            track.error = 'Error occurred while downloading';
          }
          // 异步保存更新
          // 先转换为 JSON Map，然后使用 Isolate 编码，避免发送整个对象（包含 Timer 等不可序列化字段）
          final jsonMap = track.toJson();
          final jsonString = await jsonProcessor.encode(jsonMap);
          await prefs.setString(id, jsonString);
        }

        // 检查导出状态，同步到 SingleTrack
        final exportTask = AudioExportManager.instance.getTask(track.id);
        if (exportTask != null) {
          // 根据导出任务状态更新 SingleTrack 状态
          switch (exportTask.status) {
            case ExportStatus.pending:
              if (track.downloadStatus == DownloadStatus.success) {
                track.downloadStatus = DownloadStatus.exporting;
                track.downloadPerc = 0;
              }
              break;
            case ExportStatus.processing:
              track.downloadStatus = DownloadStatus.exporting;
              track.downloadPerc = (exportTask.progress * 100).floor().clamp(0, 100);
              break;
            case ExportStatus.completed:
              track.downloadStatus = DownloadStatus.success;
              track.downloadPerc = 100;
              track.error = '';
              await _updateTrackExportedAudioInfo(track, exportTask);
              break;
            case ExportStatus.failed:
              // 导出失败不影响下载成功状态
              track.downloadStatus = DownloadStatus.success;
              track.error = exportTask.error ?? 'Export failed';
              break;
          }

          // 为每个导出任务设置状态监听（如果还没有设置）
          if (!instance._exportTaskListeners.containsKey(track.id)) {
            _setupTaskStatusListener(instance, track.id, track);
          }
        }

        videos.add(track);
        // 如果track有videoId，恢复映射关系
        if (track.videoId.isNotEmpty) {
          instance._videoIdToTrack[track.videoId] = track;
        }
      } catch (e) {
        debugPrint('Error loading track $id: $e');
        // 如果解码失败，尝试降级到同步解码
        try {
          final jsonVideo = prefs.getString(id);
          if (jsonVideo != null) {
            final track = SingleTrack.fromJson(json.decode(jsonVideo) as Map<String, dynamic>);
            // 路径已经是相对路径，使用时通过 getAbsolutePath() 获取
            videos.add(track);
            if (track.videoId.isNotEmpty) {
              instance._videoIdToTrack[track.videoId] = track;
            }
          }
        } catch (e2) {
          debugPrint('Error in fallback decode for $id: $e2');
        }
      }
    }

    // 通知 UI 更新
    instance.notifyListeners();
  }

  Future<void> beginDownLoadVideo(String videoId, String languageCode, {String? cover, String? title, String? des}) async {
    if (videoId.isEmpty) {
      return;
    }
    try {
      // 首先检查 _videoIdToTrack 映射（更快，O(1)）
      final existingTrackInMap = _videoIdToTrack[videoId];
      if (existingTrackInMap != null) {
        final status = existingTrackInMap.downloadStatus;
        // 如果正在处理中（不包括重试），直接返回
        if (status == DownloadStatus.downloading || status == DownloadStatus.muxing || status == DownloadStatus.querying || status == DownloadStatus.waiting || status == DownloadStatus.exporting) {
          // 正在处理中，直接返回
          return;
        }
        // 状态是 canceled、failed、paused 或 retrying，移除旧任务
        _videoIdToTrack.remove(videoId);
        _processingVideoIds.remove(videoId); // 确保从处理集合中移除
        videos.remove(existingTrackInMap);
        final idString = 'video_${existingTrackInMap.id}';
        videoIds.remove(idString);
        _prefs.remove(idString);
        _prefs.setStringList('video_list', videoIds);
        notifyListeners();
      } else {
        // 如果映射中没有，再检查 videos 列表（兼容性检查）
        try {
          final existingTrack = videos.firstWhere(
            (track) => track.videoId == videoId,
          );
          final status = existingTrack.downloadStatus;
          if (status != DownloadStatus.canceled && status != DownloadStatus.failed) {
            // 如果在处理中，同步到映射中
            _videoIdToTrack[videoId] = existingTrack;
            return;
          }
          // 状态是 canceled 或 failed，移除旧任务
          videos.remove(existingTrack);
          _processingVideoIds.remove(videoId); // 确保从处理集合中移除
          final idString = 'video_${existingTrack.id}';
          videoIds.remove(idString);
          _prefs.remove(idString);
          _prefs.setStringList('video_list', videoIds);
          notifyListeners();
        } catch (e) {
          // 没有找到，继续执行
        }
      }

      // 检查是否正在创建 placeholderTrack（防止重复请求）
      if (_processingVideoIds.contains(videoId)) {
        return;
      }

      // 立即标记为正在处理中（防止重复请求）
      _processingVideoIds.add(videoId);

      // 立即创建占位任务并加入队列，查询视频信息作为下载任务的一部分
      final id = nextId;
      final setting = await SettingsImpl.init();
      // 使用 videoId 作为临时文件名，避免编码问题
      final tempPath = path.join(setting.downloadPath, '$videoId.temp');
      final placeholderTrack = SingleTrack(
        id,
        cover ?? '',
        tempPath,
        title ?? 'Querying video info...',
        '0 B',
        0,
        StreamType.audio,
        prefs: _prefs,
        videoId: videoId,
        language: languageCode,
        des: des,
      );
      placeholderTrack.downloadStatus = DownloadStatus.querying;

      // 记录videoId到track的映射
      _videoIdToTrack[videoId] = placeholderTrack;

      // 立即加入队列
      addVideo(placeholderTrack);
      videos.add(placeholderTrack);
      notifyListeners(); // 立即通知UI更新

      // 设置取消回调，允许用户取消查询操作
      placeholderTrack.cancelCallback = () {
        videos.remove(placeholderTrack);
        final idString = 'video_${placeholderTrack.id}';
        videoIds.remove(idString);
        _prefs.remove(idString);
        _prefs.setStringList('video_list', videoIds);
        _videoIdToTrack.remove(videoId); // 从映射中移除
        _processingVideoIds.remove(videoId); // 从处理集合中移除
        // 从运行列表和等待队列移除
        _runningDownloads.remove(placeholderTrack);
        _waitingDownloads.removeWhere((task) => task.track.id == placeholderTrack.id);
        notifyListeners();
        placeholderTrack.downloadStatus = DownloadStatus.canceled;
      };
      // 注意：_fetchAndDownloadVideoInfo 内部会在所有返回点移除 _processingVideoIds
      _fetchAndDownloadVideoInfo(videoId, placeholderTrack, setting, languageCode: languageCode);
    } catch (e) {
      debugPrint('Error in beginDownLoadVideo: $e');
      // 如果出错，从映射和处理集合中移除
      _videoIdToTrack.remove(videoId);
      _processingVideoIds.remove(videoId);
    }
  }

  @override
  Future<void> retryDownload(SingleTrack video) async {
    // 检查是否有 videoId
    if (video.videoId.isEmpty) {
      return;
    }

    // 如果任务正在下载中，不需要重试
    if (video.downloadStatus == DownloadStatus.downloading || video.downloadStatus == DownloadStatus.muxing || video.downloadStatus == DownloadStatus.querying || video.downloadStatus == DownloadStatus.retrying) {
      return;
    }

    final videoId = video.videoId;

    // 如果任务已经有完整信息（totalSize > 0），说明之前已经获取过流信息
    // 可以直接恢复下载，只需要获取 manifest，不需要重新查询视频信息
    if (video.totalSize > 0 && video.title.isNotEmpty && video.title != 'Querying video info...') {
      await _resumeDownloadWithExistingInfo(video);
      return;
    }

    // 如果任务信息不完整，移除旧任务并重新开始
    // 保存原任务的信息，以便重试时保持
    final savedLanguage = video.language;
    // 保存原视频的标题、封面和描述，避免重试时丢失
    final savedTitle = (video.title.isNotEmpty && video.title != 'Querying video info...') ? video.title : null;
    final savedCover = video.icon.isNotEmpty ? video.icon : null;
    final savedDes = video.des;
    final tracksToRemove = videos.where((track) => track.videoId == videoId).toList();
    for (final track in tracksToRemove) {
      videos.remove(track);
      final idString = 'video_${track.id}';
      videoIds.remove(idString);
      _prefs.remove(idString);
    }
    _prefs.setStringList('video_list', videoIds);
    _videoIdToTrack.remove(videoId);
    notifyListeners();

    // 重新开始下载，保持原语言信息、标题、封面和描述
    // beginDownLoadVideo 内部会创建新的 placeholderTrack，状态为 querying
    // 如果是从失败状态重试，会在 _fetchAndDownloadVideoInfo 中从 querying 开始
    await beginDownLoadVideo(videoId, savedLanguage, cover: savedCover, title: savedTitle, des: savedDes);
  }

  @override
  Future<void> resumeDownload(SingleTrack video) async {
    // 检查是否有 videoId
    if (video.videoId.isEmpty) {
      return;
    }

    // 如果任务正在下载中，不需要恢复
    if (video.downloadStatus == DownloadStatus.downloading || video.downloadStatus == DownloadStatus.muxing || video.downloadStatus == DownloadStatus.querying || video.downloadStatus == DownloadStatus.retrying) {
      return;
    }

    // 检查临时文件是否存在
    final filePath = await video.getAbsolutePath();
    final tempFile = File(filePath);
    final hasTempFile = await tempFile.exists();

    if (hasTempFile && video.totalSize > 0) {
      // 如果任务已经有完整信息（title 不是占位符），直接使用已有信息恢复
      if (video.title.isNotEmpty && video.title != 'Querying video info...') {
        await _resumeDownloadWithExistingInfo(video);
        return;
      }
    }

    // 如果没有临时文件或信息不完整，降级为重试
    await retryDownload(video);
  }

  /// 使用已有信息恢复下载（不重新查询视频信息）
  Future<void> _resumeDownloadWithExistingInfo(SingleTrack existingTrack) async {
    final videoId = existingTrack.videoId;

    // 检查是否已经有相同 videoId 的任务在下载
    SingleTrack? existingActiveTrack;
    try {
      existingActiveTrack = videos.firstWhere(
        (track) => track.videoId == videoId && (track.downloadStatus == DownloadStatus.downloading || track.downloadStatus == DownloadStatus.muxing || track.downloadStatus == DownloadStatus.querying || track.downloadStatus == DownloadStatus.retrying),
      );
    } catch (e) {
      existingActiveTrack = null;
    }

    if (existingActiveTrack != null) {
      return;
    }

    // 检查任务信息是否完整
    if (existingTrack.totalSize <= 0 || existingTrack.title.isEmpty || existingTrack.title == 'Querying video info...') {
      // 信息不完整，降级为重试（会重新查询）
      await retryDownload(existingTrack);
      return;
    }

    // 获取文件路径并检查文件是否存在
    String filePath = await existingTrack.getAbsolutePath();

    // 如果路径为空，说明路径配置有问题，需要重新下载
    if (filePath.isEmpty) {
      // 降级为重新下载：移除旧任务并重新开始
      final savedLanguage = existingTrack.language;
      final tracksToRemove = videos.where((track) => track.videoId == videoId).toList();
      for (final track in tracksToRemove) {
        videos.remove(track);
        final idString = 'video_${track.id}';
        videoIds.remove(idString);
        _prefs.remove(idString);
      }
      _prefs.setStringList('video_list', videoIds);
      _videoIdToTrack.remove(videoId);
      notifyListeners();
      await beginDownLoadVideo(videoId, savedLanguage);
      return;
    }

    File file = File(filePath);

    // 如果文件不存在，尝试从下载目录查找（处理旧数据只保存了文件名的情况）
    if (!await file.exists()) {
      // 检查保存的路径是否只是文件名（不包含目录分隔符）
      final savedPath = existingTrack.path;
      if (savedPath.isNotEmpty && !path.isAbsolute(savedPath) && !savedPath.contains(path.separator)) {
        // 只是文件名，尝试从当前下载目录查找
        try {
          final settings = await SettingsImpl.init();
          final downloadDir = settings.downloadPath;
          final possiblePath = path.join(downloadDir, savedPath);
          final possibleFile = File(possiblePath);
          if (await possibleFile.exists()) {
            // 找到了！更新路径为完整绝对路径
            filePath = possiblePath;
            existingTrack.path = possiblePath;
            file = possibleFile;
            debugPrint('Found file in download directory: $filePath');
          }
        } catch (e) {
          debugPrint('Error trying to find file in download directory: $e');
        }
      }
    }

    // 如果文件仍然不存在，需要重新下载而不是直接失败
    if (!await file.exists()) {
      // 降级为重新下载：移除旧任务并重新开始
      final savedLanguage = existingTrack.language;
      final tracksToRemove = videos.where((track) => track.videoId == videoId).toList();
      for (final track in tracksToRemove) {
        videos.remove(track);
        final idString = 'video_${track.id}';
        videoIds.remove(idString);
        _prefs.remove(idString);
      }
      _prefs.setStringList('video_list', videoIds);
      _videoIdToTrack.remove(videoId);
      notifyListeners();
      await beginDownLoadVideo(videoId, savedLanguage);
      return;
    }

    // 获取已下载的字节数（从文件大小）
    final downloadedBytes = await file.length();
    existingTrack.downloadedBytes = downloadedBytes;
    existingTrack.downloadPerc = existingTrack.totalSize > 0 ? (downloadedBytes / existingTrack.totalSize * 100).floor().clamp(0, 100) : 0;

    // 如果文件已经下载完成，直接标记为成功
    if (downloadedBytes >= existingTrack.totalSize && existingTrack.totalSize > 0) {
      existingTrack.downloadStatus = DownloadStatus.success;
      existingTrack.downloadPerc = 100;

      // 检查是否有已完成的导出任务，同步导出音频信息
      final exportTask = AudioExportManager.instance.getTask(existingTrack.id);
      if (exportTask != null && exportTask.status == ExportStatus.completed) {
        await _updateTrackExportedAudioInfo(existingTrack, exportTask);
      } else if (exportTask == null && _autoExportEnabled) {
        await _triggerAutoExport(existingTrack);
      }

      notifyListeners();
      return;
    }

    // 更新 videoId 到 track 的映射
    _videoIdToTrack[videoId] = existingTrack;
    existingTrack.downloadStatus = DownloadStatus.downloading;
    notifyListeners();

    // 从缓存获取视频信息（如果存在），否则需要重新获取（但这是最后的选择）
    VideoInfo? videoInfo = _videoInfoCache[videoId];
    if (videoInfo == null) {
      // 缓存中没有，尝试重新获取（但这是不得已的情况）
      final videoUrl = 'https://www.youtube.com/watch?v=$videoId';
      try {
        videoInfo = await _ytDlp.extractInfo(videoUrl);
        _videoInfoCache[videoId] = videoInfo;
      } catch (e) {
        existingTrack.downloadStatus = DownloadStatus.failed;
        existingTrack.error = 'Failed to fetch video info for resume: $e';
        _failureEventController.add(DownloadFailureEvent(
          track: existingTrack,
          error: 'Failed to fetch video info for resume: $e',
        ));
        notifyListeners();
        return;
      }
    }

    if (videoInfo.formats.isEmpty) {
      existingTrack.downloadStatus = DownloadStatus.failed;
      existingTrack.error = 'No formats available';
      _failureEventController.add(DownloadFailureEvent(
        track: existingTrack,
        error: 'No formats available',
      ));
      notifyListeners();
      return;
    }

    // 根据 streamType 选择格式
    VideoFormat? selectedFormat;
    final type = existingTrack.streamType;

    if (type == StreamType.audio) {
      selectedFormat = FormatSelector.selectBestFormat(
        videoInfo.audioFormats,
        preferAudio: true,
      );
    } else {
      selectedFormat = FormatSelector.selectBestFormat(videoInfo.formats);
    }

    if (selectedFormat == null) {
      existingTrack.downloadStatus = DownloadStatus.failed;
      existingTrack.error = 'No suitable format found';
      _failureEventController.add(DownloadFailureEvent(
        track: existingTrack,
        error: 'No suitable format found',
      ));
      notifyListeners();
      return;
    }

    // 直接开始下载，使用已有的 track 和文件路径
    // 注意：这里不调用 processSingleTrack，因为它会创建新的 track
    // 而是直接调用 _startDownload，传入已有的 track
    try {
      await _startDownload(
        existingTrack,
        videoInfo,
        selectedFormat,
        filePath, // 使用已有的文件路径
        existingTrack.title,
        existingTrack.totalSize,
        videoId,
      );
    } catch (e) {
      existingTrack.downloadStatus = DownloadStatus.failed;
      existingTrack.error = 'Error resuming download: $e';
      _failureEventController.add(DownloadFailureEvent(
        track: existingTrack,
        error: 'Error resuming download: $e',
      ));
      notifyListeners();
    }
  }

  Future<void> _fetchAndDownloadVideoInfo(String videoId, SingleTrack placeholderTrack, Settings setting, {String? languageCode}) async {
    try {
      // 检查占位符是否已被取消
      if (!videos.contains(placeholderTrack) || placeholderTrack.downloadStatus == DownloadStatus.canceled) {
        _processingVideoIds.remove(videoId);
        return;
      }

      // 构建视频URL
      final videoUrl = 'https://www.youtube.com/watch?v=$videoId';

      // 使用 yt_dlp 获取视频信息
      final videoInfo = await _ytDlp.extractInfo(videoUrl);

      // 缓存视频信息
      _videoInfoCache[videoId] = videoInfo;

      // 再次检查是否已被取消
      if (!videos.contains(placeholderTrack) || placeholderTrack.downloadStatus == DownloadStatus.canceled) {
        _processingVideoIds.remove(videoId);
        return;
      }

      if (videoInfo.formats.isEmpty) {
        placeholderTrack.downloadStatus = DownloadStatus.failed;
        placeholderTrack.error = 'No formats available for this video';
        _failureEventController.add(DownloadFailureEvent(
          track: placeholderTrack,
          error: 'No formats available for this video',
        ));
        _processingVideoIds.remove(videoId);
        notifyListeners();
        return;
      }

      // 选择格式
      VideoFormat? selectedFormat;
      StreamType type;
      String? selectedLanguage; // 记录选择的语言

      if (languageCode != null && languageCode.isNotEmpty) {
        final formats = videoInfo.formats;
        final audioFormats = formats.where((f) => f.url != null && f.url!.isNotEmpty).toList();

        // 为每种语言保留质量最差的轨道（最低比特率和最小分辨率）
        final Map<String, VideoFormat> langWorst = {};
        for (final f in audioFormats) {
          final lang = f.language;
          if (lang == null || lang.isEmpty) {
            continue;
          }

          final abr = f.tbr ?? 0;
          final height = f.height ?? 0;

          if (!langWorst.containsKey(lang)) {
            langWorst[lang] = f;
          } else {
            final existing = langWorst[lang]!;
            final existingAbr = existing.tbr ?? 0;
            final existingHeight = existing.height ?? 0;
            // 优先选择更小的分辨率，如果相同则选择更低的比特率
            if (height < existingHeight || (height == existingHeight && abr < existingAbr)) {
              langWorst[lang] = f;
            }
          }
        }

        // 查找匹配的语言轨道
        VideoFormat? chosen;
        String? chosenLang;
        for (final entry in langWorst.entries) {
          if (entry.key.toLowerCase().startsWith(languageCode.toLowerCase())) {
            chosen = entry.value;
            chosenLang = entry.key;
            break;
          }
        }

        if (langWorst.isEmpty) {
          if (audioFormats.isNotEmpty) {
            chosen = audioFormats[0];
            chosenLang = languageCode;
            selectedFormat = chosen;
            selectedLanguage = chosenLang;
            type = StreamType.audio;
          } else {
            placeholderTrack.downloadStatus = DownloadStatus.failed;
            placeholderTrack.error = "No audio formats with manifest_url found";
            _failureEventController.add(DownloadFailureEvent(
              track: placeholderTrack,
              error: "No audio formats with manifest_url found",
            ));
            _processingVideoIds.remove(videoId);
            notifyListeners();
            return;
          }
        } else if (chosen == null) {
          // 没有选择任何音轨，设置错误状态并返回
          placeholderTrack.downloadStatus = DownloadStatus.failed;
          placeholderTrack.error = "No audio track found for language '$languageCode'";
          _failureEventController.add(DownloadFailureEvent(
            track: placeholderTrack,
            error: "No audio track found for language '$languageCode'",
          ));
          _processingVideoIds.remove(videoId);
          notifyListeners();
          return;
        } else {
          selectedFormat = chosen;
          selectedLanguage = chosenLang;
          type = StreamType.audio;
        }
      } else {
        // 默认选择最佳音频格式
        selectedFormat = FormatSelector.selectBestFormat(
          videoInfo.audioFormats,
          preferAudio: true,
        );
        type = StreamType.audio;
        // 如果没有指定语言，尝试从选中的格式中获取语言信息
        if (selectedFormat != null && selectedFormat.language != null && selectedFormat.language!.isNotEmpty) {
          selectedLanguage = selectedFormat.language;
        } else {
          selectedLanguage = '';
        }
      }

      if (selectedFormat == null) {
        // 如果没有音频格式，尝试选择视频格式
        selectedFormat = FormatSelector.selectBestFormat(videoInfo.formats);
        type = StreamType.video;
      }

      // 确保 selectedLanguage 不为 null
      selectedLanguage ??= '';

      if (selectedFormat == null) {
        placeholderTrack.downloadStatus = DownloadStatus.failed;
        placeholderTrack.error = 'No suitable format found';
        _failureEventController.add(DownloadFailureEvent(
          track: placeholderTrack,
          error: 'No suitable format found',
        ));
        _processingVideoIds.remove(videoId);
        notifyListeners();
        return;
      }

      // 最后一次检查是否已被取消
      if (!videos.contains(placeholderTrack) || placeholderTrack.downloadStatus == DownloadStatus.canceled) {
        _processingVideoIds.remove(videoId);
        return;
      }

      // 移除占位任务
      videos.remove(placeholderTrack);
      final idString = 'video_${placeholderTrack.id}';
      videoIds.remove(idString);
      _prefs.remove(idString);
      _prefs.setStringList('video_list', videoIds);

      // 开始下载
      try {
        // selectedLanguage 已经确保不为 null
        // 如果 placeholderTrack 有自定义的 title、cover 和 des（不是默认值），使用这些值
        final customTitle = (placeholderTrack.title.isNotEmpty && placeholderTrack.title != 'Querying video info...') ? placeholderTrack.title : null;
        final customCover = placeholderTrack.icon.isNotEmpty ? placeholderTrack.icon : null;
        final customDes = placeholderTrack.des;

        // 成功开始下载后，从处理集合中移除（processSingleTrack 会创建新的 track 并替换 placeholderTrack）
        await processSingleTrack(
          videoInfo,
          selectedFormat,
          setting.downloadPath,
          placeholderTrack.id,
          type,
          selectedLanguage,
          customTitle: customTitle,
          customCover: customCover,
          customDes: customDes,
        );
        // processSingleTrack 成功后，新的 track 已经创建，旧的 placeholderTrack 已被移除，可以从处理集合中移除
        _processingVideoIds.remove(videoId);
      } catch (downloadError) {
        // 创建失败的任务
        // 使用选中的语言，如果没有则使用占位符任务的语言
        final failedLanguage = selectedLanguage.isNotEmpty ? selectedLanguage : placeholderTrack.language;
        final failedTrack = SingleTrack(
          placeholderTrack.id,
          videoInfo.thumbnail ?? '',
          '',
          videoInfo.title ?? 'Unknown',
          '0 B',
          0,
          type,
          prefs: _prefs,
          videoId: videoId,
          language: failedLanguage.isNotEmpty ? failedLanguage : placeholderTrack.language,
          des: placeholderTrack.des,
        );
        failedTrack.downloadStatus = DownloadStatus.failed;
        failedTrack.error = downloadError.toString();
        addVideo(failedTrack);
        videos.add(failedTrack);
        _videoIdToTrack[videoId] = failedTrack;
        _processingVideoIds.remove(videoId);
        _failureEventController.add(DownloadFailureEvent(
          track: failedTrack,
          error: downloadError.toString(),
        ));
        notifyListeners();
      }
    } catch (e) {
      // 只有在占位符仍然存在时才设置错误状态
      if (videos.contains(placeholderTrack) && placeholderTrack.downloadStatus != DownloadStatus.canceled) {
        placeholderTrack.downloadStatus = DownloadStatus.failed;
        placeholderTrack.error = 'Error fetching video info: ${e.toString()}';
        _failureEventController.add(DownloadFailureEvent(
          track: placeholderTrack,
          error: 'Error fetching video info: ${e.toString()}',
        ));
        notifyListeners();
      }
      // 无论什么情况，都要从处理集合中移除
      _processingVideoIds.remove(videoId);
    }
  }

  /// 获取视频信息（从缓存或重新获取）
  Future<VideoInfo?> getVideoInfo(String videoId) async {
    // 先检查缓存
    if (_videoInfoCache.containsKey(videoId)) {
      return _videoInfoCache[videoId];
    }

    // 重新获取
    try {
      final videoUrl = 'https://www.youtube.com/watch?v=$videoId';
      final videoInfo = await _ytDlp.extractInfo(videoUrl);
      _videoInfoCache[videoId] = videoInfo;
      return videoInfo;
    } catch (e) {
      debugPrint('Error fetching video info for $videoId: $e');
      return null;
    }
  }

  /// 触发自动导出
  Future<void> _triggerAutoExport(SingleTrack track) async {
    // 首先检查是否启用了自动导出
    if (!_autoExportEnabled) {
      return;
    }

    try {
      // 检查文件是否存在
      final filePath = await track.getAbsolutePath();
      final file = File(filePath);
      if (!await file.exists()) {
        return;
      }

      // 检查是否已经导出过
      final existingTask = _audioExportManager.getTask(track.id);
      if (existingTask != null && existingTask.status == ExportStatus.completed) {
        return;
      }

      // 检查 FFmpeg 是否可用（提前检查，避免设置导出状态后才发现不可用）
      final ffmpegProcessor = FFmpegPostProcessor();
      if (!ffmpegProcessor.available && !ffmpegProcessor.probeAvailable) {
        // FFmpeg 不可用时，不设置导出状态，保持成功状态
        return;
      }

      // 设置状态为导出中
      track.downloadStatus = DownloadStatus.exporting;
      notifyListeners();

      // 开始导出
      await _audioExportManager.exportAudio(track);

      // 设置导出任务状态监听（如果还没有设置）
      // 注意：_setupExportStatusSync 已经设置了全局监听，这里确保当前任务也有监听
      if (!_exportTaskListeners.containsKey(track.id)) {
        _setupTaskStatusListener(this, track.id, track);
      }
    } catch (e) {
      // 导出失败不影响下载成功状态
      track.downloadStatus = DownloadStatus.success;
      // 如果错误是 FFmpeg 未找到，给出更友好的提示
      final errorStr = e.toString();
      if (errorStr.contains('ffmpeg not found') || errorStr.contains('ffprobe not found')) {
        track.error = 'Auto export skipped: FFmpeg not installed';
      } else {
        track.error = 'Auto export failed: $e';
      }
      notifyListeners();
    }
  }

  /// 手动触发导出（用于用户主动导出）
  Future<void> exportTrack(SingleTrack track, {String? formatMapping}) async {
    if (track.downloadStatus != DownloadStatus.success) {
      return;
    }

    try {
      // 设置状态为导出中
      track.downloadStatus = DownloadStatus.exporting;
      notifyListeners();

      // 开始导出
      await _audioExportManager.exportAudio(track, formatMapping: formatMapping);

      // 设置导出任务状态监听（如果还没有设置）
      // 注意：_setupExportStatusSync 已经设置了全局监听，这里确保当前任务也有监听
      if (!_exportTaskListeners.containsKey(track.id)) {
        _setupTaskStatusListener(this, track.id, track);
      }
    } catch (e) {
      // 导出失败不影响下载成功状态
      track.downloadStatus = DownloadStatus.success;
      track.error = 'Export failed: $e';
      notifyListeners();
    }
  }

  /// Convert absolute path to relative path (relative to Documents directory)
  /// Returns null if path is not under Documents directory (use absolute path)
  static Future<String?> _getRelativePath(String absolutePath) async {
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      final normalizedAbsolute = path.normalize(absolutePath);
      final normalizedDocuments = path.normalize(documentsDir.path);

      // Check if path is under Documents directory
      if (normalizedAbsolute.startsWith(normalizedDocuments)) {
        // Calculate relative path
        final relativePath = path.relative(normalizedAbsolute, from: normalizedDocuments);
        // Use forward slash as separator for cross-platform compatibility
        return relativePath.replaceAll('\\', '/');
      }

      // Not under Documents directory, return null to let caller save full absolute path
      return null;
    } catch (e) {
      // Return null on error to let caller save full absolute path
      return null;
    }
  }

  /// 更新 SingleTrack 的导出音频信息（静态方法，可在静态上下文中调用）
  static Future<void> _updateTrackExportedAudioInfo(SingleTrack track, AudioExportTask exportTask) async {
    try {
      // 将绝对路径转换为相对路径
      final absolutePath = exportTask.outputFilePath;
      final relativePath = await _getRelativePath(absolutePath);
      final pathToSave = relativePath ?? path.basename(absolutePath);

      // 计算总大小（如果有分段，计算所有分段的总大小；否则使用单个文件大小）
      int? totalSize;
      if (exportTask.segments.isNotEmpty) {
        totalSize = 0;
        for (final segment in exportTask.segments) {
          final segmentFile = File(segment.filePath);
          if (await segmentFile.exists()) {
            totalSize = (totalSize ?? 0) + await segmentFile.length();
          }
        }
      } else {
        // 没有分段，使用输出文件大小
        final outputFile = File(absolutePath);
        if (await outputFile.exists()) {
          totalSize = await outputFile.length();
        }
      }

      // 批量更新导出音频信息
      track.updateExportedAudioInfo(
        path: pathToSave,
        size: totalSize,
        format: exportTask.targetFormat,
        segments: exportTask.segments.isNotEmpty ? exportTask.segments : null,
        duration: exportTask.totalDuration > 0 ? exportTask.totalDuration : null,
      );
    } catch (e) {
      debugPrint('Error updating exported audio info for track ${track.id}: $e');
    }
  }

}
