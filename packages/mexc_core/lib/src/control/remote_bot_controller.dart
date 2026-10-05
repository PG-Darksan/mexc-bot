import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/bot_event.dart';
import '../models/strategy_config.dart';
import 'bot_controller.dart';
import 'protocol.dart';
import 'server_check.dart';

/// Oracle Cloud などに常駐させたサーバーへつなぐ実装。
///
/// アプリを閉じてもサーバー側でボットは動き続ける。アプリは状態を見て
/// 設定を変えるだけの薄いクライアントになる。
class RemoteBotController implements BotController {
  RemoteBotController({
    required this.serverUrl,
    required this.token,
    this.allowSelfSignedCertificate = false,
    StrategyConfig? initialConfig,
  }) : _snapshot = BotSnapshot.initial(initialConfig ?? const StrategyConfig());

  /// 例: `wss://example.duckdns.org:8443/ws`
  final String serverUrl;

  /// サーバーと共有する接続トークン。
  final String token;

  /// 自己署名証明書を受け入れるか。
  ///
  /// **本番では false のままにすること。** true にすると TLS の検証を外すため、
  /// 経路上で盗聴・改ざんが可能になる。DuckDNS + Let's Encrypt か
  /// Tailscale を使って正規の証明書にするのが本筋。
  final bool allowSelfSignedCertificate;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _authTimer;
  int _attempt = 0;
  bool _disposed = false;

  /// 認証が通ったか。hello が返ってきたら true。
  bool _authenticated = false;

  /// やり直しても直らない理由で止まったか (トークン違い・URL違い)。
  ///
  /// 同じ値で延々つなぎ直しても通らないので、設定を直して作り直される
  /// まで待つ。
  bool _fatal = false;

  String? _lastError;

  /// 直近のつながらない理由。null なら分かっていない。
  String? get lastError => _lastError;

  /// 設定を直さないと直らない状態か。
  bool get needsSettingsFix => _fatal;

  BotSnapshot _snapshot;
  ControllerConnection _connection = ControllerConnection.disconnected;

  final _snapshotController = StreamController<BotSnapshot>.broadcast();
  final _eventController = StreamController<BotEvent>.broadcast();
  final _connectionController =
      StreamController<ControllerConnection>.broadcast();

  @override
  bool get isLocal => false;

  @override
  Stream<BotSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<BotEvent> get events => _eventController.stream;

  @override
  Stream<ControllerConnection> get connectionState =>
      _connectionController.stream;

  @override
  BotSnapshot get snapshot => _snapshot;

  @override
  ControllerConnection get connection => _connection;

  @override
  Future<void> connect() async {
    if (_disposed) return;
    _fatal = false;
    _authenticated = false;
    _setConnection(ControllerConnection.connecting);

    // URL は入れ間違いが多いので、直せる範囲は直してからつなぐ。
    final uri = normalizeServerUrl(serverUrl);
    if (uri == null) {
      _giveUp(
        'サーバーのURLが読めません: 「$serverUrl」 '
        '例: ws://192.168.0.10:8080/ws  /  wss://自分の名前.duckdns.org/ws',
      );
      return;
    }
    final authToken = token.trim();
    if (authToken.isEmpty) {
      _giveUp('接続トークンが空です。サーバーの BOT_TOKEN と同じ値を入れて下さい。');
      return;
    }

    try {
      WebSocketChannel channel;
      if (allowSelfSignedCertificate) {
        // WebSocketChannel.connect は HttpClient を差し込めないので
        // IOWebSocketChannel を直接使う。
        final client = HttpClient()
          ..badCertificateCallback = (cert, host, port) => true;
        final socket = await WebSocket.connect(
          uri.toString(),
          customClient: client,
        );
        channel = IOWebSocketChannel(socket);
      } else {
        channel = WebSocketChannel.connect(uri);
        await channel.ready;
      }
      _channel = channel;

      _sub = channel.stream.listen(
        _onMessage,
        onError: (Object e) => _scheduleReconnect('通信エラー: ${_shortReason(e)}'),
        onDone: () => _scheduleReconnect(
          _authenticated
              ? 'サーバーとの接続が切れました'
              : '繋いだ直後に切られました。接続トークンを確かめて下さい。',
        ),
        cancelOnError: true,
      );

      _send(WireMessage(
        type: ClientCommandType.auth,
        payload: {'token': authToken},
      ));
      _send(const WireMessage(type: ClientCommandType.requestSnapshot));

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        _send(const WireMessage(type: ClientCommandType.requestSnapshot));
      });

      // 「つながった」と言うのは hello が返ってきてから。トークンが違えば
      // サーバーは切ってくるので、勝手に成功にしない。
      _authTimer?.cancel();
      _authTimer = Timer(const Duration(seconds: 15), () {
        if (_authenticated || _disposed) return;
        _scheduleReconnect(
          'サーバーから返事がありません。$uri が本当にこのボットのサーバーか'
          '確かめて下さい。',
        );
      });
    } catch (e) {
      _scheduleReconnect('接続出来ません (${_shortReason(e)})');
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    WireMessage message;
    try {
      message = WireMessage.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return;
    }

    switch (message.type) {
      case ServerMessageType.snapshot:
        _snapshot = BotSnapshot.fromJson(message.payload);
        if (!_snapshotController.isClosed) {
          _snapshotController.add(_snapshot);
        }
      case ServerMessageType.event:
        final event = BotEvent.fromJson(message.payload);
        if (!_eventController.isClosed) _eventController.add(event);
      case ServerMessageType.history:
        final list = (message.payload['events'] as List?) ?? const [];
        for (final e in list.cast<Map<String, dynamic>>()) {
          if (!_eventController.isClosed) {
            _eventController.add(BotEvent.fromJson(e));
          }
        }
      case ServerMessageType.error:
        final text = message.payload['message'] as String? ?? '不明なエラー';
        if (!_eventController.isClosed) {
          _eventController.add(BotEvent.error('サーバー: $text'));
        }
        // 認証前に返るエラーはトークン違い。つなぎ直しても通らない。
        if (!_authenticated) {
          _giveUp('サーバーに拒まれました: $text (接続トークンを確かめて下さい)');
        }
      case ServerMessageType.hello:
        // ここで初めて「つながった」と言える。
        _authenticated = true;
        _authTimer?.cancel();
        _attempt = 0;
        _lastError = null;
        _setConnection(ControllerConnection.connected);
      case ServerMessageType.ack:
      default:
        break;
    }
  }

  void _send(WireMessage message) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(message.toJson()));
    } catch (e) {
      _scheduleReconnect('送信に失敗: $e');
    }
  }

  void _scheduleReconnect(String reason) {
    if (_disposed) return;
    _closeSocket();
    _lastError = reason;
    _setConnection(ControllerConnection.error);
    if (!_eventController.isClosed) {
      _eventController.add(BotEvent.warning(reason));
    }
    // 直しようのない理由で止めたときは、つなぎ直さない。
    if (_fatal) return;

    if (_reconnectTimer?.isActive ?? false) return;
    _attempt = math.min(_attempt + 1, 5);
    final delay = Duration(seconds: math.min(30, 1 << _attempt));
    _reconnectTimer = Timer(delay, connect);
  }

  /// 設定を直すまでつなぎ直さない形で止める。
  void _giveUp(String reason) {
    _fatal = true;
    _scheduleReconnect(reason);
  }

  void _closeSocket() {
    _pingTimer?.cancel();
    _authTimer?.cancel();
    _authenticated = false;
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  /// 例外から、画面に出して分かる短い理由を作る。
  static String _shortReason(Object error) => switch (error) {
    SocketException(:final osError, :final message) =>
      osError?.message ?? (message.isEmpty ? '$error' : message),
    WebSocketException(:final message) => message,
    HandshakeException() => 'TLS の検証に失敗しました',
    _ => '$error',
  };

  void _setConnection(ControllerConnection state) {
    _connection = state;
    if (!_connectionController.isClosed) _connectionController.add(state);
  }

  @override
  Future<void> start() async =>
      _send(const WireMessage(type: ClientCommandType.start));

  @override
  Future<void> stop() async =>
      _send(const WireMessage(type: ClientCommandType.stop));

  @override
  Future<void> updateConfig(StrategyConfig config) async => _send(
    WireMessage(
      type: ClientCommandType.updateConfig,
      payload: config.toJson(),
    ),
  );

  /// サーバーが持つ取引所APIキーを更新する。
  Future<void> updateCredentials(String apiKey, String apiSecret) async =>
      _send(
        WireMessage(
          type: ClientCommandType.updateCredentials,
          payload: {'apiKey': apiKey, 'apiSecret': apiSecret},
        ),
      );

  @override
  Future<void> closePosition(String id) async => _send(
    WireMessage(
      type: ClientCommandType.closePosition,
      payload: {'id': id},
    ),
  );

  @override
  Future<void> refreshAccount() async =>
      _send(const WireMessage(type: ClientCommandType.refreshAccount));

  @override
  Future<void> clearHistory({String? id}) async => _send(
    WireMessage(
      type: ClientCommandType.clearHistory,
      payload: {if (id != null) 'id': id},
    ),
  );

  @override
  Future<void> updatePositionExit(
    String id, {
    double? takeProfitPrice,
    double? stopLossPrice,
    bool clearStopLoss = false,
  }) async => _send(
    WireMessage(
      type: ClientCommandType.updatePositionExit,
      payload: {
        'id': id,
        if (takeProfitPrice != null) 'takeProfitPrice': takeProfitPrice,
        if (stopLossPrice != null) 'stopLossPrice': stopLossPrice,
        'clearStopLoss': clearStopLoss,
      },
    ),
  );

  @override
  Future<void> dispose() async {
    _disposed = true;
    _pingTimer?.cancel();
    _authTimer?.cancel();
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}
    await _snapshotController.close();
    await _eventController.close();
    await _connectionController.close();
  }
}
