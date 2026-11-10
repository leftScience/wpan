import 'package:shared_preferences/shared_preferences.dart';

/// Persists the player choices the user makes in the settings sheet
/// (stream mode, decode mode, playback rate) so the next session starts from
/// the same configuration instead of resetting to the server default every time.
class PlayerPreferencesStorage {
  PlayerPreferencesStorage({String keyPrefix = 'player_preferences_'})
    : _keyPrefix = keyPrefix;

  final String _keyPrefix;
  SharedPreferences? _prefs;

  Future<SharedPreferences> _instance() async {
    final cached = _prefs;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    return prefs;
  }

  String _key(String name) => '$_keyPrefix$name';

  Future<String?> readProxyMode() async {
    final prefs = await _instance();
    final raw = (prefs.getString(_key('proxy_mode')) ?? '').trim();
    return raw.isEmpty ? null : raw;
  }

  Future<void> saveProxyMode(String? mode) async {
    final prefs = await _instance();
    final normalized = (mode ?? '').trim();
    if (normalized.isEmpty) {
      await prefs.remove(_key('proxy_mode'));
    } else {
      await prefs.setString(_key('proxy_mode'), normalized);
    }
  }

  Future<String?> readDecodeMode() async {
    final prefs = await _instance();
    final raw = (prefs.getString(_key('decode_mode')) ?? '').trim();
    return raw.isEmpty ? null : raw;
  }

  Future<void> saveDecodeMode(String? mode) async {
    final prefs = await _instance();
    final normalized = (mode ?? '').trim();
    if (normalized.isEmpty) {
      await prefs.remove(_key('decode_mode'));
    } else {
      await prefs.setString(_key('decode_mode'), normalized);
    }
  }

  Future<double?> readPlaybackRate() async {
    final prefs = await _instance();
    final value = prefs.getDouble(_key('playback_rate'));
    if (value == null || value <= 0) return null;
    return value;
  }

  Future<void> savePlaybackRate(double? rate) async {
    final prefs = await _instance();
    if (rate == null || rate <= 0) {
      await prefs.remove(_key('playback_rate'));
    } else {
      await prefs.setDouble(_key('playback_rate'), rate);
    }
  }
}
