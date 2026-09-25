import 'dart:async';

import '../engine/bot_engine.dart';
import '../models/bot_event.dart';
import '../models/signal.dart';
import '../models/strategy_config.dart';

/// 接続状態。
enum ControllerConnection { disconnected, connecting, connected, error }

/// 画面から見た「ボットの操作口」。
///
/// ローカル実行 ([LocalBotController]) でも、Oracle Cloud のサーバーに
/// つなぐ場合 ([RemoteBotController]) でも、UI 側は同じ口だけを見る。
abstract class BotController {
  Stream<BotSnapshot> get snapshots;
  Stream<BotEvent> get events;
  Stream<ControllerConnection> get connectionState;

  BotSnapshot get snapshot;
  ControllerConnection get connection;

  /// ローカル実行かどうか。画面の表示切り替えに使う。
  bool get isLocal;

  Future<void> connect();
  Future<void> start();
  Future<void> stop();
  Future<void> updateConfig(StrategyConfig config);
  Future<void> closePosition(String id);

  /// 決済済みの記録を消す。[id] が null なら全部。
  Future<void> clearHistory({String? id});

  /// 建玉の利確 / 損切りラインを置き直す。
  Future<void> updatePositionExit(
    String id, {
    double? takeProfitPrice,
    double? stopLossPrice,
    bool clearStopLoss = false,
  });

  Future<void> dispose();
}

/// アプリの中で直接ボットを動かす実装。
///
/// サーバーを使わずに端末だけで完結させたいときに使う。
class LocalBotController implements BotController {
  LocalBotController({
    required StrategyConfig config,
    String? apiKey,
    String? apiSecret,
    BotEngine? engine,
  }) : _engine =
           engine ??
           BotEngine(config: config, apiKey: apiKey, apiSecret: apiSecret);

  final BotEngine _engine;
  final _connectionController =
      StreamController<ControllerConnection>.broadcast();
  ControllerConnection _connection = ControllerConnection.disconnected;

  BotEngine get engine => _engine;

  @override
  bool get isLocal => true;

  @override
  Stream<BotSnapshot> get snapshots => _engine.snapshots;

  @override
  Stream<BotEvent> get events => _engine.events;

  @override
  Stream<ControllerConnection> get connectionState =>
      _connectionController.stream;

  @override
  BotSnapshot get snapshot => _engine.snapshot;

  @override
  ControllerConnection get connection => _connection;

  @override
  Future<void> connect() async {
    _setConnection(ControllerConnection.connected);
  }

  @override
  Future<void> start() => _engine.start();

  @override
  Future<void> stop() => _engine.stop();

  @override
  Future<void> updateConfig(StrategyConfig config) =>
      _engine.updateConfig(config);

  @override
  Future<void> closePosition(String id) => _engine.closePositionManually(id);

  @override
  Future<void> clearHistory({String? id}) async =>
      _engine.clearHistory(id: id);

  @override
  Future<void> updatePositionExit(
    String id, {
    double? takeProfitPrice,
    double? stopLossPrice,
    bool clearStopLoss = false,
  }) => _engine.updatePositionExit(
    id,
    takeProfitPrice: takeProfitPrice,
    stopLossPrice: stopLossPrice,
    clearStopLoss: clearStopLoss,
  );

  /// 保存済みの建玉を復元する。
  void restorePositions(Iterable<ManagedPosition> positions) =>
      _engine.restorePositions(positions);

  void _setConnection(ControllerConnection state) {
    _connection = state;
    if (!_connectionController.isClosed) _connectionController.add(state);
  }

  @override
  Future<void> dispose() async {
    await _engine.dispose();
    await _connectionController.close();
  }
}
