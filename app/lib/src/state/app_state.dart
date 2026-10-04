import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mexc_core/mexc_core.dart';

import '../data/account_data.dart';
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
/// ローカル実行とサーバー接続を同じ口 ([BotController]) で扱い、
/// 画面はこのクラスだけを見る。
class AppState extends ChangeNotifier {
  AppState(this._store, {TradeNotifier? notifier}) : _notifier = notifier;

  final SettingsStore _store;

  /// 建てた / 決済したときに端末の通知を出す。テストでは渡さない。
  final TradeNotifier? _notifier;
  final PositionChangeTracker _changes = PositionChangeTracker();

  AppSettings _settings = const AppSettings();
  StrategyConfig _config = const StrategyConfig();
  Credentials _credentials = const Credentials();
  BotController? _controller;
  BotSnapshot _snapshot = BotSnapshot.initial(const StrategyConfig());
  ControllerConnection _connection = ControllerConnection.disconnected;
  final List<BotEvent> _events = [];
  bool _initialized = false;
  String? _notice;

  StreamSubscription<BotSnapshot>? _snapshotSub;
  StreamSubscription<BotEvent>? _eventSub;
  StreamSubscription<ControllerConnection>? _connectionSub;
  Timer? _persistTimer;

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

  /// 残高だけを端末から直接取る口。ローカル実行で鍵があるときだけ持つ。
  AccountDataSource? _account;
  AccountAsset? _liveAsset;
  DateTime? _assetFetchedAt;
  String? _assetError;
  bool _refreshingAsset = false;

  /// 端末から取引所へ直接聞いた建玉と決済の記録。サーバーが返すのは
  /// ボットが建てた建玉だけなので、手で建てたものはこちらで拾う。
  List<PositionInfo> _exchangeOpen = const [];
  List<PositionInfo>? _exchangeClosed;
  Map<String, double> _lastPrices = const {};
  Map<String, double> _contractSizes = const {};
  String? _exchangeError;
  bool _refreshingExchange = false;
  Timer? _exchangeTimer;

  /// 取引所の建玉を取り直す間隔。
  static const Duration exchangeRefreshInterval = Duration(seconds: 30);

  static const int maxEvents = 500;

  AppSettings get settings => _settings;
  StrategyConfig get config => _config;
  Credentials get credentials => _credentials;
  BotSnapshot get snapshot => _snapshot;
  ControllerConnection get connection => _connection;
  List<BotEvent> get events => List.unmodifiable(_events.reversed);
  bool get initialized => _initialized;
  bool get isLocalMode => _settings.mode == RunMode.local;
  bool get isRunning => _snapshot.running;
  String? get notice => _notice ?? _store.secureStorageError;

  /// 画面に出す残高。端末で直接取ったものがあればそれを優先する。
  AccountAsset? get displayAsset => _liveAsset ?? _snapshot.asset;
  DateTime? get assetFetchedAt => _assetFetchedAt;
  String? get assetError => _assetError;
  bool get refreshingAsset => _refreshingAsset;

  /// ボットが管理していない、取引所にある建玉 (手で建てたものなど)。
  List<PositionInfo> get foreignPositions =>
      exchangeOnlyPositions(_snapshot.positions, _exchangeOpen);

  /// 取引所の決済の記録。端末から取れていなければ null。
  List<PositionInfo>? get exchangeClosed => _exchangeClosed;

  /// 端末から取引所へ聞けなかった理由。
  String? get exchangeError => _exchangeError;

  /// 銘柄の現在値。ボットのものが無ければ端末で取ったものを使う。
  double? lastPriceOf(String symbol) =>
      _snapshot.markPrices[symbol] ?? _lastPrices[symbol];

  double contractSizeOf(String symbol) => _contractSizes[symbol] ?? 1;

  Future<void> initialize() async {
    _settings = await _store.loadAppSettings();
    _config = await _store.loadStrategyConfig();
    _credentials = await _store.loadCredentials();
    _snapshot = BotSnapshot.initial(_config);
    _initialized = true;
    notifyListeners();
    await _notifier?.initialize();

    await _rebuildController();

    if (isLocalMode && _settings.wasRunning) {
      // 前回「停止」を押さずに終わった (閉じた・落ちた) ので、続きから動かす。
      // サーバー接続では、サーバーが自分で動き続けている。
      await start();
    } else if (_credentials.apiKey.isNotEmpty) {
      // 動かしていなくても、口座の中身は最初に一度見せる。
      await refreshAccount();
    }

    // ローカル実行の建玉は端末に残しておく。
    _persistTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_persistPositions());
    });
  }

  /// サーバー接続で、いまつながらない理由。分かっていなければ null。
  String? get connectionError {
    final controller = _controller;
    return controller is RemoteBotController ? controller.lastError : null;
  }

  /// 設定を直さないとつながらない状態か (トークン違いなど)。
  bool get connectionNeedsFix {
    final controller = _controller;
    return controller is RemoteBotController && controller.needsSettingsFix;
  }

  /// いまの設定でつなぎ直す。設定画面の「つなぎ直す」から呼ぶ。
  Future<void> reconnect() => _rebuildController();

  /// 実行モードやAPIキーが変わったらコントローラを作り直す。
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

    final BotController controller;
    if (_settings.mode == RunMode.local) {
      final local = LocalBotController(
        config: _config,
        apiKey: _credentials.apiKey.isEmpty ? null : _credentials.apiKey,
        apiSecret: _credentials.apiSecret.isEmpty
            ? null
            : _credentials.apiSecret,
      );
      local.restorePositions(await _store.loadPositions());
      controller = local;
    } else {
      controller = RemoteBotController(
        serverUrl: _settings.serverUrl,
        token: _settings.serverToken,
        initialConfig: _config,
      );
    }

    _controller = controller;
    _rebuildAccountSource();
    // 繋ぎ先が変わったので、建玉の覚えを取り直す (前からある分は知らせない)。
    _changes.reset();
    _snapshotSub = controller.snapshots.listen((s) {
      _snapshot = s;
      // サーバー側の設定を正とする。
      if (!controller.isLocal) _config = s.config;
      _notifyTrades(s);
      notifyListeners();
    });
    _eventSub = controller.events.listen(_addEvent);
    _connectionSub = controller.connectionState.listen((c) {
      _connection = c;
      notifyListeners();
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

  Future<void> start() async {
    await _controller?.start();
    await _rememberRunning(true);
    notifyListeners();
  }

  Future<void> stop() async {
    await _controller?.stop();
    await _rememberRunning(false);
    notifyListeners();
  }

  /// ローカル実行では「開始」から「停止」までを覚えておく。アプリを閉じたり
  /// 落ちたりしても、次に開いたとき続きから動かすため。
  /// サーバー接続ではサーバーが覚えているので、ここでは何もしない。
  Future<void> _rememberRunning(bool running) async {
    if (!isLocalMode || _settings.wasRunning == running) return;
    _settings = _settings.copyWith(wasRunning: running);
    await _store.saveAppSettings(_settings);
  }

  Future<void> closePosition(String id) async {
    await _controller?.closePosition(id);
  }

  /// 口座と建玉を取り直す。止まっていても使える。
  ///
  /// ローカル実行なら残高は端末が直接取る (待ち行列が別なので速い)。
  /// 建玉の突き合わせは裏でエンジンに頼む。サーバー接続では鍵が端末に
  /// 無いので、サーバーに頼むしかない。
  Future<void> refreshAccount() async {
    final account = _account;
    if (account == null) {
      await _controller?.refreshAccount();
      return;
    }
    if (_refreshingAsset) return;
    _refreshingAsset = true;
    _assetError = null;
    notifyListeners();
    try {
      _liveAsset = await account.fetchUsdt();
      _assetFetchedAt = DateTime.now();
    } catch (e) {
      _assetError = '$e';
    } finally {
      _refreshingAsset = false;
      notifyListeners();
    }
    final controller = _controller;
    if (controller != null) unawaited(controller.refreshAccount());
    unawaited(refreshExchange());
  }

  /// 取引所の建玉と決済の記録を、端末から直接取り直す。
  Future<void> refreshExchange() async {
    final account = _account;
    if (account == null || _refreshingExchange) return;
    _refreshingExchange = true;
    try {
      // 順に聞く (並べて聞くと、1 つが失敗したときに残りの失敗を拾い損ねる)。
      final results = (
        await account.fetchOpenPositions(),
        await account.fetchClosedPositions(),
        await account.fetchLastPrices(),
        await account.contractSizes(),
      );
      // 待っている間に鍵が変わっていたら、古い結果は捨てる。
      if (!identical(account, _account)) return;
      _exchangeOpen = results.$1;
      _exchangeClosed = results.$2;
      _lastPrices = results.$3;
      _contractSizes = results.$4;
      _exchangeError = null;
    } catch (e) {
      if (!identical(account, _account)) return;
      _exchangeError = '$e';
    } finally {
      _refreshingExchange = false;
      notifyListeners();
    }
  }

  /// 残高を直接取る口を、いまの動かし方と鍵に合わせて作り直す。
  void _rebuildAccountSource() {
    _account?.dispose();
    _account = null;
    _liveAsset = null;
    _assetFetchedAt = null;
    _assetError = null;
    _exchangeOpen = const [];
    _exchangeClosed = null;
    _exchangeError = null;
    _exchangeTimer?.cancel();
    _exchangeTimer = null;
    // サーバー接続でも、端末に鍵があれば残高・建玉・決済の記録は直接取る
    // (そのほうが速く、手で建てた建玉も見える)。
    if (!_credentials.isEmpty) {
      _account = AccountDataSource(
        apiKey: _credentials.apiKey,
        apiSecret: _credentials.apiSecret,
      );
      unawaited(refreshExchange());
      _exchangeTimer = Timer.periodic(exchangeRefreshInterval, (_) {
        unawaited(refreshExchange());
      });
    }
  }

  /// 決済済みの記録を消す。[id] が null なら全部。
  Future<void> clearHistory({String? id}) async {
    await _controller?.clearHistory(id: id);
    await _persistPositions();
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
    final modeChanged = settings.mode != _settings.mode;
    // 動かし方を変えるとローカルのボットは止まるので、続きから動かす印も消す。
    if (modeChanged) settings = settings.copyWith(wasRunning: false);
    final connectionChanged =
        settings.serverUrl != _settings.serverUrl ||
        settings.serverToken != _settings.serverToken;
    _settings = settings;
    await _store.saveAppSettings(settings);
    notifyListeners();
    if (modeChanged || (settings.mode == RunMode.remote && connectionChanged)) {
      await _rebuildController();
    }
  }

  Future<void> updateCredentials(Credentials credentials) async {
    _credentials = credentials;
    final ok = await _store.saveCredentials(credentials);
    if (!ok) {
      _notice = _store.secureStorageError;
    }
    notifyListeners();
    // ローカル実行では APIキーをエンジンに渡し直す必要がある。
    // サーバー接続では、残高を直接取る口だけ作り直す。
    if (_settings.mode == RunMode.local) {
      await _rebuildController();
    } else {
      _rebuildAccountSource();
      notifyListeners();
    }
    // キーを入れたら、止まっていてもすぐ残高を見に行く。
    if (credentials.apiKey.isNotEmpty && credentials.apiSecret.isNotEmpty) {
      await refreshAccount();
    }
  }

  Future<void> clearCredentials() async {
    await _store.clearCredentials();
    _credentials = const Credentials();
    notifyListeners();
    if (_settings.mode == RunMode.local) {
      await _rebuildController();
    } else {
      _rebuildAccountSource();
      notifyListeners();
    }
  }

  void dismissNotice() {
    _notice = null;
    notifyListeners();
  }

  Future<void> _persistPositions() async {
    final controller = _controller;
    if (controller is! LocalBotController) return;
    await _store.savePositions(controller.engine.allPositions);
  }

  /// アプリを終わらせる前の後片付け。建玉を保存し、接続を閉じる。
  Future<void> shutdown() async {
    _persistTimer?.cancel();
    _exchangeTimer?.cancel();
    await _persistPositions();
    await _snapshotSub?.cancel();
    await _eventSub?.cancel();
    await _connectionSub?.cancel();
    await _controller?.dispose();
    _controller = null;
  }

  @override
  Future<void> dispose() async {
    chartRequest.dispose();
    _account?.dispose();
    _persistTimer?.cancel();
    _exchangeTimer?.cancel();
    await _persistPositions();
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
