import 'package:meta/meta.dart';

import 'position.dart';
import 'signal.dart';
import 'strategy_config.dart';

/// ログの重み。
enum BotLogLevel { debug, info, warning, error, trade }

/// bot が出すログ 1 行。
@immutable
class BotEvent {
  const BotEvent({
    required this.time,
    required this.level,
    required this.message,
    this.symbol,
    this.data,
  });

  final DateTime time;
  final BotLogLevel level;
  final String message;
  final String? symbol;
  final Map<String, dynamic>? data;

  factory BotEvent.info(String message, {String? symbol}) =>
      BotEvent(time: DateTime.now(), level: BotLogLevel.info, message: message, symbol: symbol);

  factory BotEvent.warning(String message, {String? symbol}) => BotEvent(
    time: DateTime.now(),
    level: BotLogLevel.warning,
    message: message,
    symbol: symbol,
  );

  factory BotEvent.error(String message, {String? symbol}) => BotEvent(
    time: DateTime.now(),
    level: BotLogLevel.error,
    message: message,
    symbol: symbol,
  );

  factory BotEvent.trade(
    String message, {
    String? symbol,
    Map<String, dynamic>? data,
  }) => BotEvent(
    time: DateTime.now(),
    level: BotLogLevel.trade,
    message: message,
    symbol: symbol,
    data: data,
  );

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'level': level.name,
    'message': message,
    'symbol': symbol,
    'data': data,
  };

  factory BotEvent.fromJson(Map<String, dynamic> json) => BotEvent(
    time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
    level: BotLogLevel.values.firstWhere(
      (e) => e.name == json['level'],
      orElse: () => BotLogLevel.info,
    ),
    message: json['message'] as String? ?? '',
    symbol: json['symbol'] as String?,
    data: (json['data'] as Map?)?.cast<String, dynamic>(),
  );
}

/// 画面に出すための bot の現在状態。
@immutable
class BotSnapshot {
  const BotSnapshot({
    required this.running,
    required this.config,
    required this.wsConnected,
    required this.watchedSymbolCount,
    required this.subscriptionCount,
    required this.evaluations,
    required this.positions,
    required this.closedPositions,
    this.markPrices = const {},
    this.pendingHistoryCount = 0,
    this.lastCycleAt,
    this.lastCycleDurationMs,
    this.asset,
    this.lastError,
    this.credentialsConfigured = false,
  });

  final bool running;
  final StrategyConfig config;
  final bool wsConnected;
  final int watchedSymbolCount;
  final int subscriptionCount;

  /// 直近の評価結果。条件に近い順に並べてある。
  final List<SignalEvaluation> evaluations;

  final List<ManagedPosition> positions;
  final List<ManagedPosition> closedPositions;

  /// 保有銘柄の現在値。評価損益の表示に使う。
  final Map<String, double> markPrices;

  /// まだローソク足の履歴を読み込めていない系列の数。0 になれば準備完了。
  final int pendingHistoryCount;
  final DateTime? lastCycleAt;
  final int? lastCycleDurationMs;
  final AccountAsset? asset;
  final String? lastError;
  final bool credentialsConfigured;

  static BotSnapshot initial(StrategyConfig config) => BotSnapshot(
    running: false,
    config: config,
    wsConnected: false,
    watchedSymbolCount: 0,
    subscriptionCount: 0,
    evaluations: const [],
    positions: const [],
    closedPositions: const [],
  );

  Map<String, dynamic> toJson() => {
    'running': running,
    'config': config.toJson(),
    'wsConnected': wsConnected,
    'watchedSymbolCount': watchedSymbolCount,
    'subscriptionCount': subscriptionCount,
    'evaluations': evaluations.map((e) => e.toJson()).toList(),
    'positions': positions.map((e) => e.toJson()).toList(),
    'closedPositions': closedPositions.map((e) => e.toJson()).toList(),
    'markPrices': markPrices,
    'pendingHistoryCount': pendingHistoryCount,
    'lastCycleAt': lastCycleAt?.toIso8601String(),
    'lastCycleDurationMs': lastCycleDurationMs,
    'asset': asset?.toJson(),
    'lastError': lastError,
    'credentialsConfigured': credentialsConfigured,
  };

  factory BotSnapshot.fromJson(Map<String, dynamic> json) => BotSnapshot(
    running: json['running'] as bool? ?? false,
    config: StrategyConfig.fromJson(
      (json['config'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    wsConnected: json['wsConnected'] as bool? ?? false,
    watchedSymbolCount: (json['watchedSymbolCount'] as num?)?.toInt() ?? 0,
    subscriptionCount: (json['subscriptionCount'] as num?)?.toInt() ?? 0,
    evaluations:
        ((json['evaluations'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(SignalEvaluation.fromJson)
            .toList(),
    positions:
        ((json['positions'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ManagedPosition.fromJson)
            .toList(),
    closedPositions:
        ((json['closedPositions'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ManagedPosition.fromJson)
            .toList(),
    markPrices:
        ((json['markPrices'] as Map?) ?? const {}).map(
          (k, v) => MapEntry('$k', (v as num).toDouble()),
        ),
    pendingHistoryCount: (json['pendingHistoryCount'] as num?)?.toInt() ?? 0,
    lastCycleAt: json['lastCycleAt'] == null
        ? null
        : DateTime.tryParse(json['lastCycleAt'] as String),
    lastCycleDurationMs: (json['lastCycleDurationMs'] as num?)?.toInt(),
    asset: json['asset'] == null
        ? null
        : AccountAsset.fromJson((json['asset'] as Map).cast<String, dynamic>()),
    lastError: json['lastError'] as String?,
    credentialsConfigured: json['credentialsConfigured'] as bool? ?? false,
  );
}
