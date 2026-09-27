import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

/// 「サーバーのURL」に入れた文字を、WebSocket が受け付ける形に直す。
///
/// 入れ間違いが多いので、次の面倒は黙って吸収する。
/// * 前後の空白 / 改行 (貼り付けで付いてくる)
/// * スキームなし (`example.com:8080/ws` → `ws://example.com:8080/ws`)
/// * `http` / `https` (→ `ws` / `wss`)
/// * パスなし (→ `/ws`。サーバーはこの 1 本しか受け付けない)
///
/// 直せない書き方なら null を返す。
Uri? normalizeServerUrl(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'ws://$text';

  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  if (uri.host.isEmpty) return null;

  final scheme = switch (uri.scheme.toLowerCase()) {
    'ws' || 'http' => 'ws',
    'wss' || 'https' => 'wss',
    _ => null,
  };
  if (scheme == null) return null;

  final path = uri.path.isEmpty || uri.path == '/' ? '/ws' : uri.path;
  return uri.replace(scheme: scheme, path: path);
}

/// 疎通確認の結果。
enum ServerCheckStatus {
  /// つながって、トークンも通った。
  ok,

  /// URL の書き方が直せない。
  badUrl,

  /// トークンが空。
  noToken,

  /// URL までは解釈できたが、そこに届かない (サーバーが落ちている等)。
  unreachable,

  /// 届いたがトークンを拒まれた。
  badToken,

  /// つながったのに返事が来ない。
  noReply,
}

/// 疎通確認の結果と、画面にそのまま出せる日本語の説明。
class ServerCheckResult {
  const ServerCheckResult(this.status, this.message, {this.url});

  final ServerCheckStatus status;

  /// 利用者に見せる一文。
  final String message;

  /// 実際につないだ URL (直したあとのもの)。
  final Uri? url;

  bool get ok => status == ServerCheckStatus.ok;
}

/// サーバーに 1 回だけつないで、URL とトークンのどちらが悪いかを切り分ける。
///
/// 常駐する [RemoteBotController] とは別に、設定画面の「接続を試す」から呼ぶ。
/// 認証が通ったらすぐ閉じるので、ボットの動きには触らない。
Future<ServerCheckResult> checkBotServer({
  required String url,
  required String token,
  bool allowSelfSignedCertificate = false,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final uri = normalizeServerUrl(url);
  if (uri == null) {
    return const ServerCheckResult(
      ServerCheckStatus.badUrl,
      'URL の書き方を確かめてください。例: ws://192.168.0.10:8080/ws '
      'または wss://自分の名前.duckdns.org/ws',
    );
  }
  final trimmedToken = token.trim();
  if (trimmedToken.isEmpty) {
    return ServerCheckResult(
      ServerCheckStatus.noToken,
      '接続トークンが空です。サーバーの /etc/mexc-bot/env にある '
      'BOT_TOKEN と同じ値を入れてください。',
      url: uri,
    );
  }

  WebSocket socket;
  try {
    HttpClient? client;
    if (allowSelfSignedCertificate) {
      client = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
    }
    socket = await WebSocket.connect(
      uri.toString(),
      customClient: client,
    ).timeout(timeout);
  } on TimeoutException {
    return ServerCheckResult(
      ServerCheckStatus.unreachable,
      '$uri に届きません (時間切れ)。'
      'サーバーが動いているか、ポートが開いているかを確かめてください。',
      url: uri,
    );
  } catch (e) {
    return ServerCheckResult(
      ServerCheckStatus.unreachable,
      '$uri につなげません: ${_reason(e)}',
      url: uri,
    );
  }

  final done = Completer<ServerCheckResult>();
  void finish(ServerCheckResult result) {
    if (!done.isCompleted) done.complete(result);
  }

  socket.listen(
    (raw) {
      if (raw is! String) return;
      final WireMessage message;
      try {
        message = WireMessage.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {
        return;
      }
      switch (message.type) {
        case ServerMessageType.hello:
          finish(ServerCheckResult(
            ServerCheckStatus.ok,
            '$uri につながりました。トークンも通っています。',
            url: uri,
          ));
        case ServerMessageType.error:
          finish(ServerCheckResult(
            ServerCheckStatus.badToken,
            'サーバーに拒まれました: '
            '${message.payload['message'] ?? 'トークンが違います'}',
            url: uri,
          ));
        default:
          break;
      }
    },
    onError: (Object e) => finish(ServerCheckResult(
      ServerCheckStatus.unreachable,
      '通信中にエラーになりました: ${_reason(e)}',
      url: uri,
    )),
    onDone: () => finish(ServerCheckResult(
      ServerCheckStatus.badToken,
      'つないだ直後に切られました。トークンが違う可能性が高いです。',
      url: uri,
    )),
    cancelOnError: true,
  );

  try {
    socket.add(jsonEncode(
      WireMessage(
        type: ClientCommandType.auth,
        payload: {'token': trimmedToken},
      ).toJson(),
    ));
  } catch (e) {
    finish(ServerCheckResult(
      ServerCheckStatus.unreachable,
      '認証を送れませんでした: ${_reason(e)}',
      url: uri,
    ));
  }

  final result = await done.future.timeout(
    timeout,
    onTimeout: () => ServerCheckResult(
      ServerCheckStatus.noReply,
      'つながりましたが返事がありません。'
      '$uri が本当にこのボットのサーバーかを確かめてください '
      '(別のサービスが同じポートで動いていることがあります)。',
      url: uri,
    ),
  );
  try {
    await socket.close();
  } catch (_) {}
  return result;
}

/// 例外から、利用者が見て分かる一文を作る。
String _reason(Object error) => switch (error) {
  SocketException(:final message, :final osError) =>
    osError?.message ?? (message.isEmpty ? '$error' : message),
  WebSocketException(:final message) => message,
  HandshakeException() => 'TLS の検証に失敗しました (証明書を確かめてください)',
  _ => '$error',
};
