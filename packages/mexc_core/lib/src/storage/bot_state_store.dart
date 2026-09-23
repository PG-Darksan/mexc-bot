import 'dart:convert';
import 'dart:io';

import '../models/signal.dart';
import '../models/strategy_config.dart';

/// 設定と建玉の保存先。
abstract class BotStateStore {
  Future<StrategyConfig?> loadConfig();
  Future<void> saveConfig(StrategyConfig config);
  Future<List<ManagedPosition>> loadPositions();
  Future<void> savePositions(List<ManagedPosition> positions);
}

/// JSON ファイルに書き出す実装。サーバー常駐時に使う。
///
/// 取引所の API キーはここには入れない。サーバーでは権限 600 の
/// 環境変数ファイルから読む (systemd の EnvironmentFile)。
class FileBotStateStore implements BotStateStore {
  FileBotStateStore(this.directory);

  final Directory directory;

  File get _configFile => File('${directory.path}/config.json');
  File get _positionsFile => File('${directory.path}/positions.json');

  Future<void> _ensureDirectory() async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
  }

  @override
  Future<StrategyConfig?> loadConfig() async {
    try {
      if (!await _configFile.exists()) return null;
      final json = jsonDecode(await _configFile.readAsString());
      return StrategyConfig.fromJson((json as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveConfig(StrategyConfig config) async {
    await _ensureDirectory();
    await _configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
    );
  }

  @override
  Future<List<ManagedPosition>> loadPositions() async {
    try {
      if (!await _positionsFile.exists()) return const [];
      final json = jsonDecode(await _positionsFile.readAsString()) as List;
      return json
          .cast<Map<String, dynamic>>()
          .map(ManagedPosition.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> savePositions(List<ManagedPosition> positions) async {
    await _ensureDirectory();
    await _positionsFile.writeAsString(
      jsonEncode(positions.map((p) => p.toJson()).toList()),
    );
  }
}
