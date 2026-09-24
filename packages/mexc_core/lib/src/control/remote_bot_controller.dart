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
  int _attempt = 0;
  bool _disposed = false;

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
    _setConnection(ControllerConnection.connecting);
    try {
      final uri = Uri.parse(serverUrl);
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
      _attempt = 0;

      _sub = channel.stream.listen(
        _onMessage,
        onError: (Object e) => _scheduleReconnect('通信エラー: $e'),
        onDone: () => _scheduleReconnect('サーバーとの接続が切れました'),
        cancelOnError: true,
      );

      _send(WireMessage(
        type: ClientCommandType.auth,
        payload: {'token': token},
      ));
      _send(const WireMessage(type: ClientCommandType.requestSnapshot));

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        _send(const WireMessage(type: ClientCommandType.requestSnapshot));
      });

      _setConnection(ControllerConnection.connected);
    } catch (e) {
      _scheduleReconnect('接続できません: $e');
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
      case ServerMessageType.hello:
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
    _pingTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _setConnection(ControllerConnection.error);
    if (!_eventController.isClosed) {
      _eventController.add(BotEvent.warning(reason));
    }

    if (_reconnectTimer?.isActive ?? false) return;
    _attempt = math.min(_attempt + 1, 5);
    final delay = Duration(seconds: math.min(30, 1 << _attempt));
    _reconnectTimer = Timer(delay, connect);
  }

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
