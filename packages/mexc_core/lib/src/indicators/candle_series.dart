import '../models/candle.dart';
import '../models/timeframe.dart';

/// 1 銘柄 1 時間軸ぶんのローソク足を保持する。
///
/// 末尾は「進行中の足」であることを前提にしている。判定は 1 分ごとに行い、
/// 進行中の足を含めて毎回すべて計算し直すので、指標の再帰状態を別に持たない。
/// こうしておくと未確定足が EMA / RSI の状態を汚す事故が起きない。
class CandleSeries {
  CandleSeries({
    required this.symbol,
    required this.timeframe,
    this.maxBars = 400,
  });

  final String symbol;
  final Timeframe timeframe;
  final int maxBars;

  final List<Candle> _candles = <Candle>[];

  List<Candle> get candles => List.unmodifiable(_candles);
  int get length => _candles.length;
  bool get isEmpty => _candles.isEmpty;
  Candle? get last => _candles.isEmpty ? null : _candles.last;

  /// 直近の更新時刻 (UNIX 秒)。無取引の検知に使う。
  int lastUpdatedAt = 0;

  /// 終値の配列。指標計算にそのまま渡す。
  List<double> get closes =>
      List<double>.generate(_candles.length, (i) => _candles[i].close);

  /// REST で取得した履歴で丸ごと置き換える。
  void replaceAll(List<Candle> candles) {
    _candles
      ..clear()
      ..addAll(candles);
    _candles.sort((a, b) => a.openTime.compareTo(b.openTime));
    _trim();
  }

  /// 同じ開始時刻の足があれば置き換え、無ければ追加する。
  void upsert(Candle candle) {
    if (_candles.isEmpty) {
      _candles.add(candle);
      _trim();
      return;
    }
    final lastTime = _candles.last.openTime;
    if (candle.openTime == lastTime) {
      _candles[_candles.length - 1] = candle;
    } else if (candle.openTime > lastTime) {
      _candles.add(candle);
      _trim();
    } else {
      // 遅れて届いた過去足。該当位置があれば差し替える。
      for (var i = _candles.length - 1; i >= 0; i--) {
        if (_candles[i].openTime == candle.openTime) {
          _candles[i] = candle;
          return;
        }
        if (_candles[i].openTime < candle.openTime) {
          _candles.insert(i + 1, candle);
          return;
        }
      }
    }
  }

  /// 最新価格だけで進行中の足を進める。
  ///
  /// 出来高の無い銘柄は WebSocket の kline push が一切来ないため、
  /// ticker の最新値でバケットを埋める必要がある。
  void applyPrice(double price, int epochSeconds) {
    if (price <= 0) return;
    final bucket = timeframe.bucketStart(epochSeconds);
    if (_candles.isEmpty) {
      _candles.add(
        Candle(
          openTime: bucket,
          open: price,
          high: price,
          low: price,
          close: price,
          volume: 0,
          amount: 0,
        ),
      );
      return;
    }
    final last = _candles.last;
    if (bucket == last.openTime) {
      _candles[_candles.length - 1] = last.copyWithPrice(price);
    } else if (bucket > last.openTime) {
      _candles.add(
        Candle(
          openTime: bucket,
          open: price,
          high: price,
          low: price,
          close: price,
          volume: 0,
          amount: 0,
        ),
      );
      _trim();
    }
  }

  /// 指標を出すのに十分な本数があるか。
  bool hasEnough(int bars) => _candles.length >= bars;

  void _trim() {
    final overflow = _candles.length - maxBars;
    if (overflow > 0) _candles.removeRange(0, overflow);
  }
}
