import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/candle.dart';
import '../models/market_data.dart';
import '../models/timeframe.dart';

/// kline の購読 1 件ぶん。
class KlineSubscription {
  const KlineSubscription(this.symbol, this.timeframe);

  final String symbol;
  final Timeframe timeframe;

  @override
  bool operator ==(Object other) =>
      other is KlineSubscription &&
      other.symbol == symbol &&
      other.timeframe == timeframe;

  @override
  int get hashCode => Object.hash(symbol, timeframe);

  @override
  String toString() => '$symbol/${timeframe.interval}';
}

/// WebSocket から届いた足の更新。
class KlineUpdate {
  const KlineUpdate({
    required this.symbol,
    required this.timeframe,
    required this.candle,
  });

  final String symbol;
  final Timeframe timeframe;
  final Candle candle;
}

/// MEXC 先物 WebSocket クライアント。
///
/// REST は api.mexc.com へ移ったが、**WebSocket は contract.mexc.com/edge のまま**
/// (api.mexc.com/edge は 404)。ここを取り違えると一切つながらない。
///
/// 仕様上の注意:
/// * サーバーからの自発 ping は無い。こちらから 15 秒ごとに送らないと 60 秒で切れる。
/// * push.kline に確定フラグが無いので、足の確定は `t` が変わったかで判断する。
/// * 出来高ゼロの銘柄は push が一切来ない。無音を切断と誤判定しないこと。
/// * 1 接続あたりの購読上限は非公開。安全側に倒して接続を分割する。
class MexcWsClient {
  MexcWsClient({
    this.url = 'wss://contract.mexc.com/edge',
    this.maxChannelsPerConnection = 120,
    this.pingInterval = const Duration(seconds: 15),
  });

  final String url;
  final int maxChannelsPerConnection;
  final Duration pingInterval;

  final _klineController = StreamController<KlineUpdate>.broadcast();
  final _tickerController =
      StreamController<List<TickerSnapshot>>.broadcast();
  final _statusController = StreamController<String>.broadcast();

  final List<_WsConnection> _connections = [];
  Set<KlineSubscription> _subscriptions = {};
  bool _subscribeTickers = false;
  bool _disposed = false;

  Stream<KlineUpdate> get klines => _klineController.stream;
  Stream<List<TickerSnapshot>> get tickers => _tickerController.stream;
  Stream<String> get status => _statusController.stream;

  bool get isConnected => _connections.any((c) => c.isConnected);
  int get connectionCount => _connections.length;
  int get subscriptionCount => _subscriptions.length;

  /// 全銘柄ティッカーの購読を切り替える。
  Future<void> setTickerSubscription(bool enabled) async {
    _subscribeTickers = enabled;
    await _rebalance();
  }

  /// 購読する銘柄 × 時間軸を差し替える。
  ///
  /// 差分だけを送る。接続数が足りなければ増やし、余れば閉じる。
  Future<void> setSubscriptions(Set<KlineSubscription> subs) async {
    _subscriptions = subs;
    await _rebalance();
  }

  Future<void> _rebalance() async {
    if (_disposed) return;

    final needed = math.max(
      1,
      (_subscriptions.length / maxChannelsPerConnection).ceil(),
    );

    while (_connections.length < needed) {
      final conn = _WsConnection(
        url: url,
        pingInterval: pingInterval,
        onKline: _emitKline,
        onTickers: (t) {
          if (!_tickerController.isClosed) _tickerController.add(t);
        },
        onStatus: (s) {
          if (!_statusController.isClosed) _statusController.add(s);
        },
      );
      _connections.add(conn);
      unawaited(conn.start());
    }

    // 余った接続は「割り当てる前に」閉じる。閉じる接続へ購読を配ってしまうと
    // その銘柄の足が二度と届かなくなる。
    while (_connections.length > needed) {
      final conn = _connections.removeLast();
      await conn.dispose();
    }

    // 銘柄名から行き先を決める。順番に配ると銘柄が1つ増減しただけで
    // 全体がずれて、大量の再購読が走ってしまう。
    final chunks = List.generate(
      _connections.length,
      (_) => <KlineSubscription>{},
    );
    for (final sub in _subscriptions) {
      final slot = sub.symbol.hashCode.abs() % _connections.length;
      chunks[slot].add(sub);
    }
    for (var c = 0; c < _connections.length; c++) {
      await _connections[c].applySubscriptions(
        chunks[c],
        tickers: _subscribeTickers && c == 0,
      );
    }
  }

  void _emitKline(KlineUpdate update) {
    if (!_klineController.isClosed) _klineController.add(update);
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final c in _connections) {
      await c.dispose();
    }
    _connections.clear();
    await _klineController.close();
    await _tickerController.close();
    await _statusController.close();
  }
}

/// 1 本の WebSocket 接続。購読状態を自分で覚えていて、再接続時に貼り直す。
class _WsConnection {
  _WsConnection({
    required this.url,
    required this.pingInterval,
    required this.onKline,
    required this.onTickers,
    required this.onStatus,
  });

  final String url;
  final Duration pingInterval;
  final void Function(KlineUpdate) onKline;
  final void Function(List<TickerSnapshot>) onTickers;
  final void Function(String) onStatus;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  Set<KlineSubscription> _desired = {};
  bool _wantTickers = false;
  bool _disposed = false;
  bool _connected = false;
  int _attempt = 0;

  bool get isConnected => _connected;

  Future<void> start() async {
    if (_disposed) return;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready;
      _channel = channel;
      _connected = true;
      _attempt = 0;
      onStatus('WebSocket接続 OK');

      _sub = channel.stream.listen(
        _onMessage,
        onError: (Object e) => _scheduleReconnect('エラー: $e'),
        onDone: () => _scheduleReconnect('切断されました'),
        cancelOnError: true,
      );

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(pingInterval, (_) {
        _send({'method': 'ping'});
      });

      await _resubscribe();
    } catch (e) {
      _scheduleReconnect('接続失敗: $e');
    }
  }

  Future<void> applySubscriptions(
    Set<KlineSubscription> subs, {
    required bool tickers,
  }) async {
    final added = subs.difference(_desired);
    final removed = _desired.difference(subs);
    final tickerChanged = tickers != _wantTickers;
    _desired = subs;
    _wantTickers = tickers;
    if (!_connected) return;

    for (final s in removed) {
      _send({
        'method': 'unsub.kline',
        'param': {'symbol': s.symbol, 'interval': s.timeframe.interval},
      });
    }
    for (final s in added) {
      _send({
        'method': 'sub.kline',
        'param': {'symbol': s.symbol, 'interval': s.timeframe.interval},
        'gzip': false,
      });
      // 一気に投げるとレート制限に触れる可能性があるので少し間隔を空ける。
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
    if (tickerChanged) {
      _send({'method': tickers ? 'sub.tickers' : 'unsub.tickers', 'gzip': false});
    }
  }

  Future<void> _resubscribe() async {
    // 再接続後は購読状態が全部消えているので、覚えている分を貼り直す。
    if (_wantTickers) {
      _send({'method': 'sub.tickers', 'gzip': false});
    }
    for (final s in _desired) {
      _send({
        'method': 'sub.kline',
        'param': {'symbol': s.symbol, 'interval': s.timeframe.interval},
        'gzip': false,
      });
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
  }

  void _send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null || !_connected) return;
    try {
      channel.sink.add(jsonEncode(message));
    } catch (e) {
      _scheduleReconnect('送信失敗: $e');
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final channel = json['channel'] as String?;
    if (channel == null) return;

    switch (channel) {
      case 'push.kline':
        final data = json['data'];
        if (data is! Map<String, dynamic>) return;
        final symbol =
            (data['symbol'] as String?) ?? (json['symbol'] as String?) ?? '';
        final tf = Timeframe.fromInterval(data['interval'] as String? ?? '');
        if (symbol.isEmpty || tf == null) return;
        double d(String k) => (data[k] as num?)?.toDouble() ?? 0;
        onKline(
          KlineUpdate(
            symbol: symbol,
            timeframe: tf,
            candle: Candle(
              openTime: (data['t'] as num?)?.toInt() ?? 0,
              open: d('o'),
              high: d('h'),
              low: d('l'),
              close: d('c'),
              volume: d('q'),
              amount: d('a'),
            ),
          ),
        );
      case 'push.tickers':
        final data = json['data'];
        if (data is! List) return;
        onTickers(
          data
              .cast<Map<String, dynamic>>()
              .map(TickerSnapshot.fromJson)
              .toList(),
        );
      case 'pong':
      case 'rs.error':
      default:
        break;
    }
  }

  void _scheduleReconnect(String reason) {
    if (_disposed) return;
    _connected = false;
    _pingTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    if (_reconnectTimer?.isActive ?? false) return;
    _attempt = math.min(_attempt + 1, 6);
    // 指数バックオフ + ジッタ。連打すると IP ブロックの恐れがある。
    final base = math.min(30, 1 << _attempt);
    final jitter = math.Random().nextInt(1000);
    final delay = Duration(milliseconds: base * 1000 + jitter);
    onStatus('$reason → ${delay.inSeconds}秒後に再接続');
    _reconnectTimer = Timer(delay, start);
  }

  Future<void> dispose() async {
    _disposed = true;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _connected = false;
  }
}
