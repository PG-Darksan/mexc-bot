/// サーバー常駐モードで、アプリとサーバーがやり取りするメッセージの形式。
///
/// 1 本の WebSocket 上を JSON で流す。サーバーからは状態とログ、
/// アプリからは操作コマンドが流れる。
library;

/// サーバー → アプリ。
class ServerMessageType {
  static const String hello = 'hello';
  static const String snapshot = 'snapshot';
  static const String event = 'event';
  static const String ack = 'ack';
  static const String error = 'error';
  static const String history = 'history';
}

/// アプリ → サーバー。
class ClientCommandType {
  static const String auth = 'auth';
  static const String start = 'start';
  static const String stop = 'stop';
  static const String updateConfig = 'updateConfig';
  static const String updateCredentials = 'updateCredentials';
  static const String closePosition = 'closePosition';
  static const String updatePositionExit = 'updatePositionExit';
  static const String requestSnapshot = 'requestSnapshot';
  static const String requestHistory = 'requestHistory';
}

/// 1 通ぶんのメッセージ。
class WireMessage {
  const WireMessage({required this.type, this.payload = const {}, this.id});

  final String type;
  final Map<String, dynamic> payload;

  /// コマンドに付ける識別子。ack / error で返ってくる。
  final String? id;

  Map<String, dynamic> toJson() => {
    'type': type,
    if (id != null) 'id': id,
    'payload': payload,
  };

  factory WireMessage.fromJson(Map<String, dynamic> json) => WireMessage(
    type: json['type'] as String? ?? '',
    id: json['id'] as String?,
    payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}
