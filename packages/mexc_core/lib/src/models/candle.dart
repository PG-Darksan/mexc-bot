import 'package:meta/meta.dart';

/// ローソク足 1 本。
///
/// [openTime] は足の開始時刻 (UNIX 秒)。MEXC の kline はこの値を返す。
@immutable
class Candle {
  const Candle({
    required this.openTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.amount,
  });

  final int openTime;
  final double open;
  final double high;
  final double low;
  final double close;

  /// 出来高 (枚数)。
  final double volume;

  /// 売買代金 (USDT)。
  final double amount;

  Candle copyWithPrice(double price) => Candle(
    openTime: openTime,
    open: open,
    high: price > high ? price : high,
    low: price < low ? price : low,
    close: price,
    volume: volume,
    amount: amount,
  );

  Map<String, dynamic> toJson() => {
    't': openTime,
    'o': open,
    'h': high,
    'l': low,
    'c': close,
    'v': volume,
    'a': amount,
  };

  factory Candle.fromJson(Map<String, dynamic> json) => Candle(
    openTime: (json['t'] as num).toInt(),
    open: (json['o'] as num).toDouble(),
    high: (json['h'] as num).toDouble(),
    low: (json['l'] as num).toDouble(),
    close: (json['c'] as num).toDouble(),
    volume: (json['v'] as num?)?.toDouble() ?? 0,
    amount: (json['a'] as num?)?.toDouble() ?? 0,
  );

  @override
  String toString() =>
      'Candle(t=$openTime o=$open h=$high l=$low c=$close v=$volume)';
}
