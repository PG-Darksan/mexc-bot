import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mexc_core/mexc_core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// サーバーの状態を端末から覗くための小道具。
///
///   BOT_TOKEN=... dart run bin/status.dart --url ws://127.0.0.1:8080/ws
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('url', defaultsTo: 'ws://127.0.0.1:8080/ws')
    ..addOption('token', help: '省略すると環境変数 BOT_TOKEN を使う')
    ..addFlag('watch', abbr: 'w', help: '更新を流し続ける', negatable: false)
    ..addOption('top', defaultsTo: '15', help: '表示するシグナル件数');

  final opts = parser.parse(args);
  final token = (opts['token'] as String?) ?? Platform.environment['BOT_TOKEN'];
  if (token == null || token.isEmpty) {
    stderr.writeln('トークンがありません (--token か BOT_TOKEN)');
    exit(64);
  }
  final top = int.tryParse(opts['top'] as String) ?? 15;
  final watch = opts['watch'] as bool;

  final channel = WebSocketChannel.connect(Uri.parse(opts['url'] as String));
  await channel.ready;
  channel.sink.add(
    jsonEncode({
      'type': ClientCommandType.auth,
      'payload': {'token': token},
    }),
  );
  channel.sink.add(jsonEncode({'type': ClientCommandType.requestSnapshot}));

  final done = Completer<void>();
  channel.stream.listen(
    (raw) {
      if (raw is! String) return;
      final message = WireMessage.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (message.type == ServerMessageType.error) {
        stderr.writeln('エラー: ${message.payload['message']}');
        if (!done.isCompleted) done.complete();
        return;
      }
      if (message.type != ServerMessageType.snapshot) return;
      _printSnapshot(BotSnapshot.fromJson(message.payload), top);
      if (!watch && !done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );

  await done.future;
  await channel.sink.close();
}

void _printSnapshot(BotSnapshot s, int top) {
  final b = StringBuffer()
    ..writeln('─' * 96)
    ..writeln(
      '状態: ${s.running ? "稼働中" : "停止中"}'
      '  [${s.config.enabledSides.map((e) => e.direction.label).join("/")}]'
      '  相場データ: ${s.wsConnected ? "接続中" : "未接続"}'
      '  監視: ${s.watchedSymbolCount}銘柄 / ${s.subscriptionCount}系列'
      '${s.pendingHistoryCount > 0 ? "  履歴待ち: ${s.pendingHistoryCount}系列" : ""}',
    )
    ..writeln(
      '最終判定: ${s.lastCycleAt?.toLocal() ?? "-"}'
      '  (${s.lastCycleDurationMs ?? "-"} ms)'
      '  保有: ${s.positions.length} 件  決済済み: ${s.closedPositions.length} 件',
    );

  if (s.asset != null) {
    b.writeln(
      '残高: ${s.asset!.availableBalance.toStringAsFixed(2)} USDT'
      '  証拠金: ${s.asset!.positionMargin.toStringAsFixed(2)}'
      '  評価損益: ${s.asset!.unrealized.toStringAsFixed(4)}',
    );
  }
  if (s.lastError != null) b.writeln('直近エラー: ${s.lastError}');

  if (s.positions.isNotEmpty) {
    b.writeln('\n[保有中]');
    for (final p in s.positions) {
      final mark = s.markPrices[p.symbol];
      b.writeln(
        '  ${p.symbol.padRight(16)} ${p.direction.label.padRight(6)}'
        ' ${p.timeframe.label.padRight(6)}'
        ' 建値 ${p.entryPrice}  現在 ${mark ?? "-"}'
        '  利確 ${p.takeProfitPrice}'
        '  損益 ${mark == null ? "-" : p.unrealizedPnl(mark).toStringAsFixed(4)}',
      );
    }
  }

  final rows = s.evaluations.take(top).toList();
  if (rows.isNotEmpty) {
    b
      ..writeln('\n[評価 上位 ${rows.length} 件]')
      ..writeln(
        '  ${"銘柄".padRight(16)}${"方向".padRight(8)}${"時間軸".padRight(8)}'
        '${"RSI".padLeft(7)}${"価格".padLeft(14)}${"σ境界".padLeft(14)}'
        '${"乖離".padLeft(9)}${"利確幅".padLeft(8)}  判定',
      );
    for (final e in rows) {
      b.writeln(
        '  ${e.symbol.padRight(16)}${e.direction.label.padRight(8)}'
        '${e.timeframe.label.padRight(8)}'
        '${(e.rsi?.toStringAsFixed(1) ?? "-").padLeft(7)}'
        '${_fmt(e.price).padLeft(14)}'
        '${_fmt(e.bbBoundary).padLeft(14)}'
        '${((e.deviation == null ? "-" : "${(e.deviation! * 100).toStringAsFixed(2)}%")).padLeft(9)}'
        '${((e.expectedProfitPercent == null ? "-" : "${e.expectedProfitPercent!.toStringAsFixed(2)}%")).padLeft(8)}'
        '  ${e.isTriggered ? "★条件成立" : e.rejectReason!.label}',
      );
    }
  }
  b.writeln('─' * 96);
  stdout.write(b.toString());
}

String _fmt(double? v) {
  if (v == null) return '-';
  final abs = v.abs();
  if (abs >= 1000) return v.toStringAsFixed(2);
  if (abs >= 1) return v.toStringAsFixed(4);
  return v.toStringAsFixed(7);
}
