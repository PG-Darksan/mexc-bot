import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mexc_core/mexc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';

/// 取引所の APIキーと接続トークン。
class Credentials {
  const Credentials({this.apiKey = '', this.apiSecret = ''});

  final String apiKey;
  final String apiSecret;

  bool get isEmpty => apiKey.isEmpty || apiSecret.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// 設定の保存先。
///
/// * 売買パラメーターや画面設定は shared_preferences。
/// * 取引所の APIキーだけは flutter_secure_storage に置く。
///   ただし Windows 版は「同じユーザーで動く他プロセスからは読める」程度の
///   保護しかない点に注意 (OS のサンドボックス分離は期待できない)。
class SettingsStore {
  SettingsStore({FlutterSecureStorage? secureStorage})
    : _secure =
          secureStorage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  static const _keyAppSettings = 'app_settings_v1';
  static const _keyStrategyConfig = 'strategy_config_v1';
  static const _keyPositions = 'positions_v1';
  static const _keyApiKey = 'mexc_api_key';
  static const _keyApiSecret = 'mexc_api_secret';

  final FlutterSecureStorage _secure;

  /// セキュアストレージが使えなかったときの理由。UI に出して知らせる。
  String? secureStorageError;

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

  Future<List<ManagedPosition>> loadPositions() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_keyPositions);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(ManagedPosition.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> savePositions(List<ManagedPosition> positions) async {
    final prefs = await _prefs;
    // 直近 300 件だけ残す。
    final trimmed = positions.length > 300
        ? positions.sublist(positions.length - 300)
        : positions;
    await prefs.setString(
      _keyPositions,
      jsonEncode(trimmed.map((p) => p.toJson()).toList()),
    );
  }

  Future<Credentials> loadCredentials() async {
    try {
      final key = await _secure.read(key: _keyApiKey) ?? '';
      final secret = await _secure.read(key: _keyApiSecret) ?? '';
      secureStorageError = null;
      return Credentials(apiKey: key, apiSecret: secret);
    } catch (e) {
      secureStorageError = 'APIキーの保管領域を開けませんでした ($e)。キーは今回の起動中だけ保持されます。';
      return const Credentials();
    }
  }

  Future<bool> saveCredentials(Credentials credentials) async {
    try {
      await _secure.write(key: _keyApiKey, value: credentials.apiKey);
      await _secure.write(key: _keyApiSecret, value: credentials.apiSecret);
      secureStorageError = null;
      return true;
    } catch (e) {
      secureStorageError = 'APIキーを保存できませんでした ($e)。';
      return false;
    }
  }

  Future<void> clearCredentials() async {
    try {
      await _secure.delete(key: _keyApiKey);
      await _secure.delete(key: _keyApiSecret);
    } catch (_) {}
  }
}
