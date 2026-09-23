import 'package:mexc_core/mexc_core.dart';
import 'package:test/test.dart';

void main() {
  group('EMA', () {
    test('最初の値は期間ぶんのSMAになる', () {
      final ema = Indicators.emaSeries([1, 2, 3, 4, 5], 5);
      expect(ema[3], isNull);
      expect(ema[4], closeTo(3.0, 1e-12));
    });

    test('2本目以降は平滑係数 2/(n+1) で更新される', () {
      final ema = Indicators.emaSeries([1, 2, 3, 4, 5, 6], 5);
      // 3 + (6 - 3) * 2/6 = 4
      expect(ema[5], closeTo(4.0, 1e-12));
    });

    test('本数が足りなければ全部 null', () {
      expect(Indicators.ema([1, 2], 5), isNull);
    });
  });

  group('RSI (Wilder)', () {
    test('上げ続ければ 100', () {
      final values = List<double>.generate(30, (i) => 100.0 + i);
      expect(Indicators.rsi(values, 7), closeTo(100.0, 1e-9));
    });

    test('下げ続ければ 0', () {
      final values = List<double>.generate(30, (i) => 200.0 - i);
      expect(Indicators.rsi(values, 7), closeTo(0.0, 1e-9));
    });

    test('平滑は alpha = 1/period (EMA の 2/(n+1) ではない)', () {
      // 14 本上げたあと 1 本だけ下げる。Wilder 平滑での値を手計算で確認する。
      final values = <double>[for (var i = 0; i <= 14; i++) 100.0 + i, 108.0];
      final period = 14;
      // 最初の 14 本の平均上昇 = 1.0、平均下落 = 0。
      // 最後の 1 本で -6 → avgGain = 1*13/14, avgLoss = 6/14。
      final avgGain = 1.0 * 13 / 14;
      final avgLoss = 6.0 / 14;
      final expected = 100 - 100 / (1 + avgGain / avgLoss);
      expect(Indicators.rsi(values, period), closeTo(expected, 1e-9));
    });

    test('本数が足りなければ null', () {
      expect(Indicators.rsi([1, 2, 3], 7), isNull);
    });
  });

  group('ボリンジャーバンド', () {
    test('母標準偏差 (n で割る) で計算する', () {
      // 平均 5、母分散 4、母標準偏差 2 になる並び。
      final values = <double>[2, 4, 4, 4, 5, 5, 7, 9];
      final bb = Indicators.bollinger(values, 8, 1)!;
      expect(bb.middle, closeTo(5.0, 1e-12));
      expect(bb.deviation, closeTo(2.0, 1e-12));
      expect(bb.upper, closeTo(7.0, 1e-12));
      expect(bb.lower, closeTo(3.0, 1e-12));
    });

    test('標本標準偏差 (n-1) にはなっていない', () {
      final values = <double>[2, 4, 4, 4, 5, 5, 7, 9];
      final bb = Indicators.bollinger(values, 8, 1)!;
      // 標本標準偏差なら 2.138...。母標準偏差の 2.0 と区別できること。
      expect(bb.deviation, lessThan(2.1));
    });

    test('σ倍率が反映される', () {
      final values = <double>[2, 4, 4, 4, 5, 5, 7, 9];
      final bb = Indicators.bollinger(values, 8, 4)!;
      expect(bb.upper, closeTo(5 + 8, 1e-12));
    });
  });

  group('CandleSeries', () {
    Candle c(int t, double close) => Candle(
      openTime: t,
      open: close,
      high: close,
      low: close,
      close: close,
      volume: 0,
      amount: 0,
    );

    test('同じ開始時刻なら置き換える', () {
      final series = CandleSeries(symbol: 'X_USDT', timeframe: Timeframe.m15);
      series.upsert(c(900, 10));
      series.upsert(c(900, 11));
      expect(series.length, 1);
      expect(series.last!.close, 11);
    });

    test('新しい足は追加される', () {
      final series = CandleSeries(symbol: 'X_USDT', timeframe: Timeframe.m15);
      series.upsert(c(900, 10));
      series.upsert(c(1800, 12));
      expect(series.length, 2);
      expect(series.closes, [10, 12]);
    });

    test('最新価格で進行中の足を更新できる', () {
      final series = CandleSeries(symbol: 'X_USDT', timeframe: Timeframe.m15);
      series.upsert(c(900, 10));
      series.applyPrice(15, 1000); // 900 のバケット内
      expect(series.length, 1);
      expect(series.last!.close, 15);
      expect(series.last!.high, 15);
    });

    test('バケットをまたぐと新しい足になる', () {
      final series = CandleSeries(symbol: 'X_USDT', timeframe: Timeframe.m15);
      series.upsert(c(900, 10));
      series.applyPrice(20, 1900); // 1800 のバケット
      expect(series.length, 2);
      expect(series.last!.openTime, 1800);
      expect(series.last!.open, 20);
    });

    test('maxBars を超えたら古い足を捨てる', () {
      final series = CandleSeries(
        symbol: 'X_USDT',
        timeframe: Timeframe.m15,
        maxBars: 3,
      );
      for (var i = 0; i < 10; i++) {
        series.upsert(c(900 * (i + 1), i.toDouble()));
      }
      expect(series.length, 3);
      expect(series.closes, [7, 8, 9]);
    });
  });

  group('Timeframe', () {
    test('足の開始時刻を求められる', () {
      expect(Timeframe.m15.bucketStart(1000), 900);
      expect(Timeframe.h1.bucketStart(3700), 3600);
      expect(Timeframe.h4.bucketStart(14401), 14400);
      expect(Timeframe.d1.bucketStart(86401), 86400);
    });

    test('MEXC の interval 文字列と往復できる', () {
      for (final tf in Timeframe.values) {
        expect(Timeframe.fromInterval(tf.interval), tf);
        expect(Timeframe.fromName(tf.name), tf);
      }
    });
  });
}
