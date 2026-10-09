import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mexc_core/mexc_core.dart';

import '../data/chart_drawing.dart';
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

  /// 前に届いた状態で、ボットが動いていたか。繋いだ直後は null (知らせない)。
  bool? _lastRunning;

  AppSettings _settings = const AppSettings();
  StrategyConfig _config = const StrategyConfig();
  RemoteBotController? _controller;
  BotSnapshot _snapshot = BotSnapshot.initial(const StrategyConfig());
  ControllerConnection _connection = ControllerConnection.disconnected;
  final List<BotEvent> _events = [];
  bool _initialized = false;
  bool _refreshingAccount = false;

  /// アプリのロックが解ける時刻。ロックしていなければ null。
  DateTime? _lockUntil;
  Timer? _lockTimer;

  /// チャートに自分で引いた線 (銘柄ごと)。
  Map<String, List<ChartDrawing>> _drawings = {};

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

  /// サーバーにつながっているか。
  bool get connected => _connection == ControllerConnection.connected;

  /// [symbol] について取引所に出ている注文 (指値 / 条件付き)。
  List<ExchangeOrder> openOrdersOf(String symbol) => [
    for (final o in _snapshot.openOrders ?? const <ExchangeOrder>[])
      if (o.symbol == symbol) o,
  ];

  /// [symbol] の、条件付き注文に付けた利確 / 損切りの予約。
  List<PendingExit> pendingExitsOf(String symbol) => [
    for (final e in _snapshot.pendingExits)
      if (e.symbol == symbol) e,
  ];

  /// [symbol] の取引所の建玉 (ボットのものも手で建てたものも)。
  List<PositionInfo> exchangePositionsOf(String symbol) => [
    for (final p in _snapshot.exchangePositions ?? const <PositionInfo>[])
      if (p.symbol == symbol && p.holdVol > 0) p,
  ];

  // ── アプリのロック ─────────────────────────────────────────

  /// ロックが解ける時刻。ロックしていなければ null。
  DateTime? get lockUntil => _lockUntil;

  /// いまロックしているか。
  bool get isLocked =>
      _lockUntil != null && DateTime.now().isBefore(_lockUntil!);

  /// [until] までアプリをロックする (チャートや値段を見えなくする)。
  Future<void> lockUntilTime(DateTime until) async {
    _lockUntil = until;
    _scheduleUnlock();
    notifyListeners();
    await _store.saveLockUntil(until);
  }

  /// ロックを解く (時間が来たときと、長押しで解いたとき)。
  Future<void> unlock() async {
    _lockTimer?.cancel();
    _lockTimer = null;
    _lockUntil = null;
    notifyListeners();
    await _store.saveLockUntil(null);
  }

  void _scheduleUnlock() {
    _lockTimer?.cancel();
    final until = _lockUntil;
    if (until == null) return;
    final left = until.difference(DateTime.now());
    if (left <= Duration.zero) {
      _lockUntil = null;
      unawaited(_store.saveLockUntil(null));
      return;
    }
    _lockTimer = Timer(left, () {
      _lockUntil = null;
      notifyListeners();
      unawaited(_store.saveLockUntil(null));
    });
  }

  // ── チャートに引いた線 ─────────────────────────────────────

  List<ChartDrawing> drawingsOf(String symbol) =>
      List.unmodifiable(_drawings[symbol] ?? const <ChartDrawing>[]);

  Future<void> setDrawings(String symbol, List<ChartDrawing> drawings) async {
    _drawings = {..._drawings, symbol: List.of(drawings)};
    notifyListeners();
    await _store.saveDrawings(_drawings);
  }

  // ── 手で出す注文 ─────────────────────────────────────────

  BotController get _requireController {
    final controller = _controller;
    if (controller == null) {
      throw const RemoteCommandException('サーバーの設定がありません。設定タブで入れて下さい。');
    }
    return controller;
  }

  /// 手で新規注文を出す。出せたらサーバーからの説明を返す。
  Future<String> placeManualOrder(ManualOrderRequest request) =>
      _requireController.placeManualOrder(request);

  /// 取引所に出ている注文を取り消す。
  Future<void> cancelExchangeOrder(ExchangeOrder order) =>
      _requireController.cancelExchangeOrder(
        symbol: order.symbol,
        orderId: order.id,
        trigger: order.kind == ExchangeOrderKind.trigger,
      );

  /// ボットが管理していない建玉に利確 / 損切りを置く。
  Future<void> updateExchangePositionExit({
    required int positionId,
    double? takeProfitPrice,
    double? stopLossPrice,
  }) => _requireController.updateExchangePositionExit(
    positionId: positionId,
    takeProfitPrice: takeProfitPrice,
    stopLossPrice: stopLossPrice,
  );

  /// ボットが管理していない建玉を成行で閉じる。
  Future<void> closeExchangePosition(int positionId) =>
      _requireController.closeExchangePosition(positionId);

  Future<void> initialize() async {
    _settings = await _store.loadAppSettings();
    _config = await _store.loadStrategyConfig();
    _lockUntil = await _store.loadLockUntil();
    _scheduleUnlock();
    _drawings = await _store.loadDrawings();
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
    _lastRunning = null;
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

  /// 建てた / 決済したこと、ボットが動き出した / 止まったことを、端末の
  /// 通知で知らせる。
  void _notifyTrades(BotSnapshot snapshot) {
    final wasRunning = _lastRunning;
    _lastRunning = snapshot.running;
    final notifier = _notifier;
    // サーバーが ntfy で送っているなら、アプリでは出さない (二重に届くため)。
    if (notifier == null || snapshot.pushTopic != null) {
      _changes.update(snapshot);
      return;
    }
    if (wasRunning != null && wasRunning != snapshot.running) {
      unawaited(notifier.show(runningMessage(snapshot.running)));
    }
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
    _lockTimer?.cancel();
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
    _lockTimer?.cancel();
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
