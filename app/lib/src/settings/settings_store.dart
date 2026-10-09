import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mexc_core/mexc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/chart_drawing.dart';
import 'app_settings.dart';

/// 設定の保存先。
///
/// 売買パラメーターや画面設定は shared_preferences に置く。取引所の鍵は
/// サーバーだけが持つので、端末には置かない。
class SettingsStore {
  SettingsStore({FlutterSecureStorage? secureStorage})
    : _secure =
          secureStorage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  static const _keyAppSettings = 'app_settings_v1';
  static const _keyStrategyConfig = 'strategy_config_v1';
  static const _keyLockUntil = 'app_lock_until_v1';
  static const _keyDrawings = 'chart_drawings_v1';

  // 以前の版 (ローカル実行があった頃) に使っていた所。消すためだけに残す。
  static const _keyPositions = 'positions_v1';
  static const _keyApiKey = 'mexc_api_key';
  static const _keyApiSecret = 'mexc_api_secret';

  final FlutterSecureStorage _secure;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<AppSettings> loadAppSettings() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_keyAppSettings);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> saveAppSettings(AppSettings settings) async {
    final prefs = await _prefs;
    await prefs.setString(_keyAppSettings, jsonEncode(settings.toJson()));
  }

  Future<StrategyConfig> loadStrategyConfig() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_keyStrategyConfig);
    if (raw == null) return const StrategyConfig();
    try {
      return StrategyConfig.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return const StrategyConfig();
    }
  }

  Future<void> saveStrategyConfig(StrategyConfig config) async {
    final prefs = await _prefs;
    await prefs.setString(_keyStrategyConfig, jsonEncode(config.toJson()));
  }

  /// アプリのロックが解けるまでの時刻。ロックしていなければ null。
  Future<DateTime?> loadLockUntil() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_keyLockUntil);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> saveLockUntil(DateTime? until) async {
    final prefs = await _prefs;
    if (until == null) {
      await prefs.remove(_keyLockUntil);
    } else {
      await prefs.setString(_keyLockUntil, until.toIso8601String());
    }
  }

  /// チャートに自分で引いた線 (銘柄ごと)。
  Future<Map<String, List<ChartDrawing>>> loadDrawings() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_keyDrawings);
    if (raw == null) return {};
    try {
      final json = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return {
        for (final e in json.entries)
          e.key: [
            for (final d in (e.value as List? ?? const []).whereType<Map>())
              ?ChartDrawing.fromJson(d.cast<String, dynamic>()),
          ],
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> saveDrawings(Map<String, List<ChartDrawing>> drawings) async {
    final prefs = await _prefs;
    await prefs.setString(
      _keyDrawings,
      jsonEncode({
        for (final e in drawings.entries)
          if (e.value.isNotEmpty)
            e.key: [for (final d in e.value) d.toJson()],
      }),
    );
  }

  /// 以前の版で端末に残した取引所の鍵と、ローカル実行の建玉を消す。
  ///
  /// ボットはサーバーで動かすので、もう使わない。鍵を端末に残しておく
  /// 理由が無いので、見つけたら消す。消せなくても困らないので黙って続ける。
  Future<void> clearCredentials() async {
    try {
      await _secure.delete(key: _keyApiKey);
      await _secure.delete(key: _keyApiSecret);
    } catch (_) {}
    try {
      final prefs = await _prefs;
      await prefs.remove(_keyPositions);
    } catch (_) {}
  }
}
