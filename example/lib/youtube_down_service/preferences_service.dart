import 'package:shared_preferences/shared_preferences.dart';

/// Local [SharedPreferences] holder. Call [init] from `main()` before any code uses [getPrex].
class PreferencesService {
  PreferencesService._();
  static final PreferencesService _instance = PreferencesService._();
  factory PreferencesService() => _instance;

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  SharedPreferences getPrex() {
    final p = _prefs;
    if (p == null) {
      throw StateError(
        'PreferencesService.init() was not awaited before use. '
        'Call await PreferencesService().init() in main().',
      );
    }
    return p;
  }
}
