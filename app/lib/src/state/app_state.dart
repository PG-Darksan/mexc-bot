import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mexc_core/mexc_core.dart';

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
        apiSecret:
            _credentials.apiSecret.isEmpty ? null : _credentials.apiSecret,
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
    final connectionChanged = settings.serverUrl != _settings.serverUrl ||
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
    if (_settings.mode == RunMode.local) {
      await _rebuildController();
    }
  }

  Future<void> clearCredentials() async {
    await _store.clearCredentials();
    _credentials = const Credentials();
    notifyListeners();
    if (_settings.mode == RunMode.local) {
      await _rebuildController();
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
    _persistTimer?.cancel();
    await _persistPositions();
    await _snapshotSub?.cancel();
    await _eventSub?.cancel();
    await _connectionSub?.cancel();
    await _controller?.dispose();
    super.dispose();
  }
}
