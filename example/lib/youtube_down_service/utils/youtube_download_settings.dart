import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../preferences_service.dart';

class Settings {
  const Settings();

  SettingsImpl copyWith({
    String? downloadPath,
    String? ffmpegContainer,
  }) =>
      throw UnimplementedError();

  String get ffmpegContainer => throw UnimplementedError();

  String get downloadPath => throw UnimplementedError();
}

class SettingsImpl implements Settings {
  final SharedPreferences _prefs = PreferencesService().getPrex();
  @override
  final String downloadPath;
  @override
  final String ffmpegContainer;

  SettingsImpl._(this.downloadPath, this.ffmpegContainer);

  @override
  SettingsImpl copyWith({
    String? downloadPath,
    String? ffmpegContainer,
  }) {
    if (downloadPath != null) {
      _prefs.setString('download_path', downloadPath);
    }

    if (ffmpegContainer != null) {
      _prefs.setString('ffmpeg_container', ffmpegContainer);
    }

    return SettingsImpl._(
      downloadPath ?? this.downloadPath,
      ffmpegContainer ?? this.ffmpegContainer,
    );
  }

  static Future<SettingsImpl> init() async {
    final prefs = PreferencesService().getPrex();
    var path = prefs.getString('download_path');
    if (path == null) {
      path = (await getDefaultDownloadDir()).path;
      prefs.setString('download_path', path);
    }
    var themeId = prefs.getInt('theme_id');
    if (themeId == null) {
      themeId = 0;
      prefs.setInt('theme_id', 0);
    }
    var ffmpegContainer = prefs.getString('ffmpeg_container');
    if (ffmpegContainer == null) {
      ffmpegContainer = '.mp4';
      prefs.setString('ffmpeg_container', '.mp4');
    }

    return SettingsImpl._(path, ffmpegContainer);
  }
}

Future<Directory> getDefaultDownloadDir() async {
  if (Platform.isAndroid) {
    final paths = await getExternalStorageDirectories(type: StorageDirectory.music);
    return paths!.first;
  }
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    final path = await getDownloadsDirectory();
    return path!;
  }
  if (Platform.isIOS) {
    final appDocDir = await getApplicationDocumentsDirectory();
    return appDocDir;
  }
  throw UnsupportedError('Platform: ${Platform.operatingSystem} is not supported!');
}
