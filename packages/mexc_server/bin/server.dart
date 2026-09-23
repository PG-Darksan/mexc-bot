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
    ..addOption('host', defaultsTo: '0.0.0.0', help: '待ち受けアドレス')
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

  final token = Platform.environment['BOT_TOKEN'];
  if (token == null || token.isEmpty) {
    stderr.writeln(
      'BOT_TOKEN が設定されていません。アプリからの接続を認証できないので起動を中止します。',
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

  final server = BotServer(
    engine: engine,
    store: store,
    token: token,
  );

  final port = int.tryParse(opts['port'] as String) ?? 8080;
  final host = opts['host'] as String;
  await server.listen(host: host, port: port);

  _log('待ち受け開始: http://$host:$port  (WebSocket: /ws)');
  if (apiKey == null || apiSecret == null) {
    _log('警告: MEXC_API_KEY / MEXC_API_SECRET が未設定です。'
        '判定だけ行い、注文は出しません。');
  } else {
    _log('実発注モードで起動しました。条件が成立すると実際に注文を出します。');
  }

  // 自動起動。停止状態で待つなら BOT_AUTOSTART=0 を指定する。
  if (Platform.environment['BOT_AUTOSTART'] != '0') {
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
  });

  final BotEngine engine;
  final BotStateStore store;
  final String token;

  final Set<_Client> _clients = {};
  final List<BotEvent> _recentEvents = [];
  HttpServer? _httpServer;
  StreamSubscription<BotSnapshot>? _snapshotSub;
  StreamSubscription<BotEvent>? _eventSub;
  Timer? _saveTimer;

  static const int maxRecentEvents = 300;

  Future<void> listen({required String host, required int port}) async {
    _snapshotSub = engine.snapshots.listen(_broadcastSnapshot);
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

    _httpServer = await shelf_io.serve(router, host, port);
  }

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
      if (message.type != ClientCommandType.auth ||
          message.payload['token'] != token) {
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
          payload: engine.snapshot.toJson(),
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
        case ClientCommandType.stop:
          await engine.stop();
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
        case ClientCommandType.requestSnapshot:
          client.send(
            WireMessage(
              type: ServerMessageType.snapshot,
              payload: engine.snapshot.toJson(),
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
                    'APIキーはサーバー側の環境変数 (MEXC_API_KEY / MEXC_API_SECRET) で設定してください。',
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
        payload: snapshot.toJson(),
      ),
    );
  }

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
    _saveTimer?.cancel();
    await _persist();
    await _snapshotSub?.cancel();
    await _eventSub?.cancel();
    for (final client in _clients.toList()) {
      client.close();
    }
    _clients.clear();
    await _httpServer?.close(force: true);
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
