import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mexc_core/mexc_core.dart';

import '../data/account_data.dart';
import '../settings/app_settings.dart';
import '../settings/settings_store.dart';

/// アプリ全体の状態。
///
/// ローカル実行とサーバー接続を同じ口 ([BotController]) で扱い、
/// 画面はこのクラスだけを見る。
class AppState extends ChangeNotifier {
  AppState(this._store);

  final SettingsStore _store;

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

  /// 残高だけを端末から直接取る口。ローカル実行で鍵があるときだけ持つ。
  AccountDataSource? _account;
  AccountAsset? _liveAsset;
  DateTime? _assetFetchedAt;
  String? _assetError;
  bool _refreshingAsset = false;

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

  Future<void> initialize() async {
    _settings = await _store.loadAppSettings();
    _config = await _store.loadStrategyConfig();
    _credentials = await _store.loadCredentials();
    _snapshot = BotSnapshot.initial(_config);
    _initialized = true;
    notifyListeners();

    await _rebuildController();

    if (_settings.autoStartBot) {
      await start();
    } else if (_credentials.apiKey.isNotEmpty) {
      // 起動しない設定でも、口座の中身は最初に一度見せる。
      await refreshAccount();
    }

    // ローカル実行の建玉は端末に残しておく。
    _persistTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_persistPositions());
    });
  }

  /// 実行モードやAPIキーが変わったらコントローラを作り直す。
  Future<void> _rebuildController() async {
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
        allowSelfSignedCertificate: _settings.allowSelfSignedCertificate,
        initialConfig: _config,
      );
    }

    _controller = controller;
    _rebuildAccountSource();
    _snapshotSub = controller.snapshots.listen((s) {
      _snapshot = s;
      // サーバー側の設定を正とする。
      if (!controller.isLocal) _config = s.config;
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
  }

  /// 残高を直接取る口を、いまの動かし方と鍵に合わせて作り直す。
  void _rebuildAccountSource() {
    _account?.dispose();
    _account = null;
    _liveAsset = null;
    _assetFetchedAt = null;
    _assetError = null;
    // サーバー接続でも、端末に鍵があれば残高だけは直接取れる (そのほうが速い)。
    if (!_credentials.isEmpty) {
      _account = AccountDataSource(
        apiKey: _credentials.apiKey,
        apiSecret: _credentials.apiSecret,
      );
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
    final connectionChanged =
        settings.serverUrl != _settings.serverUrl ||
        settings.serverToken != _settings.serverToken ||
        settings.allowSelfSignedCertificate !=
            _settings.allowSelfSignedCertificate;
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
    await _persistPositions();
    await _snapshotSub?.cancel();
    await _eventSub?.cancel();
    await _connectionSub?.cancel();
    await _controller?.dispose();
    _controller = null;
  }

  @override
  Future<void> dispose() async {
    _account?.dispose();
    _persistTimer?.cancel();
    await _persistPositions();
    await _snapshotSub?.cancel();
    await _eventSub?.cancel();
    await _connectionSub?.cancel();
    await _controller?.dispose();
    super.dispose();
  }
}
