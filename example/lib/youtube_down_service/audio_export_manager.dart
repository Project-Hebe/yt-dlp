import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'video_post_processor.dart';
import 'youtube_download_manager.dart';
import 'task_entity/single_track_entity.dart';
import 'preferences_service.dart';

/// 音频分片信息
class AudioSegment {
  final int index;
  final String filePath;
  final double startTime; // 起始时间（秒）
  final double endTime; // 结束时间（秒）
  final double duration; // 时长（秒）

  AudioSegment({
    required this.index,
    required this.filePath,
    required this.startTime,
    required this.endTime,
    required this.duration,
  });

  Map<String, dynamic> toJson() => {
        'index': index,
        'filePath': filePath,
        'startTime': startTime,
        'endTime': endTime,
        'duration': duration,
      };

  factory AudioSegment.fromJson(Map<String, dynamic> json) => AudioSegment(
        index: json['index'] as int,
        filePath: json['filePath'] as String,
        startTime: (json['startTime'] as num).toDouble(),
        endTime: (json['endTime'] as num).toDouble(),
        duration: (json['duration'] as num).toDouble(),
      );
}

/// 音频导出任务信息
class AudioExportTask {
  final int trackId;
  final String originalFilePath;
  final String outputFilePath;
  final String targetFormat; // 目标格式：mp3, aac, m4a, opus, flac, wav 等
  double totalDuration;
  final List<AudioSegment> segments;
  ExportStatus status;
  String? error;
  double progress;

  AudioExportTask({
    required this.trackId,
    required this.originalFilePath,
    required this.outputFilePath,
    required this.targetFormat,
    this.totalDuration = 0.0,
    List<AudioSegment>? segments,
    this.status = ExportStatus.pending,
    this.error,
    this.progress = 0.0,
  }) : segments = segments ?? [];

  Map<String, dynamic> toJson() => {
        'trackId': trackId,
        'originalFilePath': originalFilePath,
        'outputFilePath': outputFilePath,
        'targetFormat': targetFormat,
        'totalDuration': totalDuration,
        'segments': segments.map((s) => s.toJson()).toList(),
        'status': status.toString(),
        'error': error,
        'progress': progress,
      };

  factory AudioExportTask.fromJson(Map<String, dynamic> json) => AudioExportTask(
        trackId: json['trackId'] as int,
        originalFilePath: json['originalFilePath'] as String,
        outputFilePath: json['outputFilePath'] as String? ?? json['mp3FilePath'] as String, // 向后兼容
        targetFormat: json['targetFormat'] as String? ?? 'mp3', // 向后兼容
        totalDuration: (json['totalDuration'] as num).toDouble(),
        segments: (json['segments'] as List?)?.map((s) => AudioSegment.fromJson(s as Map<String, dynamic>)).toList() ?? [],
        status: _parseStatus(json['status'] as String?),
        error: json['error'] as String?,
        progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      );

  static ExportStatus _parseStatus(String? statusStr) {
    if (statusStr == null) return ExportStatus.pending;
    switch (statusStr) {
      case 'ExportStatus.processing':
        return ExportStatus.processing;
      case 'ExportStatus.completed':
        return ExportStatus.completed;
      case 'ExportStatus.failed':
        return ExportStatus.failed;
      default:
        return ExportStatus.pending;
    }
  }
}

/// 导出状态
enum ExportStatus {
  pending, // 等待中
  processing, // 处理中
  completed, // 已完成
  failed, // 失败
}

/// 格式映射解析器
/// 解析格式映射规则，如 'aac>m4a/mov>mp4/mkv' 或 'best'
class FormatMappingResolver {
  /// 解析格式映射规则
  /// @param source 源格式（如 'aac', 'mov', 'mp4'）
  /// @param mapping 映射规则字符串，格式：'A>B/C>D/E' 或 'best'
  ///                例如：'aac>m4a/mov>mp4/mkv' 表示：
  ///                - aac 格式转换为 m4a
  ///                - mov 格式转换为 mp4
  ///                - 其他格式转换为 mkv
  /// @returns (targetFormat, errorMessage) 如果找不到映射，返回 (null, errorMessage)
  static (String?, String?) resolveMapping(String source, String mapping) {
    if (mapping.toLowerCase() == 'best') {
      return ('best', null);
    }

    final pairs = mapping.toLowerCase().split('/');
    for (final pair in pairs) {
      final kv = pair.split('>');
      if (kv.length == 1) {
        // 没有 '>'，表示这是默认格式
        final target = kv[0].trim();
        if (target == source.toLowerCase()) {
          return (target, 'already is in target format $source');
        }
        return (target, null);
      } else if (kv[0].trim() == source.toLowerCase()) {
        // 找到匹配的源格式
        final target = kv[1].trim();
        if (target == source.toLowerCase()) {
          return (target, 'already is in target format $source');
        }
        return (target, null);
      }
    }

    return (null, 'could not find a mapping for $source');
  }
}

/// 音频导出管理器
/// 负责处理下载完成的音频/视频，转换为指定格式，并在需要时进行分片切割
/// 支持多种音频格式：mp3, aac, m4a, opus, vorbis, flac, alac, wav
class AudioExportManager extends ChangeNotifier {
  static final AudioExportManager _instance = AudioExportManager._internal();
  static AudioExportManager get instance => _instance;
  AudioExportManager._internal();

  final SharedPreferences _prefs = PreferencesService().getPrex();
  final Map<int, AudioExportTask> _exportTasks = {};
  final Map<int, StreamController<AudioExportTask>> _taskControllers = {};

  // 配置参数
  /// 最大音频文件时长（秒），超过此时长将进行分片
  double maxSegmentDuration = 600.0; // 默认 10 分钟

  /// 分片重叠时长（秒），用于避免切割时丢失内容
  double segmentOverlap = 2.0; // 默认 2 秒

  /// 音频比特率（kbps），如果设置，将使用固定比特率
  /// 如果为 null，将使用质量值（0-10，0=best, 10=worst）
  int? audioBitrate = 192;

  /// 音频质量值（0-10），仅在 audioBitrate 为 null 时使用
  /// 0 = 最佳质量，10 = 最差质量
  double audioQuality = 5.0;

  /// 目标音频格式映射规则
  /// 支持格式：
  /// - 'best': 自动选择最佳格式（优先无损）
  /// - 'mp3', 'aac', 'm4a', 'opus', 'vorbis', 'flac', 'alac', 'wav': 指定格式
  /// - 'aac>m4a/mov>mp4/mkv': 格式映射规则
  ///   例如：'aac>m4a/mov>mp4/mkv' 表示：
  ///   - aac 格式转换为 m4a
  ///   - mov 格式转换为 mp4
  ///   - 其他格式转换为 mkv
  String targetAudioFormat = 'mp3';

  /// 是否不覆盖已存在的文件
  bool noPostOverwrites = false;

  /// 是否保留原始文件的修改时间
  bool preserveFileTime = true;

  /// 是否启用分片功能（某些格式可能不支持分片）
  /// Currently disabled - segmentation feature is not used
  bool enableSegmentation = false;

  /// 最大文件大小限制（字节），如果设置，导出后的文件将不超过此大小
  /// 默认 20MB (20 * 1024 * 1024 = 20971520 字节)
  /// 如果为 null，则不限制文件大小
  int? maxFileSizeBytes = 10 * 1024 * 1024; // 20MB

  /// 最小比特率（kbps），在压缩时不会低于此值
  /// 默认 48 kbps，这是保证基本可听质量的最低值
  int minBitrateKbps = 48;

  List<AudioExportTask> get exportTasks => _exportTasks.values.toList();

  AudioExportTask? getTask(int trackId) => _exportTasks[trackId];

  Stream<AudioExportTask>? watchTask(int trackId) {
    _taskControllers[trackId] ??= StreamController<AudioExportTask>.broadcast();
    return _taskControllers[trackId]!.stream;
  }

  /// 初始化，从 SharedPreferences 加载已保存的任务
  Future<void> initialize() async {
    try {
      // 尝试加载新格式的任务
      final tasksJson = _prefs.getString('audio_export_tasks');
      if (tasksJson != null) {
        final tasksList = json.decode(tasksJson) as List;
        for (final taskJson in tasksList) {
          final task = AudioExportTask.fromJson(taskJson as Map<String, dynamic>);
          _exportTasks[task.trackId] = task;
        }
        notifyListeners();
        return;
      }

      // 向后兼容：尝试加载旧的 MP3 任务
      final oldTasksJson = _prefs.getString('mp3_export_tasks');
      if (oldTasksJson != null) {
        final tasksList = json.decode(oldTasksJson) as List;
        for (final taskJson in tasksList) {
          final task = AudioExportTask.fromJson(taskJson as Map<String, dynamic>);
          _exportTasks[task.trackId] = task;
        }
        // 迁移到新格式
        await _saveTasks();
        await _prefs.remove('mp3_export_tasks');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading audio export tasks: $e');
    }
  }

  /// 保存任务到 SharedPreferences
  Future<void> _saveTasks() async {
    try {
      final tasksList = _exportTasks.values.map((t) => t.toJson()).toList();
      final tasksJson = json.encode(tasksList);
      await _prefs.setString('audio_export_tasks', tasksJson);
    } catch (e) {
      debugPrint('Error saving audio export tasks: $e');
    }
  }

  /// 处理下载完成的视频/音频，转换为指定格式
  /// @param track 下载完成的音视频轨道
  /// @param formatMapping 可选的格式映射规则，如果提供则覆盖默认的 targetAudioFormat
  Future<void> exportAudio(SingleTrack track, {String? formatMapping}) async {
    // 允许在 success 或 exporting 状态下导出
    if (track.downloadStatus != DownloadStatus.success && track.downloadStatus != DownloadStatus.exporting) {
      debugPrint('Track ${track.id} is not in a valid state for export: ${track.downloadStatus}');
      return;
    }
    final filePath = await track.getAbsolutePath();
    final file = File(filePath);
    if (!await file.exists()) {
      debugPrint('File does not exist: ${track.path}');
      return;
    }

    // 检查是否已经处理过
    if (_exportTasks.containsKey(track.id)) {
      final existingTask = _exportTasks[track.id]!;
      if (existingTask.status == ExportStatus.completed) {
        debugPrint('Track ${track.id} already exported to ${existingTask.targetFormat}');
        return;
      }
    }

    // 确定目标格式
    final sourceExt = path.extension(track.path).substring(1).toLowerCase();
    final mapping = formatMapping ?? targetAudioFormat;
    final (targetFormat, errorMsg) = FormatMappingResolver.resolveMapping(sourceExt, mapping);

    if (targetFormat == null) {
      debugPrint('Cannot export track ${track.id}: $errorMsg');
      return;
    }

    // 根据目标格式确定输出文件扩展名
    final outputExt = _getOutputExtension(file.path, targetFormat);
    // 使用 videoId 作为输出文件名，避免编码问题和特殊字符
    final dir = path.dirname(file.path);
    // 处理文件名冲突（如果文件已存在，添加数字后缀）
    String outputPath = path.join(dir, '${track.videoId}.$outputExt');
    outputPath = await _getValidPath(outputPath);
    final task = AudioExportTask(
      trackId: track.id,
      originalFilePath: file.path,
      outputFilePath: outputPath,
      targetFormat: targetFormat,
      totalDuration: 0.0,
    );

    _exportTasks[track.id] = task;
    _saveTasks();
    notifyListeners();
    _notifyTaskUpdate(track.id, task);

    // 开始处理
    _processExport(task);
  }

  /// 导出为 MP3 格式（便捷方法）
  Future<void> exportToMP3(SingleTrack track) async {
    await exportAudio(track, formatMapping: 'mp3');
  }

  /// 获取输出文件扩展名
  String _getOutputExtension(String originalPath, String targetFormat) {
    if (targetFormat == 'best') {
      // 如果源文件已经是音频格式，保持原格式
      final sourceExt = path.extension(originalPath).substring(1).toLowerCase();
      final commonAudioExts = ['mp3', 'm4a', 'ogg', 'opus', 'wav', 'flac', 'wma', 'aac'];
      if (commonAudioExts.contains(sourceExt)) {
        return sourceExt;
      }
      // 否则默认使用 mp3
      return 'mp3';
    }

    // 根据目标格式返回扩展名
    final formatToExt = {
      'mp3': 'mp3',
      'aac': 'm4a',
      'm4a': 'm4a',
      'opus': 'opus',
      'vorbis': 'ogg',
      'flac': 'flac',
      'alac': 'm4a',
      'wav': 'wav',
    };
    return formatToExt[targetFormat] ?? 'mp3';
  }

  /// 获取有效的文件路径（处理文件名冲突）
  Future<String> _getValidPath(String strPath) async {
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

  /// 处理导出任务
  Future<void> _processExport(AudioExportTask task) async {
    try {
      task.status = ExportStatus.processing;
      task.progress = 0.0;
      notifyListeners();
      _notifyTaskUpdate(task.trackId, task);

      // 步骤 1: 先获取原始音频时长，用于计算合适的比特率
      double estimatedDuration = 0.0;
      try {
        estimatedDuration = await _getAudioDuration(task.originalFilePath);
      } catch (e) {
        debugPrint('Warning: Could not get duration from original file, will use default bitrate: $e');
      }

      // 如果启用了文件大小限制，根据时长动态调整比特率
      int? originalBitrate = audioBitrate;
      if (maxFileSizeBytes != null && estimatedDuration > 0) {
        final calculatedBitrate = _calculateBitrateForSizeLimit(estimatedDuration, maxFileSizeBytes!);
        if (calculatedBitrate != null) {
          debugPrint('File size limit enabled: ${maxFileSizeBytes! / (1024 * 1024)}MB, duration: ${estimatedDuration}s, calculated bitrate: ${calculatedBitrate}kbps');
          audioBitrate = calculatedBitrate;
        }
      }

      // 步骤 2: 提取音频并转换为目标格式
      await _extractAudioToFormat(task);

      // 恢复原始比特率设置
      audioBitrate = originalBitrate;

      task.progress = 0.5;
      notifyListeners();
      _notifyTaskUpdate(task.trackId, task);

      // 步骤 3: 获取音频时长
      final duration = await _getAudioDuration(task.outputFilePath);
      task.totalDuration = duration;

      // 步骤 4: 检查文件大小，如果超过限制，重新压缩
      if (maxFileSizeBytes != null) {
        final outputFile = File(task.outputFilePath);
        if (await outputFile.exists()) {
          final fileSize = await outputFile.length();
          if (fileSize > maxFileSizeBytes!) {
            debugPrint('Output file size (${fileSize / (1024 * 1024)}MB) exceeds limit (${maxFileSizeBytes! / (1024 * 1024)}MB), re-compressing...');
            await _recompressToSizeLimit(task, duration);
            
            // 压缩后验证文件存在
            final finalFile = File(task.outputFilePath);
            if (!await finalFile.exists()) {
              throw Exception('Compressed file does not exist after re-compression: ${task.outputFilePath}');
            }
            final finalSize = await finalFile.length();
            if (finalSize == 0) {
              throw Exception('Compressed file is empty: ${task.outputFilePath}');
            }
            debugPrint('Final file after compression: ${path.basename(task.outputFilePath)}, size: ${finalSize / (1024 * 1024)}MB');
          }
        } else {
          throw Exception('Output file does not exist before compression check: ${task.outputFilePath}');
        }
      }

      // 步骤 5: 如果时长超过限制且启用分片，进行分片切割
      // 注意：某些格式（如 flac, wav）可能不适合分片
      final supportsSegmentation = _supportsSegmentation(task.targetFormat);
      if (enableSegmentation && supportsSegmentation && duration > maxSegmentDuration) {
        debugPrint('Starting audio split for track ${task.trackId}...');
        await _splitAudio(task);
        debugPrint('Audio split completed for track ${task.trackId}, segments: ${task.segments.length}');
      } else {
        // 不需要分片，创建一个完整的分片记录
        task.segments.add(AudioSegment(
          index: 0,
          filePath: task.outputFilePath,
          startTime: 0.0,
          endTime: duration,
          duration: duration,
        ));
      }

      // 确保状态更新（即使分片过程中有异常，也要标记为完成）
      debugPrint('Marking export as completed for track ${task.trackId}...');
      task.status = ExportStatus.completed;
      task.progress = 1.0;
      _saveTasks();
      notifyListeners();
      _notifyTaskUpdate(task.trackId, task);

      debugPrint('Audio export completed for track ${task.trackId} to ${task.targetFormat}');
    } catch (e, stackTrace) {
      debugPrint('Error processing MP3 export: $e');
      debugPrint('Stack trace: $stackTrace');
      task.status = ExportStatus.failed;
      task.error = e.toString();
      _saveTasks();
      notifyListeners();
      _notifyTaskUpdate(task.trackId, task);
    }
  }

  /// 根据文件大小限制和音频时长计算所需的比特率
  /// @param durationSeconds 音频时长（秒）
  /// @param maxSizeBytes 最大文件大小（字节）
  /// @returns 计算出的比特率（kbps），如果计算出的值低于 minBitrateKbps，返回 null（表示无法满足限制）
  int? _calculateBitrateForSizeLimit(double durationSeconds, int maxSizeBytes) {
    if (durationSeconds <= 0 || maxSizeBytes <= 0) {
      return null;
    }

    // 计算公式：bitrate (kbps) = (maxSizeBytes * 8) / (durationSeconds * 1000)
    // 乘以 8 将字节转换为比特，除以 1000 将 bps 转换为 kbps
    // 保留 5% 的安全余量，避免因编码开销导致略微超出
    final calculatedBitrate = ((maxSizeBytes * 8) / (durationSeconds * 1000) * 0.95).floor();

    // 确保不低于最小比特率
    if (calculatedBitrate < minBitrateKbps) {
      debugPrint('Warning: Calculated bitrate ($calculatedBitrate kbps) is below minimum ($minBitrateKbps kbps). File may exceed size limit.');
      return minBitrateKbps;
    }

    return calculatedBitrate;
  }

  /// 重新压缩音频文件以满足大小限制
  /// @param task 导出任务
  /// @param duration 音频时长（秒）
  Future<void> _recompressToSizeLimit(AudioExportTask task, double duration) async {
    if (maxFileSizeBytes == null || duration <= 0) {
      return;
    }

    // 计算所需的比特率
    final targetBitrate = _calculateBitrateForSizeLimit(duration, maxFileSizeBytes!);
    if (targetBitrate == null || targetBitrate < minBitrateKbps) {
      debugPrint('Warning: Cannot compress file to meet size limit. Duration: ${duration}s, limit: ${maxFileSizeBytes! / (1024 * 1024)}MB');
      return;
    }

    debugPrint('Re-compressing audio to ${targetBitrate}kbps to meet size limit...');

    // 保存原始文件路径
    final originalOutputPath = task.outputFilePath;
    // 确保临时文件使用正确的扩展名（.mp3.tmp），这样 FFmpeg 可以识别格式
    final tempOutputPath = '${path.withoutExtension(originalOutputPath)}.compressed${path.extension(originalOutputPath)}';

    try {
      // 备份原始比特率
      final originalBitrate = audioBitrate;

      // 设置新的比特率
      audioBitrate = targetBitrate;

      // 使用 FFmpeg 重新编码
      final processor = FFmpegPostProcessor();
      final codec = _getCodecForFormat(task.targetFormat);
      final opts = <String>[
        '-acodec',
        codec,
        '-b:a',
        '${targetBitrate}k',
      ];

      await processor.runFfmpeg(task.outputFilePath, tempOutputPath, opts);

      // 检查新文件是否存在且有效
      final tempFile = File(tempOutputPath);
      if (await tempFile.exists()) {
        final newSize = await tempFile.length();
        if (newSize > 0 && newSize <= maxFileSizeBytes!) {
          // 验证压缩后的文件确实存在且有效，然后再替换原文件
          final originalFile = File(originalOutputPath);
          
          // 先验证原文件存在（作为备份检查）
          if (await originalFile.exists()) {
            // 删除原文件
            await originalFile.delete();
          }
          
          // 将压缩后的文件重命名为最终路径（保持 .mp3 扩展名）
          await tempFile.rename(originalOutputPath);
          
          // 验证最终文件确实存在
          final finalFile = File(originalOutputPath);
          if (await finalFile.exists()) {
            debugPrint('Re-compression successful: ${newSize / (1024 * 1024)}MB <= ${maxFileSizeBytes! / (1024 * 1024)}MB, file saved as ${path.basename(originalOutputPath)}');
          } else {
            debugPrint('Error: Re-compressed file was not properly renamed to ${originalOutputPath}');
            throw Exception('Failed to rename compressed file');
          }
        } else {
          // 新文件仍然超过限制或大小为0，删除临时文件
          await tempFile.delete();
          if (newSize == 0) {
            debugPrint('Warning: Re-compressed file is empty, keeping original file');
          } else {
            debugPrint('Warning: Re-compressed file still exceeds size limit: ${newSize / (1024 * 1024)}MB');
          }
        }
      } else {
        debugPrint('Error: Re-compressed file was not created at $tempOutputPath');
        throw Exception('Compressed file does not exist');
      }

      // 恢复原始比特率
      audioBitrate = originalBitrate;
    } catch (e) {
      debugPrint('Error during re-compression: $e');
      // 清理临时文件
      try {
        final tempFile = File(tempOutputPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (e2) {
        debugPrint('Error cleaning up temp file: $e2');
      }
      // 压缩失败时，保留原文件（不删除）
      debugPrint('Re-compression failed, keeping original file: $originalOutputPath');
    }
  }

  /// 检查格式是否支持分片
  bool _supportsSegmentation(String format) {
    // 有损压缩格式通常支持分片
    // 无损格式可能需要重新编码，分片可能不太合适
    const supportedFormats = ['mp3', 'aac', 'm4a', 'opus', 'vorbis', 'ogg'];
    return supportedFormats.contains(format.toLowerCase());
  }

  /// 根据格式获取 FFmpeg 编码器
  String _getCodecForFormat(String format) {
    final formatToCodec = {
      'mp3': 'libmp3lame',
      'aac': 'aac',
      'm4a': 'aac',
      'opus': 'libopus',
      'vorbis': 'libvorbis',
      'flac': 'flac',
      'wav': 'pcm_s16le',
    };
    return formatToCodec[format.toLowerCase()] ?? 'libmp3lame';
  }

  /// 提取音频并转换为目标格式
  Future<void> _extractAudioToFormat(AudioExportTask task) async {
    // 检查源文件是否已经是目标格式的音频文件
    final sourceExt = path.extension(task.originalFilePath).substring(1).toLowerCase();
    final commonAudioExts = ['mp3', 'm4a', 'ogg', 'opus', 'wav', 'flac', 'wma', 'aac'];

    // 如果源文件已经是目标格式，可以跳过转换
    if (task.targetFormat == 'best' && commonAudioExts.contains(sourceExt)) {
      debugPrint('Source file is already in a common audio format: $sourceExt');
      // 如果已经是目标格式，直接使用
      final sourceFile = File(task.originalFilePath);
      if (await sourceFile.exists()) {
        // 如果路径不同，复制或重命名
        if (task.originalFilePath != task.outputFilePath) {
          await sourceFile.copy(task.outputFilePath);
        }
        // 保留文件时间戳
        if (preserveFileTime) {
          await _preserveFileTime(task.originalFilePath, task.outputFilePath);
        }
        return;
      }
    }

    // 检查 FFmpeg 是否可用
    final ffmpegProcessor = FFmpegPostProcessor();
    if (!ffmpegProcessor.available && !ffmpegProcessor.probeAvailable) {
      final errorMsg = 'ffprobe and ffmpeg not found. Please install FFmpeg or provide the path using --ffmpeg-location.\n'
          'Installation instructions:\n'
          '  • macOS: brew install ffmpeg\n'
          '  • Linux: sudo apt-get install ffmpeg\n'
          '  • Windows: Download from https://ffmpeg.org/download.html';
      debugPrint('FFmpeg not available: $errorMsg');
      throw PostProcessingError(errorMsg);
    }

    // 确定质量参数
    double? qualityParam;
    if (audioBitrate != null) {
      // 使用固定比特率（如果大于10，表示是比特率值）
      qualityParam = audioBitrate!.toDouble();
    } else {
      // 使用质量值（0-10）
      qualityParam = audioQuality;
    }

    final processor = FFmpegExtractAudioPP(
      preferredcodec: task.targetFormat == 'best' ? 'best' : task.targetFormat,
      preferredquality: qualityParam,
      nopostoverwrites: noPostOverwrites,
    );

    final information = {
      'filepath': task.originalFilePath,
      'ext': sourceExt,
      // 添加文件时间戳信息（如果可用）
      if (preserveFileTime) 'filetime': await _getFileTime(task.originalFilePath),
    };

    final result = await processor.run(information);
    final newFilePath = result['info']['filepath'] as String;

    // 如果生成的文件路径与预期不同，更新任务信息
    if (newFilePath != task.outputFilePath) {
      // 重命名文件到预期路径
      final newFile = File(newFilePath);
      if (await newFile.exists()) {
        await newFile.rename(task.outputFilePath);
      }
    }

    // 保留文件时间戳
    if (preserveFileTime && information.containsKey('filetime')) {
      await _preserveFileTime(task.originalFilePath, task.outputFilePath);
    }

    // 删除临时文件
    final filesToDelete = result['files_to_delete'] as List<String>;
    for (final filePath in filesToDelete) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Error deleting file $filePath: $e');
      }
    }
  }

  /// 获取文件的修改时间（Unix 时间戳）
  Future<int?> _getFileTime(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        final stat = await file.stat();
        return stat.modified.millisecondsSinceEpoch ~/ 1000;
      }
    } catch (e) {
      debugPrint('Error getting file time: $e');
    }
    return null;
  }

  /// 保留原始文件的修改时间到新文件
  Future<void> _preserveFileTime(String sourcePath, String targetPath) async {
    try {
      final sourceFile = File(sourcePath);
      final targetFile = File(targetPath);

      if (await sourceFile.exists() && await targetFile.exists()) {
        final sourceStat = await sourceFile.stat();
        // 注意：Dart 的 File 没有直接的 utime 方法
        // 在移动平台上可能需要使用平台通道
        // 这里先记录，实际实现可能需要平台特定代码
        debugPrint('Preserving file time: ${sourceStat.modified}');
        // TODO: 实现平台特定的文件时间戳设置
      }
    } catch (e) {
      debugPrint('Error preserving file time: $e');
    }
  }

  /// 获取音频文件时长
  Future<double> _getAudioDuration(String filePath) async {
    try {
      final processor = FFmpegPostProcessor();
      final metadata = await processor.getMetadataObject(filePath);
      final format = metadata['format'] as Map<String, dynamic>?;
      final durationStr = format?['duration']?.toString();
      if (durationStr != null) {
        return double.parse(durationStr);
      }
      throw Exception('Unable to get audio duration');
    } catch (e) {
      debugPrint('Error getting audio duration: $e');
      rethrow;
    }
  }

  /// 分片切割音频
  Future<void> _splitAudio(AudioExportTask task) async {
    final segments = <AudioSegment>[];
    final processor = FFmpegPostProcessor();
    final baseDir = path.dirname(task.outputFilePath);
    final baseName = path.basenameWithoutExtension(task.outputFilePath);
    final totalDuration = task.totalDuration;

    int segmentIndex = 0;
    double currentStart = 0.0;

    debugPrint('Splitting audio (${task.targetFormat}): total duration = ${totalDuration}s, max segment = ${maxSegmentDuration}s');

    while (currentStart < totalDuration) {
      // 计算当前分片的结束时间
      double segmentEnd = (currentStart + maxSegmentDuration).clamp(0.0, totalDuration);
      double segmentDuration = segmentEnd - currentStart;

      // 如果已经到达或超过末尾，退出循环（避免浮点数精度问题）
      if (currentStart >= totalDuration || segmentDuration <= 0) {
        break;
      }

      // 如果剩余时长太短（小于1秒），合并到上一个分片
      if (segmentDuration < 1.0 && segments.isNotEmpty) {
        final lastSegment = segments.last;
        segments.removeLast();
        segmentIndex = lastSegment.index;
        segmentEnd = totalDuration;
        segmentDuration = segmentEnd - lastSegment.startTime;
        currentStart = lastSegment.startTime;

        // 需要重新生成最后一个分片
        final outputExt = _getOutputExtension(task.outputFilePath, task.targetFormat);
        final segmentFileName = '${baseName}_part${segmentIndex.toString().padLeft(3, '0')}.$outputExt';
        final segmentFilePath = path.join(baseDir, segmentFileName);

        // 删除旧的分片文件
        try {
          final oldFile = File(lastSegment.filePath);
          if (await oldFile.exists()) {
            await oldFile.delete();
          }
        } catch (e) {
          debugPrint('Error deleting old segment file: $e');
        }

        // 重新创建合并后的分片
        try {
          final opts = <String>[
            '-ss',
            currentStart.toStringAsFixed(3),
            '-t',
            segmentDuration.toStringAsFixed(3),
            '-acodec',
            'copy',
          ];
          await processor.runFfmpeg(task.outputFilePath, segmentFilePath, opts);

          final segmentFile = File(segmentFilePath);
          if (await segmentFile.exists()) {
            final segment = AudioSegment(
              index: segmentIndex,
              filePath: segmentFilePath,
              startTime: currentStart,
              endTime: segmentEnd,
              duration: segmentDuration,
            );
            segments.add(segment);
            debugPrint('Merged last segment: ${currentStart}s - ${segmentEnd}s');
          }
        } catch (e) {
          debugPrint('Error merging last segment: $e');
        }

        break; // 退出循环
      }

      // 生成分片文件路径（根据目标格式确定扩展名）
      final outputExt = _getOutputExtension(task.outputFilePath, task.targetFormat);
      final segmentFileName = '${baseName}_part${segmentIndex.toString().padLeft(3, '0')}.$outputExt';
      final segmentFilePath = path.join(baseDir, segmentFileName);

      try {
        // 使用 FFmpeg 切割音频
        final opts = <String>[
          '-ss', currentStart.toStringAsFixed(3),
          '-t', segmentDuration.toStringAsFixed(3),
          '-acodec', 'copy', // 使用流复制，不重新编码
        ];

        await processor.runFfmpeg(task.outputFilePath, segmentFilePath, opts);

        // 验证文件是否存在
        final segmentFile = File(segmentFilePath);
        if (await segmentFile.exists()) {
          // 创建分片记录
          final segment = AudioSegment(
            index: segmentIndex,
            filePath: segmentFilePath,
            startTime: currentStart,
            endTime: segmentEnd,
            duration: segmentDuration,
          );
          segments.add(segment);

          debugPrint('Created segment $segmentIndex: ${currentStart}s - ${segmentEnd}s (${segmentDuration}s)');

          // 更新进度
          task.progress = 0.5 + (segmentEnd / totalDuration) * 0.4;
          notifyListeners();
          _notifyTaskUpdate(task.trackId, task);
        } else {
          throw Exception('Failed to create segment file: $segmentFilePath');
        }
      } catch (e) {
        debugPrint('Error creating segment $segmentIndex: $e');
        // 如果切割失败，尝试使用重新编码的方式
        try {
          // 根据目标格式选择编码器
          final codec = _getCodecForFormat(task.targetFormat);
          final opts = <String>[
            '-ss',
            currentStart.toStringAsFixed(3),
            '-t',
            segmentDuration.toStringAsFixed(3),
            '-acodec',
            codec,
          ];
          if (audioBitrate != null) {
            opts.addAll(['-b:a', '${audioBitrate}k']);
          } else {
            opts.addAll(['-q:a', audioQuality.toStringAsFixed(2)]);
          }
          await processor.runFfmpeg(task.outputFilePath, segmentFilePath, opts);

          final segmentFile = File(segmentFilePath);
          if (await segmentFile.exists()) {
            final segment = AudioSegment(
              index: segmentIndex,
              filePath: segmentFilePath,
              startTime: currentStart,
              endTime: segmentEnd,
              duration: segmentDuration,
            );
            segments.add(segment);

            debugPrint('Created segment $segmentIndex (re-encoded): ${currentStart}s - ${segmentEnd}s');
          }
        } catch (e2) {
          debugPrint('Error creating segment with re-encoding: $e2');
          throw Exception('Failed to create segment $segmentIndex: $e2');
        }
      }

      // 移动到下一个分片的起始位置
      // 注意：重叠只在需要时使用，这里直接移动到下一个分片的开始
      currentStart = segmentEnd;
      segmentIndex++;

      // 如果已经到达末尾，退出循环（使用小的容差值避免浮点数精度问题）
      if (segmentEnd >= totalDuration - 0.001) {
        break;
      }
    }

    // 将分片列表添加到任务中
    task.segments.clear();
    task.segments.addAll(segments);

    debugPrint('Audio split completed: ${segments.length} segments created for ${task.targetFormat}');
    debugPrint('Final currentStart: $currentStart, totalDuration: $totalDuration');
  }

  /// 通知任务更新
  void _notifyTaskUpdate(int trackId, AudioExportTask task) {
    final controller = _taskControllers[trackId];
    if (controller != null && !controller.isClosed) {
      controller.add(task);
    }
  }

  /// 删除导出任务
  Future<void> removeTask(int trackId) async {
    _exportTasks.remove(trackId);
    final controller = _taskControllers[trackId];
    if (controller != null) {
      await controller.close();
      _taskControllers.remove(trackId);
    }
    await _saveTasks();
    notifyListeners();
  }

  /// 删除任务的所有分片文件
  Future<void> deleteTaskSegments(int trackId) async {
    final task = _exportTasks[trackId];
    if (task == null) return;

    // 删除所有分片文件
    for (final segment in task.segments) {
      try {
        final file = File(segment.filePath);
        if (await file.exists()) {
          await file.delete();
          debugPrint('Deleted segment file: ${segment.filePath}');
        }
      } catch (e) {
        debugPrint('Error deleting segment file ${segment.filePath}: $e');
      }
    }

    // 删除主音频文件（如果存在且不是分片）
    if (task.segments.isEmpty || !task.segments.any((s) => s.filePath == task.outputFilePath)) {
      try {
        final file = File(task.outputFilePath);
        if (await file.exists()) {
          await file.delete();
          debugPrint('Deleted audio file: ${task.outputFilePath}');
        }
      } catch (e) {
        debugPrint('Error deleting audio file ${task.outputFilePath}: $e');
      }
    }
  }

  /// 获取分片信息（JSON 格式）
  String getSegmentsJson(int trackId) {
    final task = _exportTasks[trackId];
    if (task == null) return '[]';
    return json.encode(task.segments.map((s) => s.toJson()).toList());
  }

  /// 从 JSON 恢复分片信息
  void restoreSegmentsFromJson(int trackId, String jsonStr) {
    try {
      final task = _exportTasks[trackId];
      if (task == null) return;

      final segmentsList = json.decode(jsonStr) as List;
      task.segments.clear();
      task.segments.addAll(
        segmentsList.map((s) => AudioSegment.fromJson(s as Map<String, dynamic>)).toList(),
      );
      _saveTasks();
      notifyListeners();
    } catch (e) {
      debugPrint('Error restoring segments from JSON: $e');
    }
  }

  /// 批量导出多个任务
  Future<void> exportMultiple(List<SingleTrack> tracks, {String? formatMapping}) async {
    for (final track in tracks) {
      await exportAudio(track, formatMapping: formatMapping);
    }
  }

  /// 批量导出为 MP3（便捷方法）
  Future<void> exportMultipleToMP3(List<SingleTrack> tracks) async {
    await exportMultiple(tracks, formatMapping: 'mp3');
  }

  /// 取消正在处理的任务
  Future<void> cancelTask(int trackId) async {
    final task = _exportTasks[trackId];
    if (task == null) return;

    if (task.status == ExportStatus.processing) {
      task.status = ExportStatus.failed;
      task.error = 'Cancelled by user';
      await _saveTasks();
      notifyListeners();
      _notifyTaskUpdate(trackId, task);
    }
  }

  /// 重新处理失败的任务
  Future<void> retryTask(int trackId) async {
    final task = _exportTasks[trackId];
    if (task == null) return;

    if (task.status == ExportStatus.failed) {
      task.status = ExportStatus.pending;
      task.error = null;
      task.progress = 0.0;
      await _saveTasks();
      notifyListeners();
      _notifyTaskUpdate(trackId, task);

      // 重新处理
      _processExport(task);
    }
  }

  /// 获取所有分片文件路径
  List<String> getAllSegmentPaths(int trackId) {
    final task = _exportTasks[trackId];
    if (task == null) return [];
    return task.segments.map((s) => s.filePath).toList();
  }

  /// 检查分片文件是否存在
  Future<bool> verifySegmentsExist(int trackId) async {
    final task = _exportTasks[trackId];
    if (task == null) return false;

    for (final segment in task.segments) {
      final file = File(segment.filePath);
      if (!await file.exists()) {
        return false;
      }
    }
    return true;
  }

  /// 获取任务统计信息
  Map<String, dynamic> getTaskStatistics(int trackId) {
    final task = _exportTasks[trackId];
    if (task == null) {
      return {
        'exists': false,
      };
    }

    return {
      'exists': true,
      'trackId': task.trackId,
      'status': task.status.toString(),
      'totalDuration': task.totalDuration,
      'segmentCount': task.segments.length,
      'progress': task.progress,
      'hasError': task.error != null,
      'error': task.error,
    };
  }

  /// 清理所有已完成的任务
  Future<void> cleanupCompletedTasks() async {
    final completedTasks = _exportTasks.values.where((task) => task.status == ExportStatus.completed).map((task) => task.trackId).toList();

    for (final trackId in completedTasks) {
      await removeTask(trackId);
    }
  }

  /// 清理所有失败的任务
  Future<void> cleanupFailedTasks() async {
    final failedTasks = _exportTasks.values.where((task) => task.status == ExportStatus.failed).map((task) => task.trackId).toList();

    for (final trackId in failedTasks) {
      await removeTask(trackId);
    }
  }

  /// 监听下载管理器，自动处理完成的下载
  void startAutoExport(DownloadManagerImpl downloadManager) {
    // 监听下载管理器的变化
    downloadManager.addListener(() {
      // 检查是否启用了自动导出
      if (!downloadManager.autoExportEnabled) {
        return;
      }
      // 检查是否有新完成的下载
      for (final track in downloadManager.videos) {
        if (track.downloadStatus == DownloadStatus.success) {
          // 检查是否已经导出过
          if (!_exportTasks.containsKey(track.id) || _exportTasks[track.id]!.status != ExportStatus.completed) {
            // 自动开始导出
            exportToMP3(track);
          }
        }
      }
    });
  }

  @override
  void dispose() {
    // 关闭所有 StreamController
    for (final controller in _taskControllers.values) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
    _taskControllers.clear();
    super.dispose();
  }
}

// ============================================================================
// 向后兼容的 MP3 导出管理器（基于 AudioExportManager）
// ============================================================================

/// MP3 导出管理器（向后兼容）
/// 这是一个便捷包装类，专门用于 MP3 导出
/// 内部使用 AudioExportManager，但提供简化的 MP3 专用接口
class MP3ExportManager extends ChangeNotifier {
  static final MP3ExportManager _instance = MP3ExportManager._internal();
  static MP3ExportManager get instance => _instance;
  MP3ExportManager._internal() {
    // 初始化底层音频导出管理器
    _audioManager.initialize();
    // 配置为 MP3 专用
    _audioManager.targetAudioFormat = 'mp3';
    // 监听底层管理器的变化
    _audioManager.addListener(() {
      notifyListeners();
    });
  }

  final AudioExportManager _audioManager = AudioExportManager.instance;

  // 代理属性
  double get maxSegmentDuration => _audioManager.maxSegmentDuration;
  set maxSegmentDuration(double value) => _audioManager.maxSegmentDuration = value;

  double get segmentOverlap => _audioManager.segmentOverlap;
  set segmentOverlap(double value) => _audioManager.segmentOverlap = value;

  int? get mp3Bitrate => _audioManager.audioBitrate;
  set mp3Bitrate(int? value) => _audioManager.audioBitrate = value;

  double get audioQuality => _audioManager.audioQuality;
  set audioQuality(double value) => _audioManager.audioQuality = value;

  bool get noPostOverwrites => _audioManager.noPostOverwrites;
  set noPostOverwrites(bool value) => _audioManager.noPostOverwrites = value;

  bool get preserveFileTime => _audioManager.preserveFileTime;
  set preserveFileTime(bool value) => _audioManager.preserveFileTime = value;

  bool get enableSegmentation => _audioManager.enableSegmentation;
  set enableSegmentation(bool value) => _audioManager.enableSegmentation = value;

  // 类型转换辅助方法
  MP3ExportTask? _convertTask(AudioExportTask? task) {
    if (task == null) return null;
    return MP3ExportTask._fromAudioTask(task);
  }

  List<MP3ExportTask> get exportTasks {
    return _audioManager.exportTasks.map((t) => MP3ExportTask._fromAudioTask(t)).toList();
  }

  MP3ExportTask? getTask(int trackId) => _convertTask(_audioManager.getTask(trackId));

  Stream<MP3ExportTask>? watchTask(int trackId) {
    final stream = _audioManager.watchTask(trackId);
    if (stream == null) return null;
    return stream.map((t) => MP3ExportTask._fromAudioTask(t));
  }

  /// 初始化
  Future<void> initialize() async {
    await _audioManager.initialize();
  }

  /// 导出为 MP3
  Future<void> exportToMP3(SingleTrack track) async {
    await _audioManager.exportToMP3(track);
  }

  /// 批量导出为 MP3
  Future<void> exportMultipleToMP3(List<SingleTrack> tracks) async {
    await _audioManager.exportMultipleToMP3(tracks);
  }

  /// 删除任务
  Future<void> removeTask(int trackId) async {
    await _audioManager.removeTask(trackId);
  }

  /// 删除任务的所有分片文件
  Future<void> deleteTaskSegments(int trackId) async {
    await _audioManager.deleteTaskSegments(trackId);
  }

  /// 获取分片信息（JSON 格式）
  String getSegmentsJson(int trackId) {
    return _audioManager.getSegmentsJson(trackId);
  }

  /// 从 JSON 恢复分片信息
  void restoreSegmentsFromJson(int trackId, String jsonStr) {
    _audioManager.restoreSegmentsFromJson(trackId, jsonStr);
  }

  /// 取消任务
  Future<void> cancelTask(int trackId) async {
    await _audioManager.cancelTask(trackId);
  }

  /// 重试任务
  Future<void> retryTask(int trackId) async {
    await _audioManager.retryTask(trackId);
  }

  /// 获取所有分片文件路径
  List<String> getAllSegmentPaths(int trackId) {
    return _audioManager.getAllSegmentPaths(trackId);
  }

  /// 检查分片文件是否存在
  Future<bool> verifySegmentsExist(int trackId) async {
    return await _audioManager.verifySegmentsExist(trackId);
  }

  /// 获取任务统计信息
  Map<String, dynamic> getTaskStatistics(int trackId) {
    return _audioManager.getTaskStatistics(trackId);
  }

  /// 清理所有已完成的任务
  Future<void> cleanupCompletedTasks() async {
    await _audioManager.cleanupCompletedTasks();
  }

  /// 清理所有失败的任务
  Future<void> cleanupFailedTasks() async {
    await _audioManager.cleanupFailedTasks();
  }

  /// 监听下载管理器，自动处理完成的下载
  void startAutoExport(DownloadManagerImpl downloadManager) {
    _audioManager.startAutoExport(downloadManager);
  }
}

/// MP3 导出任务（向后兼容）
/// 这是 AudioExportTask 的包装类，提供 MP3 专用的接口
class MP3ExportTask {
  final AudioExportTask _task;

  MP3ExportTask._fromAudioTask(this._task);

  int get trackId => _task.trackId;
  String get originalFilePath => _task.originalFilePath;
  String get mp3FilePath => _task.outputFilePath;
  double get totalDuration => _task.totalDuration;
  List<MP3Segment> get segments => _task.segments.map((s) => MP3Segment._fromAudioSegment(s)).toList();
  ExportStatus get status => _task.status;
  String? get error => _task.error;
  double get progress => _task.progress;
}

/// MP3 分片（向后兼容）
/// 这是 AudioSegment 的包装类
class MP3Segment {
  final AudioSegment _segment;

  MP3Segment._fromAudioSegment(this._segment);

  int get index => _segment.index;
  String get filePath => _segment.filePath;
  double get startTime => _segment.startTime;
  double get endTime => _segment.endTime;
  double get duration => _segment.duration;

  Map<String, dynamic> toJson() => _segment.toJson();
  factory MP3Segment.fromJson(Map<String, dynamic> json) => MP3Segment._fromAudioSegment(AudioSegment.fromJson(json));
}
