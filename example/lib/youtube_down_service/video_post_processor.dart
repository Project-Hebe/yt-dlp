import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

/// PostProcessingError exception
class PostProcessingError implements Exception {
  final String message;
  PostProcessingError(this.message);

  @override
  String toString() => message;
}

/// FFmpegPostProcessorError exception
class FFmpegPostProcessorError extends PostProcessingError {
  FFmpegPostProcessorError(String message) : super(message);
}

/// PostProcessor base class
abstract class PostProcessor {
  dynamic _downloader;

  PostProcessor([this._downloader]);

  void setDownloader(dynamic downloader) {
    _downloader = downloader;
  }

  String ppKey() {
    final name = runtimeType.toString();
    if (name.endsWith('PP')) {
      final baseName = name.substring(0, name.length - 2);
      if (baseName.toLowerCase().startsWith('ffmpeg')) {
        return baseName.substring(6);
      }
      return baseName;
    }
    return name;
  }

  void toScreen(String text, {bool prefix = true}) {
    if (_downloader != null) {
      final tag = prefix ? '[${ppKey()}] ' : '';
      // Call downloader's toScreen method if available
      try {
        _downloader.toScreen('$tag$text');
      } catch (e) {
        print('$tag$text');
      }
    } else {
      print(text);
    }
  }

  void reportWarning(String text) {
    if (_downloader != null) {
      try {
        _downloader.reportWarning(text);
      } catch (e) {
        print('Warning: $text');
      }
    } else {
      print('Warning: $text');
    }
  }

  void writeDebug(String text) {
    // 使用 Flutter 的 debugPrint 输出到控制台
    debugPrint('[FFmpegPostProcessor] $text');
    if (_downloader != null) {
      try {
        _downloader.writeDebug(text);
      } catch (e) {
        // Debug output can be silent
      }
    }
  }

  dynamic getParam(String name, [dynamic defaultValue]) {
    if (_downloader != null) {
      try {
        return _downloader.params?[name] ?? defaultValue;
      } catch (e) {
        return defaultValue;
      }
    }
    return defaultValue;
  }

  void deleteDownloadedFiles(List<String> filesToDelete) {
    for (final file in filesToDelete) {
      if (file.isNotEmpty) {
        try {
          final f = File(file);
          if (f.existsSync()) {
            f.deleteSync();
          }
        } catch (e) {
          // Ignore deletion errors
        }
      }
    }
  }

  void tryUtime(String filePath, int atime, int mtime, {String errnote = 'Cannot update utime of file'}) {
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        // Note: Dart doesn't have direct utime support, this is a placeholder
        // In a real implementation, you might need platform-specific code
      }
    } catch (e) {
      reportWarning(errnote);
    }
  }

  /// Run the PostProcessor
  /// Returns a tuple: (files_to_delete, updated_info)
  Future<Map<String, dynamic>> run(Map<String, dynamic> information) async {
    return {'files_to_delete': [], 'info': information};
  }
}

/// Extension to output format mapping
const Map<String, String> extToOutFormats = {
  'aac': 'adts',
  'flac': 'flac',
  'm4a': 'ipod',
  'mka': 'matroska',
  'mkv': 'matroska',
  'mpg': 'mpeg',
  'ogv': 'ogg',
  'ts': 'mpegts',
  'wma': 'asf',
  'wmv': 'asf',
  'weba': 'webm',
  'vtt': 'webvtt',
};

/// Audio codec definitions: name -> (ext, encoder, opts)
const Map<String, List<dynamic>> acodecs = {
  'mp3': ['mp3', 'libmp3lame', []],
  'aac': [
    'm4a',
    'aac',
    ['-f', 'adts']
  ],
  'm4a': [
    'm4a',
    'aac',
    ['-bsf:a', 'aac_adtstoasc']
  ],
  'opus': ['opus', 'libopus', []],
  'vorbis': ['ogg', 'libvorbis', []],
  'flac': ['flac', 'flac', []],
  'alac': [
    'm4a',
    null,
    ['-acodec', 'alac']
  ],
  'wav': [
    'wav',
    null,
    ['-f', 'wav']
  ],
};

/// Resolve mapping from source format
String? resolveMapping(String source, String mapping) {
  final pairs = mapping.toLowerCase().split('/');
  for (final pair in pairs) {
    final kv = pair.split('>');
    if (kv.length == 1 || kv[0].trim() == source) {
      final target = kv.last.trim();
      if (target == source) {
        return null; // Already in target format
      }
      return target;
    }
  }
  return null;
}

/// FFmpegPostProcessor base class
/// Uses ffmpeg_kit_flutter_new plugin API exclusively (no system commands)
/// Based on: https://pub.dev/packages/ffmpeg_kit_flutter_new
class FFmpegPostProcessor extends PostProcessor {
  String? _version;
  String? _probeVersion;
  Map<String, dynamic> _features = {};

  static bool? _ffmpegKitAvailable;
  static bool? _ffprobeKitAvailable;

  FFmpegPostProcessor([super.downloader]) {
    _checkFFmpegKitAvailability();
  }

  /// 检查 ffmpeg_kit_flutter_new 是否可用
  /// 基于官方文档: https://pub.dev/packages/ffmpeg_kit_flutter_new
  void _checkFFmpegKitAvailability() {
    if (_ffmpegKitAvailable == null) {
      try {
        // FFmpegKit 总是可用（如果插件已安装）
        _ffmpegKitAvailable = true;
        // 异步获取版本信息
        FFmpegKitConfig.getVersion().then((version) {
          if (version.isNotEmpty) {
            _version = version;
          }
        }).catchError((e) {
          // 如果获取版本失败，仍然认为插件可用（运行时验证）
          writeDebug('Warning: Could not get FFmpeg version: $e');
        });
      } catch (e) {
        // 如果导入失败，插件不可用
        _ffmpegKitAvailable = false;
        writeDebug('Error: FFmpegKit not available: $e');
      }
    }

    if (_ffprobeKitAvailable == null) {
      // FFprobeKit 总是可用（如果插件已安装）
      _ffprobeKitAvailable = true;
    }
  }

  static Map<String, String> getVersions([dynamic downloader]) {
    final pp = FFmpegPostProcessor(downloader);
    return {
      if (pp._version != null) 'ffmpeg': pp._version!,
      if (pp._probeVersion != null) 'ffprobe': pp._probeVersion!,
    };
  }

  bool get available {
    // 只使用 ffmpeg_kit_flutter_new 插件
    return _ffmpegKitAvailable == true;
  }

  String? get executable {
    // 返回特殊标记，表示使用 FFmpegKit API
    return 'ffmpeg_kit';
  }

  bool get probeAvailable {
    // 只使用 ffmpeg_kit_flutter_new 的 FFprobeKit
    return _ffprobeKitAvailable == true;
  }

  String? get probeExecutable {
    // 返回特殊标记，表示使用 FFprobeKit API
    return 'ffprobe_kit';
  }

  void checkVersion() {
    if (!available) {
      throw FFmpegPostProcessorError('ffmpeg_kit_flutter_new plugin not found. Please add ffmpeg_kit_flutter_new to your pubspec.yaml dependencies.');
    }

    // 异步获取版本信息（如果还没有）
    if (_version == null) {
      FFmpegKitConfig.getVersion().then((version) {
        if (version.isNotEmpty) {
          _version = version;
        }
      });
    }
  }

  /// 获取音频编解码器（异步版本）
  /// 使用 FFprobeKit API (https://pub.dev/packages/ffmpeg_kit_flutter_new)
  Future<String?> getAudioCodec(String filePath) async {
    if (!probeAvailable) {
      throw PostProcessingError('ffprobe not found. Please add ffmpeg_kit_flutter_new to your pubspec.yaml dependencies.');
    }

    try {
      writeDebug('Getting audio codec for file: $filePath');

      // 检查文件是否存在
      final file = File(filePath);
      if (!file.existsSync()) {
        writeDebug('File does not exist: $filePath');
        return null;
      }

      // 使用 FFprobeKit 通过 getMetadataObject 获取音频编解码器
      final metadata = await getMetadataObject(filePath);
      writeDebug('Successfully retrieved metadata, keys: ${metadata.keys.toList()}');

      final streams = metadata['streams'];
      if (streams == null) {
        writeDebug('No streams found in metadata');
        return null;
      }

      if (streams is List) {
        writeDebug('Found ${streams.length} streams');
        for (int i = 0; i < streams.length; i++) {
          final stream = streams[i];
          if (stream is Map) {
            final codecType = stream['codec_type'];
            final codecName = stream['codec_name'];
            writeDebug('Stream $i: codec_type=$codecType, codec_name=$codecName');

            if (codecType == 'audio') {
              if (codecName != null) {
                writeDebug('Found audio codec: $codecName');
                return codecName.toString();
              } else {
                writeDebug('Stream $i is audio but codec_name is null');
              }
            }
          }
        }
        writeDebug('No audio stream found in ${streams.length} streams');
      } else {
        writeDebug('Streams is not a List, type: ${streams.runtimeType}');
      }
    } catch (e, stackTrace) {
      writeDebug('Error getting audio codec with FFprobeKit: $e');
      writeDebug('Stack trace: $stackTrace');
      return null;
    }

    writeDebug('Failed to get audio codec: returning null');
    return null;
  }

  /// 获取音频编解码器（同步版本，已废弃，请使用异步版本）
  /// @deprecated 使用 getAudioCodec() async 版本
  String? getAudioCodecSync(String filePath) {
    // 尝试同步等待（不推荐，但为了向后兼容）
    try {
      final metadata = getMetadataObjectSync(filePath);
      final streams = metadata['streams'];
      if (streams is List) {
        for (final stream in streams) {
          if (stream is Map && stream['codec_type'] == 'audio') {
            final codecName = stream['codec_name'];
            if (codecName != null) {
              return codecName.toString();
            }
          }
        }
      }
    } catch (e) {
      writeDebug('Error getting audio codec (sync): $e');
      return null;
    }
    return null;
  }

  /// 获取媒体元数据（异步版本）
  /// 使用 FFprobeKit API (https://pub.dev/packages/ffmpeg_kit_flutter_new)
  Future<Map<String, dynamic>> getMetadataObject(String filePath, {List<String> opts = const []}) async {
    checkVersion();

    if (!probeAvailable) {
      throw PostProcessingError('ffprobe not found. Please add ffmpeg_kit_flutter_new to your pubspec.yaml dependencies.');
    }

    // 使用 FFprobeKit.execute() 执行命令
    return await _getMetadataObjectWithFFprobeKit(filePath, opts);
  }

  /// 获取媒体元数据（同步版本，已废弃，请使用异步版本）
  /// @deprecated 使用 getMetadataObject() async 版本
  Map<String, dynamic> getMetadataObjectSync(String filePath, {List<String> opts = const []}) {
    return _getMetadataObjectWithFFprobeKitSync(filePath, opts);
  }

  /// 从 FFprobeKit 输出中提取纯 JSON 部分
  /// FFprobeKit 的输出可能包含日志信息（如 "Input #0, mp3, from '...':"），
  /// 需要提取纯 JSON 对象
  String? _extractJsonFromOutput(String output) {
    // 方法1: 查找第一个 '{' 开始，使用括号匹配找到对应的 '}'
    final jsonStart = output.indexOf('{');
    if (jsonStart < 0) {
      writeDebug('No JSON start found in output');
      return null;
    }
    
    // 使用括号匹配找到完整的 JSON 对象（正确处理字符串中的括号）
    int braceCount = 0;
    int jsonEnd = -1;
    bool inString = false;
    bool escapeNext = false;
    
    for (int i = jsonStart; i < output.length; i++) {
      final char = output[i];
      
      if (escapeNext) {
        escapeNext = false;
        continue;
      }
      
      if (char == '\\') {
        escapeNext = true;
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
            jsonEnd = i;
            break;
          }
        }
      }
    }
    
    if (jsonEnd > jsonStart) {
      final jsonStr = output.substring(jsonStart, jsonEnd + 1);
      writeDebug('Extracted JSON from position $jsonStart to $jsonEnd (length: ${jsonStr.length})');
      // 验证提取的 JSON 是否有效
      try {
        json.decode(jsonStr);
        writeDebug('Extracted JSON is valid');
        return jsonStr;
      } catch (e) {
        writeDebug('Extracted JSON is invalid: $e');
        writeDebug('JSON preview (first 200 chars): ${jsonStr.length > 200 ? jsonStr.substring(0, 200) : jsonStr}');
        // 继续尝试其他方法
      }
    }
    
    // 方法2: 如果方法1失败，尝试查找包含 "streams" 或 "format" 的 JSON 对象
    final streamsIndex = output.indexOf('"streams"');
    final formatIndex = output.indexOf('"format"');
    if (streamsIndex > 0 || formatIndex > 0) {
      final searchIndex = streamsIndex > 0 && formatIndex > 0
          ? (streamsIndex < formatIndex ? streamsIndex : formatIndex)
          : (streamsIndex > 0 ? streamsIndex : formatIndex);
      
      // 向前查找最近的 '{'（在 searchIndex 之前）
      final jsonStart2 = output.lastIndexOf('{', searchIndex);
      if (jsonStart2 >= 0 && jsonStart2 != jsonStart) {
        // 再次使用括号匹配
        int braceCount2 = 0;
        int jsonEnd2 = -1;
        bool inString2 = false;
        bool escapeNext2 = false;
        
        for (int i = jsonStart2; i < output.length; i++) {
          final char = output[i];
          
          if (escapeNext2) {
            escapeNext2 = false;
            continue;
          }
          
          if (char == '\\') {
            escapeNext2 = true;
            continue;
          }
          
          if (char == '"') {
            inString2 = !inString2;
            continue;
          }
          
          if (!inString2) {
            if (char == '{') {
              braceCount2++;
            } else if (char == '}') {
              braceCount2--;
              if (braceCount2 == 0) {
                jsonEnd2 = i;
                break;
              }
            }
          }
        }
        
        if (jsonEnd2 > jsonStart2) {
          final jsonStr = output.substring(jsonStart2, jsonEnd2 + 1);
          writeDebug('Extracted JSON using alternative method from position $jsonStart2 to $jsonEnd2 (length: ${jsonStr.length})');
          // 验证提取的 JSON 是否有效
          try {
            json.decode(jsonStr);
            writeDebug('Extracted JSON is valid (alternative method)');
            return jsonStr;
          } catch (e) {
            writeDebug('Extracted JSON is invalid (alternative method): $e');
            writeDebug('JSON preview (first 200 chars): ${jsonStr.length > 200 ? jsonStr.substring(0, 200) : jsonStr}');
            // 继续尝试其他方法
          }
        }
      }
    }
    
    // 方法3: 尝试直接解析整个输出（如果输出是纯 JSON）
    try {
      final trimmed = output.trim();
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        json.decode(trimmed); // 验证是否是有效的 JSON
        writeDebug('Output is pure JSON, using directly');
        return trimmed;
      }
    } catch (e) {
      // 不是纯 JSON，继续
    }
    
    writeDebug('Failed to extract JSON from output');
    return null;
  }

  /// 使用 FFprobeKit API 异步获取元数据
  Future<Map<String, dynamic>> _getMetadataObjectWithFFprobeKit(String filePath, List<String> opts) async {
    try {
      // 检查文件是否存在
      final file = File(filePath);
      if (!file.existsSync()) {
        writeDebug('File does not exist: $filePath');
        throw PostProcessingError('File does not exist: $filePath');
      }

      writeDebug('File exists: ${file.existsSync()}, size: ${file.lengthSync()} bytes');

      // 构建 ffprobe 命令
      // 对包含空格的文件路径进行转义（ffprobe 不需要 file: 前缀）
      final escapedFilePath = filePath.contains(' ') ? '"$filePath"' : filePath;
      final cmd = <String>[
        '-hide_banner',
        '-loglevel', 'quiet', // 完全抑制日志输出，只输出 JSON
        '-show_format',
        '-show_streams',
        '-print_format',
        'json',
        ...opts,
        escapedFilePath,
      ];
      final command = cmd.join(' ');

      writeDebug('FFprobeKit command: $command');

      // 使用 FFprobeKit.execute() 执行命令
      final session = await FFprobeKit.execute(command);
      final returnCode = await session.getReturnCode();

      writeDebug('FFprobeKit return code: $returnCode');

      if (returnCode != null && ReturnCode.isSuccess(returnCode)) {
        final output = await session.getOutput();
        if (output != null && output.isNotEmpty) {
          writeDebug('FFprobeKit output length: ${output.length}');
          try {
            // 解析 JSON 输出
            // FFprobeKit 的输出可能包含日志（如 "Input #0, mp3, from '...':"），需要提取纯 JSON 部分
            String? jsonStr = _extractJsonFromOutput(output);
            
            if (jsonStr == null || jsonStr.isEmpty) {
              writeDebug('No valid JSON found in output');
              writeDebug('Output preview (first 1000 chars): ${output.length > 1000 ? output.substring(0, 1000) : output}');
              throw PostProcessingError('Failed to extract JSON from ffprobe output');
            }
            
            writeDebug('Extracted JSON length: ${jsonStr.length}');
            final result = json.decode(jsonStr) as Map<String, dynamic>;
            writeDebug('FFprobeKit successfully parsed JSON output');
            if (result.containsKey('streams')) {
              final streams = result['streams'];
              if (streams is List) {
                writeDebug('Found ${streams.length} streams in metadata');
              } else {
                writeDebug('Streams is not a List: ${streams.runtimeType}');
              }
            } else {
              writeDebug('Metadata does not contain "streams" key. Keys: ${result.keys.toList()}');
            }
            return result;
          } catch (e) {
            writeDebug('Failed to parse FFprobeKit JSON output: $e');
            writeDebug('Output preview (first 1000 chars): ${output.length > 1000 ? output.substring(0, 1000) : output}');
            throw PostProcessingError('Failed to parse ffprobe JSON output: $e');
          }
        } else {
          writeDebug('FFprobeKit returned empty output');
          throw PostProcessingError('ffprobe returned empty output');
        }
      } else {
        final failStackTrace = await session.getFailStackTrace();
        final output = await session.getOutput();
        writeDebug('FFprobeKit failed with return code: $returnCode');
        writeDebug('FFprobeKit output: $output');
        writeDebug('FFprobeKit fail stack trace: $failStackTrace');
        throw PostProcessingError('ffprobe failed: ${failStackTrace ?? output ?? "unknown error"}');
      }
    } catch (e, stackTrace) {
      writeDebug('Error getting metadata with FFprobeKit: $e');
      writeDebug('Stack trace: $stackTrace');
      // 重新抛出异常，让调用者知道具体错误
      if (e is PostProcessingError) {
        rethrow;
      }
      throw PostProcessingError('Error getting metadata with FFprobeKit: $e');
    }
  }

  /// 使用 FFprobeKit API 同步获取元数据（阻塞等待）
  /// 使用 FFprobeKit.execute() 执行 ffprobe 命令并解析 JSON 输出
  /// 参考: https://pub.dev/packages/ffmpeg_kit_flutter_new
  Map<String, dynamic> _getMetadataObjectWithFFprobeKitSync(String filePath, List<String> opts) {
    try {
      // 构建 ffprobe 命令
      final cmd = [
        '-hide_banner',
        '-loglevel', 'quiet', // 完全抑制日志输出，只输出 JSON
        '-show_format',
        '-show_streams',
        '-print_format',
        'json',
        ...opts,
        filePath,
      ];
      final command = cmd.join(' ');

      writeDebug('FFprobeKit command: $command');

      // 使用 Completer 将异步转换为同步
      Map<String, dynamic>? result;
      Exception? error;
      final completer = Completer<void>();
      var isCompleted = false;

      // 使用 FFprobeKit.execute() 执行命令
      FFprobeKit.execute(command).then((session) async {
        try {
          final returnCode = await session.getReturnCode();
          if (returnCode != null && ReturnCode.isSuccess(returnCode)) {
            final output = await session.getOutput();
            if (output != null && output.isNotEmpty) {
              try {
                // 解析 JSON 输出
                // FFprobeKit 的输出可能包含日志（如 "Input #0, mp3, from '...':"），需要提取纯 JSON 部分
                final jsonStr = _extractJsonFromOutput(output);
                
                if (jsonStr == null || jsonStr.isEmpty) {
                  writeDebug('No valid JSON found in output');
                  writeDebug('Output preview (first 1000 chars): ${output.length > 1000 ? output.substring(0, 1000) : output}');
                  error = PostProcessingError('Failed to extract JSON from ffprobe output');
                } else {
                  writeDebug('Extracted JSON length: ${jsonStr.length}');
                  result = json.decode(jsonStr) as Map<String, dynamic>;
                  writeDebug('FFprobeKit successfully parsed JSON output');
                }
              } catch (e) {
                writeDebug('Failed to parse FFprobeKit JSON output: $e');
                writeDebug('Output preview (first 1000 chars): ${output.length > 1000 ? output.substring(0, 1000) : output}');
                error = PostProcessingError('Failed to parse ffprobe JSON output: $e');
              }
            } else {
              writeDebug('FFprobeKit returned empty output');
              error = PostProcessingError('ffprobe returned empty output');
            }
          } else {
            final failStackTrace = await session.getFailStackTrace();
            final output = await session.getOutput();
            writeDebug('FFprobeKit failed with return code: $returnCode');
            writeDebug('FFprobeKit output: $output');
            writeDebug('FFprobeKit fail stack trace: $failStackTrace');
            error = PostProcessingError('ffprobe failed: ${failStackTrace ?? output ?? "unknown error"}');
          }
        } catch (e, stackTrace) {
          writeDebug('Error processing ffprobe result: $e');
          writeDebug('Stack trace: $stackTrace');
          error = PostProcessingError('Error processing ffprobe result: $e');
        } finally {
          isCompleted = true;
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
      }).catchError((e, stackTrace) {
        writeDebug('FFprobeKit execution failed: $e');
        writeDebug('Stack trace: $stackTrace');
        error = PostProcessingError('ffprobe execution failed: $e');
        isCompleted = true;
        if (!completer.isCompleted) {
          completer.complete();
        }
      });

      // 同步等待（使用循环和微任务）
      // 注意：在 Dart 中，同步等待异步操作需要使用特殊技巧
      var waitCount = 0;
      const maxWaitCount = 3000; // 最多等待 30 秒（每次 10ms）

      // 设置超时
      completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          if (!isCompleted) {
            writeDebug('FFprobeKit timeout after 30 seconds');
            error = PostProcessingError('ffprobe timeout after 30 seconds');
            isCompleted = true;
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
        },
      );

      // 等待完成 - 使用更可靠的等待机制
      while (!isCompleted && waitCount < maxWaitCount) {
        // 使用 Future.microtask 让事件循环有机会处理异步操作
        Future.microtask(() {});
        // 短暂等待
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsedMilliseconds < 10 && !isCompleted) {
          // 短暂等待，让 CPU 有机会处理其他任务
        }
        stopwatch.stop();
        waitCount++;
      }

      if (waitCount >= maxWaitCount && !isCompleted) {
        writeDebug('FFprobeKit timeout (max wait count exceeded)');
        error = PostProcessingError('ffprobe timeout (max wait exceeded)');
        isCompleted = true;
        if (!completer.isCompleted) {
          completer.complete();
        }
      }

      if (error != null) {
        writeDebug('FFprobeKit error: $error');
        throw error!;
      }

      if (result == null) {
        writeDebug('FFprobeKit returned null result');
        throw PostProcessingError('FFprobeKit returned null result');
      }

      // 此时 result 一定不为 null
      final finalResult = result!;
      writeDebug('FFprobeKit successfully retrieved metadata with ${finalResult.length} keys');
      if (finalResult.containsKey('streams')) {
        final streams = finalResult['streams'];
        if (streams is List) {
          writeDebug('Found ${streams.length} streams');
        }
      }
      return finalResult;
    } catch (e, stackTrace) {
      writeDebug('Error getting metadata with FFprobeKit: $e');
      writeDebug('Stack trace: $stackTrace');
      throw PostProcessingError('Error getting metadata with FFprobeKit: $e');
    }
  }

  List<dynamic> streamCopyOpts({bool copy = true, String? ext}) {
    final opts = <String>['-map', '0', '-dn', '-ignore_unknown'];
    if (copy) {
      opts.addAll(['-c', 'copy']);
    }
    if (ext != null && ['mp4', 'mov', 'm4a'].contains(ext)) {
      opts.addAll(['-c:s', 'mov_text']);
    }
    return opts;
  }

  /// 转义文件路径，如果路径包含空格，则用引号包裹
  String _escapeFilePath(String path) {
    // 如果路径包含空格，需要用引号包裹
    if (path.contains(' ')) {
      // 对于 file: 协议，需要在 file: 后面加上引号包裹的路径
      if (path.startsWith('file:')) {
        final actualPath = path.substring(5); // 移除 'file:' 前缀
        return 'file:"$actualPath"';
      }
      return '"$path"';
    }
    return path;
  }

  String _ffmpegFilenameArgument(String fn) {
    if (fn.startsWith('http://') || fn.startsWith('https://')) {
      return fn;
    }
    if (fn == '-') {
      return fn;
    }
    // 对包含空格的文件路径进行转义
    final pathWithPrefix = 'file:$fn';
    return _escapeFilePath(pathWithPrefix);
  }

  Future<String> runFfmpeg(String path, String outPath, List<String> opts, {List<int>? expectedRetcodes}) async {
    return await runFfmpegMultipleFiles([path], outPath, opts, expectedRetcodes: expectedRetcodes);
  }

  Future<String> runFfmpegMultipleFiles(
    List<String> inputPaths,
    String outPath,
    List<String> opts, {
    List<int>? expectedRetcodes,
  }) async {
    return await realRunFfmpeg(
      inputPaths.map((p) => [p, <String>[]]).toList(),
      [
        [outPath, opts]
      ],
      expectedRetcodes: expectedRetcodes,
    );
  }

  Future<String> realRunFfmpeg(
    List<List<dynamic>> inputPathOpts,
    List<List<dynamic>> outputPathOpts, {
    List<int>? expectedRetcodes,
  }) async {
    checkVersion();

    expectedRetcodes ??= [0];

    // Get oldest mtime from input files
    int? oldestMtime;
    for (final pathOpt in inputPathOpts) {
      final filePath = pathOpt[0] as String;
      if (filePath.isNotEmpty) {
        final file = File(filePath);
        if (file.existsSync()) {
          final stat = file.statSync();
          if (oldestMtime == null || stat.modified.millisecondsSinceEpoch < oldestMtime) {
            oldestMtime = stat.modified.millisecondsSinceEpoch;
          }
        }
      }
    }

    // 构建 FFmpeg 命令参数（使用 FFmpegKit API）
    final cmd = <String>['-y', '-loglevel', 'repeat+info'];

    // Add input files
    for (final pathOpt in inputPathOpts) {
      final filePath = pathOpt[0] as String;
      final fileOpts = pathOpt[1] as List<String>;
      if (filePath.isNotEmpty) {
        cmd.addAll(fileOpts);
        cmd.addAll(['-i', _ffmpegFilenameArgument(filePath)]);
      }
    }

    // Add output file
    for (final pathOpt in outputPathOpts) {
      final filePath = pathOpt[0] as String;
      final fileOpts = pathOpt[1] as List<String>;
      if (filePath.isNotEmpty) {
        if (filePath == outputPathOpts[0][0]) {
          // 根据文件扩展名判断是否需要添加 faststart（只对容器格式有效）
          final extension = path.extension(filePath).toLowerCase();
          final containerFormats = ['.mp4', '.mov', '.m4a', '.m4v'];
          final audioFormats = ['.mp3', '.ogg', '.opus', '.flac', '.wav', '.aac'];
          
          // 如果输出文件是 .tmp，尝试从文件名或输入文件推断格式
          String? actualFormat;
          if (extension == '.tmp') {
            // 尝试从文件名推断（例如 .mp3.tmp -> .mp3）
            final fileName = path.basename(filePath);
            // 查找 .tmp 之前的扩展名
            final tmpIndex = fileName.toLowerCase().lastIndexOf('.tmp');
            if (tmpIndex > 0) {
              final beforeTmp = fileName.substring(0, tmpIndex);
              final inferredExt = path.extension(beforeTmp).toLowerCase();
              if (inferredExt.isNotEmpty) {
                actualFormat = inferredExt;
              }
            }
            
            // 如果无法从文件名推断，尝试从输入文件推断
            if (actualFormat == null && inputPathOpts.isNotEmpty) {
              final inputPath = inputPathOpts[0][0] as String;
              actualFormat = path.extension(inputPath).toLowerCase();
            }
          } else {
            actualFormat = extension;
          }
          
          // 只对容器格式添加 faststart
          if (actualFormat != null && containerFormats.contains(actualFormat)) {
            fileOpts.addAll(['-movflags', '+faststart']);
          } else if (actualFormat != null && audioFormats.contains(actualFormat)) {
            // 对于纯音频格式，明确指定输出格式（FFmpeg 可能无法从 .tmp 扩展名推断格式）
            if (extension == '.tmp') {
              // 移除格式扩展名，只保留实际格式（例如 .mp3 -> mp3）
              final formatName = actualFormat.substring(1); // 移除开头的点
              fileOpts.addAll(['-f', formatName]);
            }
          }
        }
        cmd.addAll(fileOpts);
        // 对输出文件路径进行转义（处理包含空格的情况，输出路径不需要 file: 前缀）
        final escapedOutPath = filePath.contains(' ') ? '"$filePath"' : filePath;
        cmd.add(escapedOutPath);
      }
    }

    final command = cmd.join(' ');
    writeDebug('FFmpegKit command: $command');

    // 使用 FFmpegKit API 执行命令
    // 参考: https://pub.dev/packages/ffmpeg_kit_flutter_new
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();
    final returnCodeValue = returnCode?.getValue();

    if (returnCodeValue == null || !expectedRetcodes.contains(returnCodeValue)) {
      final failStackTrace = await session.getFailStackTrace();
      final output = await session.getOutput();
      writeDebug('FFmpegKit failed: $output');
      throw FFmpegPostProcessorError(failStackTrace ?? output ?? 'ffmpeg failed with return code $returnCodeValue');
    }

    // Update file times
    if (oldestMtime != null) {
      for (final pathOpt in outputPathOpts) {
        final filePath = pathOpt[0] as String;
        if (filePath.isNotEmpty) {
          try {
            final file = File(filePath);
            if (file.existsSync()) {
              // Note: Dart doesn't have direct utime, this is simplified
            }
          } catch (e) {
            // Ignore
          }
        }
      }
    }

    final output = await session.getOutput();
    return output ?? '';
  }

  double? _getRealVideoDuration(String filePath, {bool fatal = true}) {
    try {
      final metadata = getMetadataObjectSync(filePath);
      final format = metadata['format'] as Map<String, dynamic>?;
      final duration = format?['duration'];
      if (duration == null) {
        throw PostProcessingError('ffprobe returned empty duration');
      }
      return double.tryParse(duration.toString());
    } catch (e) {
      if (fatal) {
        throw PostProcessingError('Unable to determine video duration: $e');
      }
      return null;
    }
  }

  void _fixupChapters(Map<String, dynamic> info) {
    final chapters = info['chapters'] as List?;
    if (chapters != null && chapters.isNotEmpty) {
      final lastChapter = chapters.last as Map<String, dynamic>;
      if (lastChapter['end_time'] == null) {
        final filepath = info['filepath'] as String?;
        if (filepath != null) {
          final duration = _getRealVideoDuration(filepath, fatal: false);
          if (duration != null) {
            lastChapter['end_time'] = duration;
          }
        }
      }
    }
  }
}

/// FFmpegExtractAudioPP - Extract audio from video
class FFmpegExtractAudioPP extends FFmpegPostProcessor {
  static const commonAudioExts = ['mp3', 'm4a', 'ogg', 'opus', 'wav', 'flac', 'wma'];
  static const supportedExts = ['mp3', 'aac', 'm4a', 'opus', 'vorbis', 'flac', 'alac', 'wav'];

  String mapping;
  double? preferredQuality;
  bool nopostoverwrites;

  FFmpegExtractAudioPP({
    dynamic downloader,
    String? preferredcodec,
    double? preferredquality,
    bool nopostoverwrites = false,
  })  : mapping = preferredcodec ?? 'best',
        preferredQuality = preferredquality,
        nopostoverwrites = nopostoverwrites,
        super(downloader);

  List<String> _qualityArgs(String? codec) {
    if (preferredQuality == null || codec == null) return [];

    if (preferredQuality! > 10) {
      return ['-b:a', '${preferredQuality!.toInt()}k'];
    }

    // Quality mapping for different codecs
    final limits = <String, List<double>>{
      'libmp3lame': [10, 0],
      'libvorbis': [0, 10],
      'aac': [0.1, 4],
      'libfdk_aac': [1, 5],
    };

    final codecLimits = limits[codec];
    if (codecLimits == null) return [];

    final q = codecLimits[1] + (codecLimits[0] - codecLimits[1]) * (preferredQuality! / 10);
    if (codec == 'libfdk_aac') {
      return ['-vbr', q.toInt().toString()];
    }
    return ['-q:a', q.toStringAsFixed(2)];
  }

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> information) async {
    final origPath = information['filepath'] as String;
    final ext = information['ext'] as String? ?? '';

    final targetFormat = resolveMapping(ext, mapping);
    if (targetFormat == null || targetFormat == 'best') {
      if (commonAudioExts.contains(ext)) {
        toScreen('Not converting audio $origPath; the file is already in a common audio format');
        return {'files_to_delete': [], 'info': information};
      }
    }

    if (targetFormat == null) {
      toScreen('Not converting audio $origPath; could not find a mapping');
      return {'files_to_delete': [], 'info': information};
    }

    // 尝试获取音频编解码器（参考 Python 版本的严格策略）
    String? filecodec = await getAudioCodec(origPath);
    final codecUnknown = filecodec == null;

    if (codecUnknown) {
      final file = File(origPath);
      final fileExists = file.existsSync();
      final fileSize = fileExists ? file.lengthSync() : 0;
      final warningMsg = 'WARNING: unable to obtain file audio codec with ffprobe. '
          'File: $origPath, Exists: $fileExists, Size: $fileSize bytes. '
          'Will force re-encoding to target format.';
      toScreen(warningMsg);
      reportWarning(warningMsg);
      // 当无法获取编解码器时，不能假设源格式，必须强制重新编码到目标格式
      // 不使用 copy 操作，避免编解码器不匹配导致的错误
      writeDebug('Codec unknown, will force re-encoding to target format: $targetFormat');
    }

    String extension;
    String? acodec;
    List<String> moreOpts;

    // 如果无法确定源编解码器，强制重新编码到目标格式（不使用 copy）
    if (codecUnknown) {
      // 当 targetFormat == 'best' 时，使用 MP3 作为默认格式
      final actualTargetFormat = targetFormat == 'best' ? 'mp3' : targetFormat;
      if (!acodecs.containsKey(actualTargetFormat)) {
        throw PostProcessingError('Unknown target format: $actualTargetFormat');
      }

      // 强制转换到目标格式，使用目标格式的编码器
      final codecInfo = acodecs[actualTargetFormat]!;
      extension = codecInfo[0] as String;
      acodec = codecInfo[1] as String?; // 可能是 null（对于 alac, wav）
      moreOpts = List<String>.from(codecInfo[2] as List);

      if (acodec == 'aac' && _features['fdk'] == true) {
        acodec = 'libfdk_aac';
        moreOpts = [];
      }
      writeDebug('Force re-encoding: target=$actualTargetFormat (original: $targetFormat), codec=$acodec (source codec unknown)');
    } else if (filecodec == 'aac' && ['m4a', 'best'].contains(targetFormat)) {
      // AAC 到 M4A 可以无损复制（容器转换）
      final m4aInfo = acodecs['m4a']!;
      extension = m4aInfo[0] as String;
      moreOpts = List<String>.from(m4aInfo[2] as List);
      acodec = 'copy';
      writeDebug('Lossless container conversion: AAC -> M4A');
    } else if (targetFormat == 'best' || targetFormat == filecodec) {
      // 相同格式，尝试无损复制
      if (acodecs.containsKey(filecodec)) {
        final codecInfo = acodecs[filecodec]!;
        extension = codecInfo[0] as String;
        moreOpts = List<String>.from(codecInfo[2] as List);
        acodec = 'copy';
        writeDebug('Lossless copy: format=$filecodec');
      } else {
        // 无法无损复制，使用 MP3 作为默认（参考 Python 版本）
        final mp3Info = acodecs['mp3']!;
        extension = mp3Info[0] as String;
        acodec = mp3Info[1] as String?; // MP3 的编码器是 libmp3lame，不会是 null
        moreOpts = List<String>.from(mp3Info[2] as List);
        writeDebug('Fallback to MP3 encoding: format not in acodecs, filecodec=$filecodec, target=$targetFormat');
      }
    } else {
      // 转换到目标格式（需要重新编码）
      if (!acodecs.containsKey(targetFormat)) {
        throw PostProcessingError('Unknown target format: $targetFormat');
      }
      final codecInfo = acodecs[targetFormat]!;
      extension = codecInfo[0] as String;
      acodec = codecInfo[1] as String?; // 可能是 null（对于 alac, wav）
      moreOpts = List<String>.from(codecInfo[2] as List);

      if (acodec == 'aac' && _features['fdk'] == true) {
        acodec = 'libfdk_aac';
        moreOpts = [];
      }
      writeDebug('Converting audio: $filecodec -> $targetFormat, codec=$acodec');
    }

    // 对于 MP3 输出格式，必须使用编码器，不能使用 copy（除非源格式也是 MP3）
    if (extension == 'mp3' && acodec == 'copy' && (codecUnknown || filecodec != 'mp3')) {
      final mp3Info = acodecs['mp3']!;
      acodec = mp3Info[1] as String?; // MP3 的编码器是 libmp3lame，不会是 null
      moreOpts = List<String>.from(mp3Info[2] as List);
      writeDebug('Force MP3 encoding (cannot use copy for MP3 output when source is not MP3 or unknown)');
    }

    if (acodec != null && acodec != 'copy') {
      moreOpts.addAll(_qualityArgs(acodec));
    }

    final newPath = _replaceExtension(origPath, extension, ext);
    var tempPath = newPath;
    var finalOrigPath = origPath;

    if (newPath == origPath) {
      if (acodec == 'copy') {
        toScreen('Not converting audio $origPath; file is already in target format $targetFormat');
        return {'files_to_delete': [], 'info': information};
      }
      finalOrigPath = _prependExtension(origPath, 'orig');
      tempPath = _prependExtension(origPath, 'temp');
    }

    if (nopostoverwrites && File(newPath).existsSync() && File(finalOrigPath).existsSync()) {
      toScreen('Post-process file $newPath exists, skipping');
      return {'files_to_delete': [], 'info': information};
    }

    toScreen('Destination: $newPath');

    // 构建 FFmpeg 选项（参考 Python 版本的 run_ffmpeg 方法）
    final opts = <String>['-vn'];
    // 如果 acodec 是 null，不添加 -acodec 参数（使用 moreOpts 中的选项，如 -acodec alac）
    if (acodec != null) {
      opts.addAll(['-acodec', acodec]);
    }
    opts.addAll(moreOpts);

    await runFfmpeg(origPath, tempPath, opts);

    if (finalOrigPath != origPath) {
      await File(origPath).rename(finalOrigPath);
    }
    await File(tempPath).rename(newPath);

    information['filepath'] = newPath;
    information['ext'] = extension;

    return {
      'files_to_delete': [finalOrigPath],
      'info': information
    };
  }

  String _replaceExtension(String filepath, String newExt, String oldExt) {
    if (filepath.endsWith(oldExt)) {
      return filepath.substring(0, filepath.length - oldExt.length) + newExt;
    }
    return path.setExtension(filepath, '.$newExt');
  }

  String _prependExtension(String filepath, String prefix) {
    final ext = path.extension(filepath);
    final base = path.withoutExtension(filepath);
    return '$base.$prefix$ext';
  }
}

/// FFmpegVideoConvertorPP - Convert video format
class FFmpegVideoConvertorPP extends FFmpegPostProcessor {
  static const supportedExts = ['mp4', 'avi', 'mkv', 'webm', 'flv', 'mov', 'mp3', 'm4a', 'ogg', 'opus', 'aac', 'vorbis', 'gif'];

  String? mapping;

  FFmpegVideoConvertorPP({dynamic downloader, String? preferedformat})
      : mapping = preferedformat,
        super(downloader);

  List<String> _options(String targetExt) {
    final streamOpts = streamCopyOpts(copy: false);
    final opts = streamOpts.map((e) => e.toString()).toList();
    if (targetExt == 'avi') {
      opts.addAll(['-c:v', 'libxvid', '-vtag', 'XVID']);
    }
    return opts;
  }

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    final filename = info['filepath'] as String;
    final sourceExt = (info['ext'] as String? ?? '').toLowerCase();

    if (mapping == null) {
      toScreen('Not converting media file "$filename"; no target format specified');
      return {'files_to_delete': [], 'info': info};
    }

    final targetExt = resolveMapping(sourceExt, mapping!);
    if (targetExt == null) {
      toScreen('Not converting media file "$filename"; could not find a mapping');
      return {'files_to_delete': [], 'info': info};
    }

    final outpath = _replaceExtension(filename, targetExt, sourceExt);
    toScreen('Converting video from $sourceExt to $targetExt; Destination: $outpath');

    await runFfmpeg(filename, outpath, _options(targetExt));

    info['filepath'] = outpath;
    info['format'] = targetExt;
    info['ext'] = targetExt;

    return {
      'files_to_delete': [filename],
      'info': info
    };
  }

  String _replaceExtension(String filepath, String newExt, String oldExt) {
    if (filepath.endsWith(oldExt)) {
      return filepath.substring(0, filepath.length - oldExt.length) + newExt;
    }
    return path.setExtension(filepath, '.$newExt');
  }
}

/// FFmpegVideoRemuxerPP - Remux video (copy streams without re-encoding)
class FFmpegVideoRemuxerPP extends FFmpegVideoConvertorPP {
  FFmpegVideoRemuxerPP({dynamic downloader, String? preferedformat}) : super(downloader: downloader, preferedformat: preferedformat);

  @override
  List<String> _options(String targetExt) {
    final streamOpts = streamCopyOpts();
    return streamOpts.map((e) => e.toString()).toList();
  }
}

/// FFmpegEmbedSubtitlePP - Embed subtitles into video
class FFmpegEmbedSubtitlePP extends FFmpegPostProcessor {
  static const supportedExts = ['mp4', 'mov', 'm4a', 'webm', 'mkv', 'mka'];

  bool alreadyHaveSubtitle;

  FFmpegEmbedSubtitlePP({dynamic downloader, bool alreadyHaveSubtitle = false})
      : alreadyHaveSubtitle = alreadyHaveSubtitle,
        super(downloader);

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    final ext = info['ext'] as String? ?? '';
    if (!supportedExts.contains(ext)) {
      toScreen('Subtitles can only be embedded in ${supportedExts.join(", ")} files');
      return {'files_to_delete': [], 'info': info};
    }

    final subtitles = info['requested_subtitles'] as Map<String, dynamic>?;
    if (subtitles == null || subtitles.isEmpty) {
      toScreen('There aren\'t any subtitles to embed');
      return {'files_to_delete': [], 'info': info};
    }

    final filename = info['filepath'] as String;
    final subLangs = <String>[];
    final subNames = <String?>[];
    final subFilenames = <String>[];

    for (final entry in subtitles.entries) {
      final lang = entry.key;
      final subInfo = entry.value as Map<String, dynamic>;
      final subPath = subInfo['filepath'] as String?;

      if (subPath == null || !File(subPath).existsSync()) {
        reportWarning('Skipping embedding $lang subtitle because the file is missing');
        continue;
      }

      final subExt = subInfo['ext'] as String? ?? '';
      if (subExt == 'json') {
        reportWarning('JSON subtitles cannot be embedded');
        continue;
      }

      if (ext != 'webm' || (ext == 'webm' && subExt == 'vtt')) {
        subLangs.add(lang);
        subNames.add(subInfo['name'] as String?);
        subFilenames.add(subPath);
      } else if (ext == 'webm' && subExt != 'vtt') {
        reportWarning('Only WebVTT subtitles can be embedded in webm files');
      }

      if (ext == 'mp4' && subExt == 'ass') {
        reportWarning('ASS subtitles cannot be properly embedded in mp4 files; expect issues');
      }
    }

    if (subLangs.isEmpty) {
      return {'files_to_delete': [], 'info': info};
    }

    final inputFiles = [filename, ...subFilenames];
    final streamOpts = streamCopyOpts(ext: ext);
    final opts = <String>[
      ...streamOpts.map((e) => e.toString()),
      '-map',
      '-0:s',
    ];

    for (int i = 0; i < subLangs.length; i++) {
      opts.addAll(['-map', '${i + 1}:0']);
      final lang = subLangs[i];
      opts.addAll(['-metadata:s:s:$i', 'language=$lang']);
      final name = subNames[i];
      if (name != null) {
        opts.addAll([
          '-metadata:s:s:$i',
          'handler_name=$name',
          '-metadata:s:s:$i',
          'title=$name',
        ]);
      }
    }

    final tempFilename = _prependExtension(filename, 'temp');
    toScreen('Embedding subtitles in "$filename"');

    await runFfmpegMultipleFiles(inputFiles, tempFilename, opts);
    await File(tempFilename).rename(filename);

    final filesToDelete = alreadyHaveSubtitle ? <String>[] : subFilenames;
    return {'files_to_delete': filesToDelete, 'info': info};
  }

  String _prependExtension(String filepath, String prefix) {
    final ext = path.extension(filepath);
    final base = path.withoutExtension(filepath);
    return '$base.$prefix$ext';
  }
}

/// FFmpegMetadataPP - Add metadata to video
class FFmpegMetadataPP extends FFmpegPostProcessor {
  bool addMetadata;
  bool addChapters;
  dynamic addInfojson;

  FFmpegMetadataPP({
    dynamic downloader,
    bool addMetadata = true,
    bool addChapters = true,
    dynamic addInfojson = 'if_exists',
  })  : addMetadata = addMetadata,
        addChapters = addChapters,
        addInfojson = addInfojson,
        super(downloader);

  List<String> _options(String targetExt) {
    final audioOnly = targetExt == 'm4a';
    final streamOpts = streamCopyOpts(copy: !audioOnly);
    final opts = streamOpts.map((e) => e.toString()).toList();
    if (audioOnly) {
      opts.addAll(['-vn', '-acodec', 'copy']);
    }
    return opts;
  }

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    _fixupChapters(info);
    final filename = info['filepath'] as String;
    final filesToDelete = <String>[];
    final options = <String>[];

    if (addChapters && info['chapters'] != null) {
      final metadataFilename = _replaceExtension(filename, 'meta', path.extension(filename).substring(1));
      options.addAll(_getChapterOpts(info['chapters'] as List, metadataFilename));
      filesToDelete.add(metadataFilename);
    }

    if (addMetadata) {
      options.addAll(_getMetadataOpts(info));
    }

    if (addInfojson != null && addInfojson != false && addInfojson != 'if_exists') {
      final ext = info['ext'] as String? ?? '';
      if (['mkv', 'mka'].contains(ext)) {
        // Infojson handling simplified
        // In full implementation, would handle info.json attachment
      } else if (addInfojson == true) {
        toScreen('The info-json can only be attached to mkv/mka files');
      }
    }

    if (options.isEmpty) {
      toScreen('There isn\'t any metadata to add');
      return {'files_to_delete': [], 'info': info};
    }

    final tempFilename = _prependExtension(filename, 'temp');
    toScreen('Adding metadata to "$filename"');

    final ext = info['ext'] as String? ?? '';
    final allOpts = <String>[
      ..._options(ext),
      ...options,
    ];

    await runFfmpegMultipleFiles([filename], tempFilename, allOpts);
    deleteDownloadedFiles(filesToDelete);
    await File(tempFilename).rename(filename);

    return {'files_to_delete': [], 'info': info};
  }

  List<String> _getChapterOpts(List chapters, String metadataFilename) {
    final file = File(metadataFilename);
    final content = StringBuffer(';FFMETADATA1\n');

    for (final chapter in chapters) {
      if (chapter is! Map<String, dynamic>) continue;
      final ch = chapter;
      final startTime = (ch['start_time'] as num?)?.toInt() ?? 0;
      final endTime = (ch['end_time'] as num?)?.toInt() ?? 0;
      final title = ch['title'] as String?;

      content.writeln('[CHAPTER]');
      content.writeln('TIMEBASE=1/1000');
      content.writeln('START=${startTime * 1000}');
      content.writeln('END=${endTime * 1000}');
      if (title != null) {
        final escaped = title.replaceAllMapped(RegExp(r'([\\=;#\n])'), (m) => '\\${m.group(1)}');
        content.writeln('title=$escaped');
      }
    }

    file.writeAsStringSync(content.toString());

    return ['-map_metadata', '1'];
  }

  List<String> _getMetadataOpts(Map<String, dynamic> info) {
    final opts = <String>['-write_id3v1', '1'];
    final metadata = <String, String>{};

    // Add common metadata fields
    void addMeta(String key, List<String> infoKeys) {
      for (final infoKey in infoKeys) {
        final value = info[infoKey];
        if (value != null && value.toString().isNotEmpty) {
          metadata[key] = value.toString().replaceAll('\0', '');
          return;
        }
      }
    }

    addMeta('title', ['track', 'title']);
    addMeta('date', ['upload_date']);
    addMeta('description', ['description']);
    addMeta('comment', ['webpage_url']);
    addMeta('artist', ['artist', 'artists', 'creator', 'creators', 'uploader', 'uploader_id']);
    addMeta('album', ['album', 'series']);

    for (final entry in metadata.entries) {
      opts.addAll(['-metadata', '${entry.key}=${entry.value}']);
    }

    return opts;
  }

  String _replaceExtension(String filepath, String newExt, String oldExt) {
    if (filepath.endsWith(oldExt)) {
      return filepath.substring(0, filepath.length - oldExt.length) + newExt;
    }
    return path.setExtension(filepath, '.$newExt');
  }

  String _prependExtension(String filepath, String prefix) {
    final ext = path.extension(filepath);
    final base = path.withoutExtension(filepath);
    return '$base.$prefix$ext';
  }
}

/// FFmpegMergerPP - Merge video and audio streams
class FFmpegMergerPP extends FFmpegPostProcessor {
  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    final filename = info['filepath'] as String;
    final tempFilename = _prependExtension(filename, 'temp');
    final args = <String>['-c', 'copy'];

    final requestedFormats = info['requested_formats'];
    final formats = requestedFormats is List ? requestedFormats : <dynamic>[];

    for (int i = 0; i < formats.length; i++) {
      final fmt = formats[i];
      if (fmt is! Map<String, dynamic>) continue;
      if (fmt['acodec'] != 'none') {
        args.addAll(['-map', '$i:a:0']);
        // 注意：这里在循环中，不能使用 await，暂时跳过 aacFixup 检查
        // 或者需要重构为异步方法
        // TODO: 如果需要 aacFixup，需要重构为异步方法
      }
      if (fmt['vcodec'] != 'none') {
        args.addAll(['-map', '$i:v:0']);
      }
    }

    final filesToMerge = info['__files_to_merge'] as List<String>? ?? [];
    toScreen('Merging formats into "$filename"');

    await runFfmpegMultipleFiles(filesToMerge, tempFilename, args);
    await File(tempFilename).rename(filename);

    return {'files_to_delete': filesToMerge, 'info': info};
  }

  String _prependExtension(String filepath, String prefix) {
    final ext = path.extension(filepath);
    final base = path.withoutExtension(filepath);
    return '$base.$prefix$ext';
  }

  bool canMerge() {
    return true;
  }
}

/// FFmpegFixupPostProcessor - Base class for fixup processors
abstract class FFmpegFixupPostProcessor extends FFmpegPostProcessor {
  FFmpegFixupPostProcessor([super.downloader]);

  Future<void> _fixup(String msg, String filename, List<String> options) async {
    final tempFilename = _prependExtension(filename, 'temp');
    toScreen('$msg of "$filename"');
    await runFfmpeg(filename, tempFilename, options);
    await File(tempFilename).rename(filename);
  }

  String _prependExtension(String filepath, String prefix) {
    final ext = path.extension(filepath);
    final base = path.withoutExtension(filepath);
    return '$base.$prefix$ext';
  }
}

/// FFmpegFixupStretchedPP - Fix aspect ratio
class FFmpegFixupStretchedPP extends FFmpegFixupPostProcessor {
  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    final stretchedRatio = info['stretched_ratio'];
    if (stretchedRatio != null && stretchedRatio != 1) {
      final streamOpts = streamCopyOpts();
      final opts = <String>[
        ...streamOpts.map((e) => e.toString()),
        '-aspect',
        stretchedRatio.toString(),
      ];
      await _fixup('Fixing aspect ratio', info['filepath'] as String, opts);
    }
    return {'files_to_delete': [], 'info': info};
  }
}

/// FFmpegFixupM4aPP - Fix M4A container
class FFmpegFixupM4aPP extends FFmpegFixupPostProcessor {
  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    if (info['container'] == 'm4a_dash') {
      final streamOpts = streamCopyOpts();
      final opts = <String>[
        ...streamOpts.map((e) => e.toString()),
        '-f',
        'mp4',
      ];
      await _fixup('Correcting container', info['filepath'] as String, opts);
    }
    return {'files_to_delete': [], 'info': info};
  }
}

/// FFmpegFixupM3u8PP - Fix MPEG-TS in MP4 container
class FFmpegFixupM3u8PP extends FFmpegFixupPostProcessor {
  bool _needsFixup(Map<String, dynamic> info) {
    final ext = info['ext'] as String? ?? '';
    if (!['mp4', 'm4a'].contains(ext)) return false;

    final protocol = info['protocol'] as String? ?? '';
    if (!protocol.startsWith('m3u8')) return false;

    try {
      final metadata = getMetadataObjectSync(info['filepath'] as String);
      final format = metadata['format'] as Map<String, dynamic>?;
      final formatName = format?['format_name'] as String?;
      return formatName?.toLowerCase() == 'mpegts';
    } catch (e) {
      reportWarning('Unable to extract metadata: $e');
      return true;
    }
  }

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    if (_needsFixup(info)) {
      final args = <String>['-f', 'mp4'];
      final audioCodec = await getAudioCodec(info['filepath'] as String);
      if (audioCodec == 'aac') {
        args.addAll(['-bsf:a', 'aac_adtstoasc']);
      }
      final streamOpts = streamCopyOpts();
      final opts = <String>[
        ...streamOpts.map((e) => e.toString()),
        ...args,
      ];
      await _fixup('Fixing MPEG-TS in MP4 container', info['filepath'] as String, opts);
    }
    return {'files_to_delete': [], 'info': info};
  }
}

/// FFmpegFixupTimestampPP - Fix frame timestamps
class FFmpegFixupTimestampPP extends FFmpegFixupPostProcessor {
  final String trim;

  FFmpegFixupTimestampPP({dynamic downloader, double trim = 0.001})
      : trim = trim.toString(),
        super(downloader);

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    List<String> opts;
    if (_features['setts'] != true) {
      reportWarning('A re-encode is needed to fix timestamps in older versions of ffmpeg. '
          'Please install ffmpeg 4.4 or later to fixup without re-encoding');
      opts = ['-vf', 'setpts=PTS-STARTPTS'];
    } else {
      opts = ['-c', 'copy', '-bsf', 'setts=ts=TS-STARTPTS'];
    }
    final streamOpts = streamCopyOpts(copy: false);
    opts.addAll(streamOpts.map((e) => e.toString()));
    opts.addAll(['-ss', trim]);
    await _fixup('Fixing frame timestamp', info['filepath'] as String, opts);
    return {'files_to_delete': [], 'info': info};
  }
}

/// FFmpegCopyStreamPP - Copy stream
class FFmpegCopyStreamPP extends FFmpegFixupPostProcessor {
  static const message = 'Copying stream';

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    final streamOpts = streamCopyOpts();
    final opts = streamOpts.map((e) => e.toString()).toList();
    await _fixup(message, info['filepath'] as String, opts);
    return {'files_to_delete': [], 'info': info};
  }
}

/// FFmpegFixupDurationPP - Fix video duration
class FFmpegFixupDurationPP extends FFmpegCopyStreamPP {
  static const message = 'Fixing video duration';
}

/// FFmpegFixupDuplicateMoovPP - Fix duplicate MOOV atoms
class FFmpegFixupDuplicateMoovPP extends FFmpegCopyStreamPP {
  static const message = 'Fixing duplicate MOOV atoms';
}

/// FFmpegSubtitlesConvertorPP - Convert subtitle formats
class FFmpegSubtitlesConvertorPP extends FFmpegPostProcessor {
  static const supportedExts = ['srt', 'vtt', 'ass', 'ssa', 'ttml', 'dfxp'];

  String? format;

  FFmpegSubtitlesConvertorPP({dynamic downloader, String? format})
      : format = format,
        super(downloader);

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    final subs = info['requested_subtitles'] as Map<String, dynamic>?;
    if (subs == null || format == null) {
      toScreen('There aren\'t any subtitles to convert');
      return {'files_to_delete': [], 'info': info};
    }

    final newExt = format!;
    final newFormat = newExt == 'vtt' ? 'webvtt' : newExt;

    toScreen('Converting subtitles');
    final subFilenames = <String>[];

    for (final entry in subs.entries) {
      final lang = entry.key;
      final sub = entry.value as Map<String, dynamic>;
      final subPath = sub['filepath'] as String?;

      if (subPath == null || !File(subPath).existsSync()) {
        reportWarning('Skipping converting $lang subtitle because the file is missing');
        continue;
      }

      final ext = sub['ext'] as String? ?? '';
      if (ext == newExt) {
        toScreen('Subtitle file for $newExt is already in the requested format');
        continue;
      } else if (ext == 'json') {
        toScreen('You have requested to convert json subtitles into another format, '
            'which is currently not possible');
        continue;
      }

      final oldFile = subPath;
      subFilenames.add(oldFile);
      final newFile = _replaceExtension(oldFile, newExt);

      // Convert using ffmpeg
      await runFfmpeg(oldFile, newFile, ['-f', newFormat]);

      // Update subtitle info
      try {
        final content = await File(newFile).readAsString();
        subs[lang] = {
          'ext': newExt,
          'data': content,
          'filepath': newFile,
        };
      } catch (e) {
        reportWarning('Failed to read converted subtitle file: $e');
      }
    }

    return {'files_to_delete': subFilenames, 'info': info};
  }

  String _replaceExtension(String filepath, String newExt) {
    return path.setExtension(filepath, '.$newExt');
  }
}

/// FFmpegSplitChaptersPP - Split video by chapters
class FFmpegSplitChaptersPP extends FFmpegPostProcessor {
  final bool forceKeyframes;

  FFmpegSplitChaptersPP({dynamic downloader, bool forceKeyframes = false})
      : forceKeyframes = forceKeyframes,
        super(downloader);

  String _prepareFilename(int number, Map<String, dynamic> chapter, Map<String, dynamic> info) {
    // Simplified - in full implementation would use downloader's prepare_filename
    final basePath = info['filepath'] as String? ?? '';
    final baseName = path.withoutExtension(basePath);
    final ext = path.extension(basePath);
    final title = chapter['title'] as String?;
    final titlePart = title != null ? ' - $title' : '';
    return '$baseName - Chapter $number$titlePart$ext';
  }

  List<String>? _ffmpegArgsForChapter(int number, Map<String, dynamic> chapter, Map<String, dynamic> info) {
    final destination = _prepareFilename(number, chapter, info);
    final dir = path.dirname(destination);
    final dirFile = Directory(dir);
    if (!dirFile.existsSync()) {
      dirFile.createSync(recursive: true);
    }

    chapter['filepath'] = destination;
    toScreen('Chapter ${number.toString().padLeft(3, '0')}; Destination: $destination');

    final startTime = (chapter['start_time'] as num?)?.toDouble() ?? 0.0;
    final endTime = (chapter['end_time'] as num?)?.toDouble() ?? 0.0;
    final duration = endTime - startTime;

    return ['-ss', startTime.toString(), '-t', duration.toString()];
  }

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    _fixupChapters(info);
    final chapters = info['chapters'] as List?;
    if (chapters == null || chapters.isEmpty) {
      toScreen('Chapter information is unavailable');
      return {'files_to_delete': [], 'info': info};
    }

    var inFile = info['filepath'] as String;

    // Force keyframes if needed (simplified - full implementation would re-encode)
    if (forceKeyframes && chapters.length > 1) {
      // In full implementation, would call force_keyframes method
      reportWarning('Force keyframes not fully implemented');
    }

    toScreen('Splitting video by chapters; ${chapters.length} chapters found');

    for (int idx = 0; idx < chapters.length; idx++) {
      final chapter = chapters[idx] as Map<String, dynamic>;
      final opts = _ffmpegArgsForChapter(idx + 1, chapter, info);
      if (opts != null) {
        final destination = chapter['filepath'] as String;
        final streamOpts = streamCopyOpts();
        final allOpts = <String>[
          ...opts,
          ...streamOpts.map((e) => e.toString()),
        ];
        await runFfmpeg(inFile, destination, allOpts);
      }
    }

    return {'files_to_delete': [], 'info': info};
  }

  void _fixupChapters(Map<String, dynamic> info) {
    final chapters = info['chapters'] as List?;
    if (chapters != null && chapters.isNotEmpty) {
      final lastChapter = chapters.last;
      if (lastChapter is Map<String, dynamic> && lastChapter['end_time'] == null) {
        final filepath = info['filepath'] as String?;
        if (filepath != null) {
          try {
            final duration = _getRealVideoDuration(filepath, fatal: false);
            if (duration != null) {
              lastChapter['end_time'] = duration;
            }
          } catch (e) {
            // Ignore
          }
        }
      }
    }
  }

  double? _getRealVideoDuration(String filePath, {bool fatal = true}) {
    try {
      final metadata = getMetadataObjectSync(filePath);
      final format = metadata['format'] as Map<String, dynamic>?;
      final duration = format?['duration'];
      if (duration == null) {
        throw PostProcessingError('ffprobe returned empty duration');
      }
      return double.tryParse(duration.toString());
    } catch (e) {
      if (fatal) {
        throw PostProcessingError('Unable to determine video duration: $e');
      }
      return null;
    }
  }
}

/// FFmpegThumbnailsConvertorPP - Convert thumbnail formats
class FFmpegThumbnailsConvertorPP extends FFmpegPostProcessor {
  static const supportedExts = ['jpg', 'png', 'webp', 'gif'];

  String? mapping;

  FFmpegThumbnailsConvertorPP({dynamic downloader, String? format})
      : mapping = format,
        super(downloader);

  List<String> _options(String targetExt) {
    final opts = <String>['-update', '1'];
    if (targetExt == 'jpg') {
      opts.addAll(['-bsf:v', 'mjpeg2jpeg']);
    }
    return opts;
  }

  Future<String> convertThumbnail(String thumbnailFilename, String targetExt) async {
    final thumbnailConvFilename = _replaceExtension(thumbnailFilename, targetExt);
    toScreen('Converting thumbnail "$thumbnailFilename" to $targetExt');

    final sourceExt = path.extension(thumbnailFilename).toLowerCase();
    final inputOpts = sourceExt == '.gif' ? <String>[] : <String>['-f', 'image2', '-pattern_type', 'none'];

    // Note: real_run_ffmpeg would be used here, simplified for now
    await runFfmpeg(thumbnailFilename, thumbnailConvFilename, [
      ...inputOpts,
      ..._options(targetExt),
    ]);

    return thumbnailConvFilename;
  }

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    final filesToDelete = <String>[];
    bool hasThumbnail = false;

    final thumbnails = info['thumbnails'] as List?;
    if (thumbnails != null) {
      for (int idx = 0; idx < thumbnails.length; idx++) {
        final thumbnailDict = thumbnails[idx] as Map<String, dynamic>;
        final originalThumbnail = thumbnailDict['filepath'] as String?;

        if (originalThumbnail == null) continue;
        hasThumbnail = true;

        var thumbnailExt = path.extension(originalThumbnail).toLowerCase();
        if (thumbnailExt.startsWith('.')) {
          thumbnailExt = thumbnailExt.substring(1);
        }
        if (thumbnailExt == 'jpeg') {
          thumbnailExt = 'jpg';
        }

        if (mapping == null) {
          continue;
        }

        final targetExt = resolveMapping(thumbnailExt, mapping!);
        if (targetExt == null) {
          toScreen('Not converting thumbnail "$originalThumbnail"; already in target format');
          continue;
        }

        thumbnailDict['filepath'] = await convertThumbnail(originalThumbnail, targetExt);
        filesToDelete.add(originalThumbnail);
      }
    }

    if (!hasThumbnail) {
      toScreen('There aren\'t any thumbnails to convert');
    }

    return {'files_to_delete': filesToDelete, 'info': info};
  }

  String _replaceExtension(String filepath, String newExt) {
    return path.setExtension(filepath, '.$newExt');
  }
}

/// FFmpegConcatPP - Concatenate multiple video files
class FFmpegConcatPP extends FFmpegPostProcessor {
  final bool onlyMultiVideo;

  FFmpegConcatPP({dynamic downloader, bool onlyMultiVideo = false})
      : onlyMultiVideo = onlyMultiVideo,
        super(downloader);

  List<String> _getCodecs(String file) {
    try {
      final metadata = getMetadataObjectSync(file);
      final streams = metadata['streams'] as List?;
      if (streams != null) {
        final codecs = streams.where((s) => s is Map && s['codec_name'] != null).map((s) => (s as Map)['codec_name'].toString()).toList();
        writeDebug('Codecs = ${codecs.join(", ")}');
        return codecs;
      }
    } catch (e) {
      // Ignore
    }
    return [];
  }

  Future<List<String>> concatFiles(List<String> inFiles, String outFile) async {
    final outDir = Directory(path.dirname(outFile));
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    if (inFiles.length == 1) {
      final inFile = File(inFiles[0]);
      final outFileObj = File(outFile);
      if (inFile.absolute.path != outFileObj.absolute.path) {
        toScreen('Moving "${inFiles[0]}" to "$outFile"');
      }
      await inFile.rename(outFile);
      return [];
    }

    // Check if all files have same codecs
    final codecSets = inFiles.map((f) => _getCodecs(f).toSet()).toList();
    if (codecSets.length > 1) {
      final firstSet = codecSets[0];
      for (int i = 1; i < codecSets.length; i++) {
        if (codecSets[i] != firstSet) {
          throw PostProcessingError('The files have different streams/codecs and cannot be concatenated. '
              'Either select different formats or --recode-video them to a common format');
        }
      }
    }

    toScreen('Concatenating ${inFiles.length} files; Destination: $outFile');

    // Create concat file
    final concatFile = '$outFile.concat';
    final concatContent = StringBuffer('ffconcat version 1.0\n');
    for (final file in inFiles) {
      final fileArg = _ffmpegFilenameArgument(file);
      concatContent.writeln('file $fileArg');
    }
    await File(concatFile).writeAsString(concatContent.toString());

    // Run ffmpeg concat
    final streamOpts = streamCopyOpts();
    final opts = <String>[
      '-hide_banner',
      '-nostdin',
      '-f',
      'concat',
      '-safe',
      '0',
      ...streamOpts.map((e) => e.toString()),
    ];

    await runFfmpeg(concatFile, outFile, opts);
    await File(concatFile).delete();

    return inFiles;
  }

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> info) async {
    final entries = info['entries'] as List? ?? [];
    if (entries.isEmpty || (onlyMultiVideo && info['_type'] != 'multi_video')) {
      return {'files_to_delete': [], 'info': info};
    }

    // Extract file paths from entries
    final inFiles = <String>[];
    for (final entry in entries) {
      if (entry is Map<String, dynamic>) {
        final requestedDownloads = entry['requested_downloads'] as List?;
        if (requestedDownloads != null && requestedDownloads.isNotEmpty) {
          final download = requestedDownloads[0];
          if (download is Map<String, dynamic>) {
            final filepath = download['filepath'] as String?;
            if (filepath != null) {
              inFiles.add(filepath);
            }
          }
        }
      }
    }

    if (inFiles.length < entries.length) {
      throw PostProcessingError('Aborting concatenation because some downloads failed');
    }

    // Determine output extension
    final exts = inFiles.map((f) => path.extension(f).substring(1)).toList();
    final ext = exts.toSet().length == 1 ? exts[0] : 'mkv';

    // Prepare output filename (simplified)
    final basePath = info['filepath'] as String? ?? 'output';
    final baseName = path.withoutExtension(basePath);
    final outFile = '$baseName.$ext';

    final filesToDelete = await concatFiles(inFiles, outFile);

    info['requested_downloads'] = [
      {'filepath': outFile, 'ext': ext}
    ];

    return {'files_to_delete': filesToDelete, 'info': info};
  }
}
