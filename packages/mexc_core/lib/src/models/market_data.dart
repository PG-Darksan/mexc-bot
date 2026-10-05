import 'package:meta/meta.dart';

import 'strategy_config.dart';

/// `GET /api/v1/contract/ticker` の 1 銘柄分。
@immutable
class TickerSnapshot {
  const TickerSnapshot({
    required this.symbol,
    required this.lastPrice,
    required this.fairPrice,
    required this.indexPrice,
    required this.amount24,
    required this.volume24,
    required this.fundingRate,
    required this.riseFallRate,
    required this.timestamp,
    this.high24Price = 0,
    this.lower24Price = 0,
  });

  final String symbol;
  final double lastPrice;
  final double fairPrice;
  final double indexPrice;

  /// 24時間の売買代金 (USDT)。出来高フィルタはこの値を見る。
  final double amount24;

  /// 24時間の出来高 (枚)。
  final double volume24;

  /// 直近の資金調達率 (0.0001 = 0.01%)。
  final double fundingRate;

  /// 24時間の騰落率 (0.05 = +5%)。
  final double riseFallRate;
  final int timestamp;

  /// 24時間の高値と安値。値幅の並べ替えに使う。
  final double high24Price;
  final double lower24Price;

  /// 24時間の騰落率 (%)。
  double get changePercent => riseFallRate * 100;

  /// 24時間の値幅 (安値から高値までの %)。取れていなければ 0。
  double get range24Percent =>
      lower24Price > 0 ? (high24Price - lower24Price) / lower24Price * 100 : 0;

  factory TickerSnapshot.fromJson(Map<String, dynamic> json) {
    double d(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return TickerSnapshot(
      symbol: json['symbol'] as String,
      lastPrice: d('lastPrice'),
      fairPrice: d('fairPrice'),
      indexPrice: d('indexPrice'),
      amount24: d('amount24'),
      volume24: d('volume24'),
      fundingRate: d('fundingRate'),
      riseFallRate: d('riseFallRate'),
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      high24Price: d('high24Price'),
      lower24Price: d('lower24Price'),
    );
  }
}

/// `GET /api/v1/contract/funding_rate/{symbol}` の結果。
@immutable
class FundingInfo {
  const FundingInfo({
    required this.symbol,
    required this.fundingRate,
    required this.collectCycleHours,
    required this.nextSettleTime,
    required this.fetchedAt,
  });

  final String symbol;

  /// 正ならロングが払いショートが受け取る。負ならショートが払う。
  final double fundingRate;

  /// 調達間隔 (時間)。MEXC は銘柄ごとに 8 / 4 / 1 などが混在する。
  final int collectCycleHours;

  final int nextSettleTime;
  final DateTime fetchedAt;

  /// 次に資金調達を精算するまでの時間 (時間単位)。
  ///
  /// 精算の時刻が取れていない (または過ぎている) ときは、調達間隔の区切り
  /// (UTC の 0 時から間隔ごと) で精算されるものとして求める。
  double hoursUntilSettle(DateTime now) {
    final nowMs = now.millisecondsSinceEpoch;
    var next = nextSettleTime;
    if (next <= nowMs) {
      final cycleMs = (collectCycleHours < 1 ? 1 : collectCycleHours) * 3600000;
      next = (nowMs ~/ cycleMs + 1) * cycleMs;
    }
    return (next - nowMs) / 3600000;
  }

  /// 指定方向の建玉が資金調達を「支払う」側かどうか。
  ///
  /// fundingRate が正ならロングが払い、負ならショートが払う。
  bool paysFor(TradeDirection direction) =>
      direction.isShort ? fundingRate < 0 : fundingRate > 0;

  /// 指定方向から見た負担率 (正の値なら支払い負担)。
  double burdenRateFor(TradeDirection direction) =>
      direction.isShort ? -fundingRate : fundingRate;

  factory FundingInfo.fromJson(
    Map<String, dynamic> json, {
    required DateTime fetchedAt,
  }) => FundingInfo(
    symbol: json['symbol'] as String,
    fundingRate: (json['fundingRate'] as num?)?.toDouble() ?? 0,
    collectCycleHours: (json['collectCycle'] as num?)?.toInt() ?? 8,
    nextSettleTime: (json['nextSettleTime'] as num?)?.toInt() ?? 0,
    fetchedAt: fetchedAt,
  );

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'fundingRate': fundingRate,
    'collectCycle': collectCycleHours,
    'nextSettleTime': nextSettleTime,
  };
}
