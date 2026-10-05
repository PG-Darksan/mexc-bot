import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mexc_core/mexc_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Oracle Cloud の Always Free インスタンスなどに常駐させる本体。
///
/// 起動例:
///   MEXC_API_KEY=... MEXC_API_SECRET=... BOT_TOKEN=... \
///   dart run bin/server.dart --port 8080 --data-dir /var/lib/mexc-bot
///
/// TLS はこのプロセスでは終端しない。Caddy か Nginx を前に置くか、
/// Tailscale / Cloudflare Tunnel を使う (README を参照)。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8080', help: '待ち受けポート')
    ..addOption(
      'host',
      defaultsTo: '0.0.0.0',
      help: '待ち受けアドレス。カンマ区切りで複数書ける '
          '(例: 127.0.0.1,100.x.y.z → Caddy からも Tailscale からも繋がる)',
    )
    ..addOption(
      'data-dir',
      defaultsTo: './data',
      help: '設定と建玉を保存するディレクトリ',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final opts = parser.parse(args);
  if (opts['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  // 前後の空白や改行が混ざっていると、アプリ側の値と食い違って
  // 「トークンが違います」になる。読んだ時点で落としておく。
  final token = Platform.environment['BOT_TOKEN']?.trim();
  if (token == null || token.isEmpty) {
    stderr.writeln(
      'BOT_TOKEN が設定されていません。アプリからの接続を認証出来ないので起動を中止します。',
    );
    exit(64);
  }

  final apiKey = Platform.environment['MEXC_API_KEY'];
  final apiSecret = Platform.environment['MEXC_API_SECRET'];

  final store = FileBotStateStore(Directory(opts['data-dir'] as String));
  final config = await store.loadConfig() ?? const StrategyConfig();
  final savedPositions = await store.loadPositions();

  final engine = BotEngine(
    config: config,
    apiKey: apiKey,
    apiSecret: apiSecret,
  );
  engine.restorePositions(savedPositions);

  // アプリを閉じていてもスマホに届くよう、通知はサーバーから ntfy で送る。
  final topic = Platform.environment['NTFY_TOPIC']?.trim() ?? '';
  final push = topic.isEmpty
      ? null
      : PushNotifier(
          topic: topic,
          server: Platform.environment['NTFY_URL']?.trim(),
        );

  final server = BotServer(
    engine: engine,
    store: store,
    token: token,
    push: push,
  );

  final port = int.tryParse(opts['port'] as String) ?? 8080;
  // 1 つの HttpServer は 1 つのアドレスにしか着けないので、
  // 指定された数だけ立てる。Caddy 越し (127.0.0.1) と Tailscale の
  // アドレスを同時に使えるようにするため。
  final hosts = (opts['host'] as String)
      .split(',')
      .map((h) => h.trim())
      .where((h) => h.isNotEmpty)
      .toSet()
      .toList();
  if (hosts.isEmpty) hosts.add('0.0.0.0');
  await server.listen(hosts: hosts, port: port);

  if (apiKey == null || apiSecret == null) {
    _log('警告: MEXC_API_KEY / MEXC_API_SECRET が未設定です。'
        '判定だけ行い、注文は出しません。');
  } else {
    _log('実発注モードで起動しました。条件が成立すると実際に注文を出します。');
  }

  // アプリから最後に押した「開始 / 停止」を引き継ぐ。「停止」したまま
  // サーバーが立ち上がり直しても、勝手に動き出さないようにするため。
  // まだ一度も押していなければ BOT_AUTOSTART に従う (0 なら止めて待つ)。
  final savedRunning = await store.loadRunning();
  if (savedRunning ?? Platform.environment['BOT_AUTOSTART'] != '0') {
    await engine.start();
  }

  // 終了シグナルで後片付けする (systemd の stop / restart 用)。
  ProcessSignal.sigint.watch().listen((_) => _shutdown(server, engine));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => _shutdown(server, engine));
  }
}

Future<void> _shutdown(BotServer server, BotEngine engine) async {
  _log('終了処理を始めます');
  await engine.stop();
  await server.dispose();
  await engine.dispose();
  exit(0);
}

void _log(String message) {
  stdout.writeln('[${DateTime.now().toIso8601String()}] $message');
}

/// WebSocket でアプリとつながるサーバー。
class BotServer {
  BotServer({
    required this.engine,
    required this.store,
    required this.token,
    this.push,
  });

  final BotEngine engine;
  final BotStateStore store;
  final String token;

  /// スマホへの通知。NTFY_TOPIC が無ければ null。
  final PushNotifier? push;

  final Set<_Client> _clients = {};
  final List<BotEvent> _recentEvents = [];
  final List<HttpServer> _httpServers = [];

  /// 待ち受けに失敗したアドレスごとの、やり直しの時計。
  final Map<String, Timer> _retryTimers = {};
  bool _disposed = false;
  StreamSubscription<BotSnapshot>? _snapshotSub;
  StreamSubscription<BotEvent>? _eventSub;
  Timer? _saveTimer;

  static const int maxRecentEvents = 300;

  Future<void> listen({
    required List<String> hosts,
    required int port,
  }) async {
    // 起動した時点の状態を元にして、そこからの変化を知らせる。
    push?.onSnapshot(engine.snapshot);
    _snapshotSub = engine.snapshots.listen((snapshot) {
      _broadcastSnapshot(snapshot);
      push?.onSnapshot(snapshot);
    });
    _eventSub = engine.events.listen((event) {
      _recentEvents.add(event);
      if (_recentEvents.length > maxRecentEvents) {
        _recentEvents.removeRange(0, _recentEvents.length - maxRecentEvents);
      }
      _log('${event.level.name}: ${event.message}');
      _broadcast(
        WireMessage(type: ServerMessageType.event, payload: event.toJson()),
      );
    });

    // 設定と建玉は定期的に保存する。プロセスが落ちても状態を引き継げる。
    _saveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_persist());
    });

    final wsHandler = webSocketHandler((
      WebSocketChannel channel,
      String? protocol,
    ) {
      _handleConnection(channel);
    });

    final router = Cascade()
        .add((Request request) {
          if (request.url.path == 'ws') return wsHandler(request);
          return Response.notFound('not found');
        })
        .add((Request request) {
          if (request.url.path == 'health') {
            return Response.ok(
              jsonEncode({
                'ok': true,
                'running': engine.isRunning,
                'positions': engine.openPositions.length,
                'time': DateTime.now().toIso8601String(),
              }),
              headers: {'content-type': 'application/json'},
            );
          }
          return Response.notFound('not found');
        })
        .handler;

    for (final host in hosts) {
      await _serve(router, host, port);
    }
  }

  /// [host] で待ち受ける。
  ///
  /// 127.0.0.1 などで待ち受けられないのは、同じポートに前のボットが残って
  /// いるとき。2 台目まで動かすと注文が二重に出るので、起動を止める (例外を
  /// そのまま投げる)。Tailscale などのアドレスは、サーバーの起動直後には
  /// まだ割り当てられていないことがある。それで落ちると売買まで止まって
  /// しまうので、知らせて 30 秒ごとに待ち受け直す。
  Future<void> _serve(Handler handler, String host, int port) async {
    if (_disposed) return;
    try {
      _httpServers.add(await shelf_io.serve(handler, host, port));
      _retryTimers.remove(host);
      _log('待ち受け開始: http://$host:$port  (WebSocket: /ws)');
    } on SocketException catch (e) {
      if (_mustListen(host)) rethrow;
      _log('$host:$port で待ち受けられません (${e.message})。30 秒後にやり直します。');
      _retryTimers[host] = Timer(const Duration(seconds: 30), () {
        unawaited(_serve(handler, host, port));
      });
    }
  }

  static bool _mustListen(String host) =>
      host == '127.0.0.1' ||
      host == 'localhost' ||
      host == '::1' ||
      host == '0.0.0.0';

  void _handleConnection(WebSocketChannel channel) {
    final client = _Client(channel);
    _clients.add(client);
    _log('クライアント接続 (現在 ${_clients.length} 台)');

    // 認証されないまま放置された接続は切る。
    final authTimeout = Timer(const Duration(seconds: 10), () {
      if (!client.authenticated) {
        client.send(
          const WireMessage(
            type: ServerMessageType.error,
            payload: {'message': '認証されませんでした'},
          ),
        );
        client.close();
      }
    });

    channel.stream.listen(
      (raw) => _onClientMessage(client, raw),
      onDone: () {
        authTimeout.cancel();
        _clients.remove(client);
        _log('クライアント切断 (残り ${_clients.length} 台)');
      },
      onError: (Object e) {
        authTimeout.cancel();
        _clients.remove(client);
      },
    );
  }

  Future<void> _onClientMessage(_Client client, dynamic raw) async {
    if (raw is! String) return;
    WireMessage message;
    try {
      message = WireMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return;
    }

    if (!client.authenticated) {
      final sent = (message.payload['token'] as String?)?.trim();
      if (message.type != ClientCommandType.auth || sent != token) {
        // どちらが悪いのか分かるように、長さだけ残す (値は書かない)。
        _log(
          message.type != ClientCommandType.auth
              ? '認証より先に ${message.type} が来たので切りました'
              : 'トークンが合わないので切りました '
                  '(受け取り ${sent?.length ?? 0} 文字 / 期待 ${token.length} 文字)',
        );
        client.send(
          const WireMessage(
            type: ServerMessageType.error,
            payload: {'message': 'トークンが違います'},
          ),
        );
        client.close();
        return;
      }
      client.authenticated = true;
      client.send(
        WireMessage(
          type: ServerMessageType.hello,
          payload: {'version': 1, 'serverTime': DateTime.now().toIso8601String()},
        ),
      );
      client.send(
        WireMessage(
          type: ServerMessageType.snapshot,
          payload: _snapshotPayload(engine.snapshot),
        ),
      );
      client.send(
        WireMessage(
          type: ServerMessageType.history,
          payload: {
            'events': _recentEvents.map((e) => e.toJson()).toList(),
          },
        ),
      );
      return;
    }

    try {
      switch (message.type) {
        case ClientCommandType.start:
          await engine.start();
          await store.saveRunning(true);
        case ClientCommandType.stop:
          await engine.stop();
          await store.saveRunning(false);
        case ClientCommandType.updateConfig:
          final config = StrategyConfig.fromJson(message.payload);
          final errors = config.validate();
          if (errors.isNotEmpty) {
            client.send(
              WireMessage(
                type: ServerMessageType.error,
                id: message.id,
                payload: {'message': errors.join(' / ')},
              ),
            );
            return;
          }
          await engine.updateConfig(config);
          await store.saveConfig(config);
        case ClientCommandType.closePosition:
          await engine.closePositionManually(
            message.payload['id'] as String? ?? '',
          );
        case ClientCommandType.refreshAccount:
          await engine.refreshAccount();
        case ClientCommandType.clearHistory:
          engine.clearHistory(id: message.payload['id'] as String?);
          await store.savePositions(engine.allPositions);
        case ClientCommandType.updatePositionExit:
          await engine.updatePositionExit(
            message.payload['id'] as String? ?? '',
            takeProfitPrice:
                (message.payload['takeProfitPrice'] as num?)?.toDouble(),
            stopLossPrice:
                (message.payload['stopLossPrice'] as num?)?.toDouble(),
            clearStopLoss: message.payload['clearStopLoss'] as bool? ?? false,
          );
        case ClientCommandType.requestSnapshot:
          client.send(
            WireMessage(
              type: ServerMessageType.snapshot,
              payload: _snapshotPayload(engine.snapshot),
            ),
          );
          return;
        case ClientCommandType.requestHistory:
          client.send(
            WireMessage(
              type: ServerMessageType.history,
              payload: {
                'events': _recentEvents.map((e) => e.toJson()).toList(),
              },
            ),
          );
          return;
        case ClientCommandType.updateCredentials:
          // APIキーはサーバーの環境変数で管理する方針。
          // 通信経路に鍵を流さないため、ここでは受け付けない。
          client.send(
            WireMessage(
              type: ServerMessageType.error,
              id: message.id,
              payload: {
                'message':
                    'APIキーはサーバー側の環境変数 (MEXC_API_KEY / MEXC_API_SECRET) で設定して下さい。',
              },
            ),
          );
          return;
        default:
          return;
      }
      client.send(
        WireMessage(type: ServerMessageType.ack, id: message.id),
      );
    } catch (e) {
      client.send(
        WireMessage(
          type: ServerMessageType.error,
          id: message.id,
          payload: {'message': '$e'},
        ),
      );
    }
  }

  void _broadcastSnapshot(BotSnapshot snapshot) {
    _broadcast(
      WireMessage(
        type: ServerMessageType.snapshot,
        payload: _snapshotPayload(snapshot),
      ),
    );
  }

  /// アプリへ送る状態。通知の購読名も添える (アプリの設定に出すため)。
  Map<String, dynamic> _snapshotPayload(BotSnapshot snapshot) => {
    ...snapshot.toJson(),
    'pushTopic': push?.topic,
  };

  void _broadcast(WireMessage message) {
    for (final client in _clients.toList()) {
      if (client.authenticated) client.send(message);
    }
  }

  Future<void> _persist() async {
    try {
      await store.saveConfig(engine.config);
      await store.savePositions(engine.allPositions);
    } catch (e) {
      _log('保存に失敗: $e');
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _saveTimer?.cancel();
    push?.close();
    await _persist();
    await _snapshotSub?.cancel();
    await _eventSub?.cancel();
    for (final client in _clients.toList()) {
      client.close();
    }
    _clients.clear();
    for (final server in _httpServers) {
      await server.close(force: true);
    }
    _httpServers.clear();
  }
}

class _Client {
  _Client(this.channel);

  final WebSocketChannel channel;
  bool authenticated = false;

  void send(WireMessage message) {
    try {
      channel.sink.add(jsonEncode(message.toJson()));
    } catch (_) {
      // 送信できない接続は次の onDone で片付く。
    }
  }

  void close() {
    try {
      channel.sink.close();
    } catch (_) {}
  }
}

/// 建てた・決済した・動き出した・止まった時に、ntfy でスマホへ知らせる。
///
/// アプリを閉じていても届くように、サーバーから送る。届いた状態を前と
/// 見比べて変化を拾う。最初に渡された状態 (起動した時点) は覚えるだけ。
class PushNotifier {
  PushNotifier({required this.topic, String? server})
    : server = (server == null || server.isEmpty) ? 'https://ntfy.sh' : server;

  /// ntfy の購読名。知っていれば誰でも読めるので、推測できない名前にする。
  final String topic;
  final String server;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  Set<String>? _open;
  Set<String>? _closed;
  bool? _running;

  void onSnapshot(BotSnapshot s) {
    final knownOpen = _open;
    final knownClosed = _closed;
    final wasRunning = _running;
    _open = {for (final p in s.positions) p.id};
    _closed = {for (final p in s.closedPositions) p.id};
    _running = s.running;
    if (knownOpen == null || knownClosed == null || wasRunning == null) return;

    for (final p in s.positions) {
      if (knownOpen.contains(p.id) || knownClosed.contains(p.id)) continue;
      unawaited(
        send(
          '建てました: ${_name(p)} ${_side(p)}',
          '${p.vol} 枚 @ ${p.entryPrice} / 利確 ${p.takeProfitPrice}'
              ' (${p.timeframe.label})',
          tag: 'chart_with_upwards_trend',
        ),
      );
    }
    for (final p in s.closedPositions) {
      if (knownClosed.contains(p.id)) continue;
      final pnl = p.realizedPnl ?? 0;
      unawaited(
        send(
          '決済しました: ${_name(p)} ${pnl >= 0 ? '+' : ''}'
              '${pnl.toStringAsFixed(4)} USDT',
          '${_side(p)} ${p.vol} 枚 / ${p.entryPrice} → ${p.closePrice ?? '-'}'
              '${p.note == null ? '' : ' (${p.note})'}',
          tag: pnl >= 0 ? 'moneybag' : 'small_red_triangle_down',
        ),
      );
    }
    if (wasRunning != s.running) {
      unawaited(
        s.running
            ? send('ボットを開始しました', 'サーバーで売買を始めました。', tag: 'arrow_forward')
            : send(
                'ボットを停止しました',
                'サーバーのボットが止まりました。建玉と預けた利確はそのまま残ります。',
                tag: 'stop_button',
              ),
      );
    }
  }

  static String _name(ManagedPosition p) => p.symbol.replaceAll('_', '');

  static String _side(ManagedPosition p) =>
      p.direction.isShort ? '売り (ショート)' : '買い (ロング)';

  /// 1 件送る。届かなくても売買には関わらないので、記録に残すだけにする。
  Future<void> send(String title, String message, {String? tag}) async {
    try {
      final body = utf8.encode(
        jsonEncode({
          'topic': topic,
          'title': title,
          'message': message,
          if (tag != null) 'tags': [tag],
        }),
      );
      final request = await _http.postUrl(Uri.parse(server));
      request.headers.contentType = ContentType.json;
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode >= 300) {
        _log('通知を送れませんでした (HTTP ${response.statusCode})');
      }
    } catch (e) {
      _log('通知を送れませんでした: $e');
    }
  }

  void close() => _http.close(force: true);
}
