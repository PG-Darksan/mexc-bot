import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mexc_core/mexc_core.dart';

import '../notify/trade_notifier.dart';
import '../settings/app_settings.dart';
import '../settings/settings_store.dart';

/// 「この銘柄のチャートを見せて」という画面またぎの依頼。
///
/// 同じ銘柄を続けて頼まれても届くように、通し番号を付ける。
class ChartRequest {
  const ChartRequest(this.symbol, this.serial);

  final String symbol;
  final int serial;
}

/// アプリ全体の状態。
///
/// ボットはサーバーで動かし、アプリはサーバーにつないで見る・操作するだけ。
/// 残高・建玉・決済の記録もサーバーが取引所から取って返す (端末は取引所の
/// 鍵を持たない)。画面はこのクラスだけを見る。
class AppState extends ChangeNotifier {
  AppState(this._store, {TradeNotifier? notifier}) : _notifier = notifier;

  final SettingsStore _store;

  /// 建てた / 決済したときに端末の通知を出す。テストでは渡さない。
  final TradeNotifier? _notifier;
  final PositionChangeTracker _changes = PositionChangeTracker();

  AppSettings _settings = const AppSettings();
  StrategyConfig _config = const StrategyConfig();
  RemoteBotController? _controller;
  BotSnapshot _snapshot = BotSnapshot.initial(const StrategyConfig());
  ControllerConnection _connection = ControllerConnection.disconnected;
  final List<BotEvent> _events = [];
  bool _initialized = false;
  bool _refreshingAccount = false;

  StreamSubscription<BotSnapshot>? _snapshotSub;
  StreamSubscription<BotEvent>? _eventSub;
  StreamSubscription<ControllerConnection>? _connectionSub;
  Timer? _refreshTimer;

  /// 止まっている間に、口座と建玉をサーバーに取り直してもらう間隔。
  /// 動いている間はサーバーが判定のたびに取り直すので頼まない。
  static const Duration accountRefreshInterval = Duration(seconds: 30);

  /// 銘柄一覧などからチャートを開く依頼。ホームとチャートが聞いている。
  final ValueNotifier<ChartRequest?> chartRequest = ValueNotifier(null);
  int _chartRequestSerial = 0;

  /// [symbol] のチャートをホームで開くよう頼む。
  void openChart(String symbol) {
    _chartRequestSerial++;
    chartRequest.value = ChartRequest(symbol, _chartRequestSerial);
  }

  /// 作り直しを 1 本に並べるための鎖。
  ///
  /// 設定を続けて変えると作り直しが重なり、古い口が新しい口の
  /// 購読を上書きして「つないだのに未接続のまま」になる。順番に流す。
  Future<void> _rebuildChain = Future<void>.value();

  static const int maxEvents = 500;

  AppSettings get settings => _settings;
  StrategyConfig get config => _config;
  BotSnapshot get snapshot => _snapshot;
  ControllerConnection get connection => _connection;
  List<BotEvent> get events => List.unmodifiable(_events.reversed);
  bool get initialized => _initialized;
  bool get isRunning => _snapshot.running;

  /// 画面に出す残高 (サーバーが取引所から取ったもの)。
  AccountAsset? get displayAsset => _snapshot.asset;
  bool get refreshingAsset => _refreshingAccount;

  /// ボットが管理していない、取引所にある建玉 (手で建てたものなど)。
  List<PositionInfo> get foreignPositions => exchangeOnlyPositions(
    _snapshot.positions,
    _snapshot.exchangePositions ?? const [],
  );

  /// 取引所の決済の記録。サーバーがまだ返していなければ null。
  List<PositionInfo>? get exchangeClosed => _snapshot.exchangeClosed;

  /// 銘柄の現在値。
  double? lastPriceOf(String symbol) => _snapshot.markPrices[symbol];

  /// 1 枚あたりの数量。評価損益の計算に使う。
  double contractSizeOf(String symbol) => _snapshot.contractSizes[symbol] ?? 1;

  Future<void> initialize() async {
    _settings = await _store.loadAppSettings();
    _config = await _store.loadStrategyConfig();
    _snapshot = BotSnapshot.initial(_config);
    _initialized = true;
    notifyListeners();
    // 以前の版で端末に保存した取引所の鍵。いまは使わないので消しておく。
    unawaited(_store.clearCredentials());
    await _notifier?.initialize();

    await _rebuildController();

    _refreshTimer = Timer.periodic(accountRefreshInterval, (_) {
      if (_connection == ControllerConnection.connected && !isRunning) {
        unawaited(_controller?.refreshAccount());
      }
    });
  }

  /// サーバーに、いまつながらない理由。分かっていなければ null。
  String? get connectionError => _controller?.lastError;

  /// 設定を直さないとつながらない状態か (トークン違いなど)。
  bool get connectionNeedsFix => _controller?.needsSettingsFix ?? false;

  /// いまの設定でつなぎ直す。設定画面の「つなぎ直す」から呼ぶ。
  Future<void> reconnect() => _rebuildController();

  /// 接続先が変わったらコントローラを作り直す。
  ///
  /// 重ねて呼ばれても順番に 1 つずつ実行する。
  Future<void> _rebuildController() {
    final next = _rebuildChain.then((_) => _doRebuildController());
    // 失敗しても鎖は続ける (次の作り直しが止まらないように)。
    _rebuildChain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _doRebuildController() async {
    await _snapshotSub?.cancel();
    await _eventSub?.cancel();
    await _connectionSub?.cancel();
    final old = _controller;
    _controller = null;
    if (old != null) {
      await old.dispose();
    }

    final controller = RemoteBotController(
      serverUrl: _settings.serverUrl,
      token: _settings.serverToken,
      initialConfig: _config,
    );
    _controller = controller;
    // 繋ぎ先が変わったので、建玉の覚えを取り直す (前からある分は知らせない)。
    _changes.reset();
    _snapshotSub = controller.snapshots.listen((s) {
      _snapshot = s;
      // サーバー側の設定を正とする。
      _config = s.config;
      _notifyTrades(s);
      notifyListeners();
    });
    _eventSub = controller.events.listen(_addEvent);
    _connectionSub = controller.connectionState.listen((c) {
      final connectedNow =
          c == ControllerConnection.connected && _connection != c;
      _connection = c;
      notifyListeners();
      // つながったら、残高と建玉 (手で建てたものも) を取り直してもらう。
      if (connectedNow) unawaited(controller.refreshAccount());
    });

    _snapshot = controller.snapshot;
    _connection = controller.connection;
    notifyListeners();

    await controller.connect();
  }

  void _addEvent(BotEvent event) {
    _events.add(event);
    if (_events.length > maxEvents) {
      _events.removeRange(0, _events.length - maxEvents);
    }
    notifyListeners();
  }

  /// 建てた / 決済したことを、端末の通知で知らせる。
  void _notifyTrades(BotSnapshot snapshot) {
    final notifier = _notifier;
    if (notifier == null) return;
    final changes = _changes.update(snapshot);
    for (final p in changes.opened) {
      unawaited(notifier.show(openedMessage(p)));
    }
    for (final p in changes.closed) {
      unawaited(notifier.show(closedMessage(p)));
    }
  }

  /// サーバーのボットを動かす。「停止」を押すまで、アプリを閉じても動き続ける。
  Future<void> start() async {
    await _controller?.start();
    notifyListeners();
  }

  Future<void> stop() async {
    await _controller?.stop();
    notifyListeners();
  }

  Future<void> closePosition(String id) async {
    await _controller?.closePosition(id);
  }

  /// 残高・建玉・決済の記録を、サーバーに取引所から取り直してもらう。
  /// 止まっていても使える。
  Future<void> refreshAccount() async {
    final controller = _controller;
    if (controller == null || _refreshingAccount) return;
    _refreshingAccount = true;
    notifyListeners();
    try {
      await controller.refreshAccount();
    } finally {
      _refreshingAccount = false;
      notifyListeners();
    }
  }

  /// 決済済みの記録を消す。[id] が null なら全部。
  Future<void> clearHistory({String? id}) async {
    await _controller?.clearHistory(id: id);
  }

  /// 建玉の利確 / 損切りラインを置き直す。
  Future<void> updatePositionExit(
    String id, {
    double? takeProfitPrice,
    double? stopLossPrice,
    bool clearStopLoss = false,
  }) async {
    await _controller?.updatePositionExit(
      id,
      takeProfitPrice: takeProfitPrice,
      stopLossPrice: stopLossPrice,
      clearStopLoss: clearStopLoss,
    );
  }

  Future<void> updateStrategyConfig(StrategyConfig config) async {
    _config = config;
    await _store.saveStrategyConfig(config);
    await _controller?.updateConfig(config);
    notifyListeners();
  }

  Future<void> updateAppSettings(AppSettings settings) async {
    final connectionChanged =
        settings.serverUrl != _settings.serverUrl ||
        settings.serverToken != _settings.serverToken;
    _settings = settings;
    await _store.saveAppSettings(settings);
    notifyListeners();
    if (connectionChanged) await _rebuildController();
  }

  /// アプリを終わらせる前の後片付け。接続を閉じる (ボットはサーバーで動き続ける)。
  Future<void> shutdown() async {
    _refreshTimer?.cancel();
    await _snapshotSub?.cancel();
    await _eventSub?.cancel();
    await _connectionSub?.cancel();
    await _controller?.dispose();
    _controller = null;
  }

  @override
  Future<void> dispose() async {
    chartRequest.dispose();
    _refreshTimer?.cancel();
    await _snapshotSub?.cancel();
    await _eventSub?.cancel();
    await _connectionSub?.cancel();
    await _controller?.dispose();
    super.dispose();
  }
}

/// 取引所の建玉のうち、ボットが管理していないもの。
///
/// 銘柄と向きが同じボットの建玉があれば、それと同じものとみなす
/// (一方向モードなので、同じ銘柄・同じ向きの建玉は 1 つしかない)。
List<PositionInfo> exchangeOnlyPositions(
  List<ManagedPosition> managed,
  List<PositionInfo> exchange,
) {
  final known = {
    for (final p in managed) '${p.symbol}|${p.direction.positionType}',
  };
  return [
    for (final p in exchange)
      if (!known.contains('${p.symbol}|${p.positionType}')) p,
  ];
}
