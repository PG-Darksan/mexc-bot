import 'dart:math' as math;

import 'package:meta/meta.dart';

/// ボリンジャーバンドの 1 点。
@immutable
class BollingerPoint {
  const BollingerPoint({
    required this.middle,
    required this.upper,
    required this.lower,
    required this.deviation,
  });

  /// 単純移動平均。
  final double middle;

  /// +σ 側。
  final double upper;

  /// -σ 側。
  final double lower;

  /// 標準偏差そのもの。
  final double deviation;
}

/// テクニカル指標。
///
/// TradingView と値を揃えるため、
/// * ボリンジャーバンドの標準偏差は **母標準偏差** (n で割る)
/// * RSI は **Wilder 平滑** (alpha = 1/period、初期値は period 本目の SMA)
/// を採用している。標本標準偏差 (n-1) や SMA 平滑にすると値がずれる。
class Indicators {
  const Indicators._();

  /// 指数移動平均の系列を返す。先頭 [period]-1 本は null。
  ///
  /// 初期値は [period] 本目の SMA をシードにする (TradingView の ta.ema と同じ)。
  static List<double?> emaSeries(List<double> values, int period) {
    final out = List<double?>.filled(values.length, null);
    if (period < 1 || values.length < period) return out;
    final k = 2.0 / (period + 1);
    var sum = 0.0;
    for (var i = 0; i < period; i++) {
      sum += values[i];
    }
    var prev = sum / period;
    out[period - 1] = prev;
    for (var i = period; i < values.length; i++) {
      prev = values[i] * k + prev * (1 - k);
      out[i] = prev;
    }
    return out;
  }

  /// 最新の EMA 値。計算できなければ null。
  static double? ema(List<double> values, int period) =>
      emaSeries(values, period).lastOrNull_;

  /// Wilder 平滑の RSI 系列。先頭 [period] 本は null。
  static List<double?> rsiSeries(List<double> values, int period) {
    final out = List<double?>.filled(values.length, null);
    if (period < 1 || values.length < period + 1) return out;

    var gainSum = 0.0;
    var lossSum = 0.0;
    for (var i = 1; i <= period; i++) {
      final diff = values[i] - values[i - 1];
      if (diff >= 0) {
        gainSum += diff;
      } else {
        lossSum -= diff;
      }
    }
    var avgGain = gainSum / period;
    var avgLoss = lossSum / period;
    out[period] = _rsiFrom(avgGain, avgLoss);

    for (var i = period + 1; i < values.length; i++) {
      final diff = values[i] - values[i - 1];
      final gain = diff > 0 ? diff : 0.0;
      final loss = diff < 0 ? -diff : 0.0;
      avgGain = (avgGain * (period - 1) + gain) / period;
      avgLoss = (avgLoss * (period - 1) + loss) / period;
      out[i] = _rsiFrom(avgGain, avgLoss);
    }
    return out;
  }

  /// 最新の RSI 値。計算できなければ null。
  static double? rsi(List<double> values, int period) =>
      rsiSeries(values, period).lastOrNull_;

  static double _rsiFrom(double avgGain, double avgLoss) {
    if (avgLoss == 0) return avgGain == 0 ? 50.0 : 100.0;
    final rs = avgGain / avgLoss;
    return 100 - 100 / (1 + rs);
  }

  /// ボリンジャーバンドの系列。先頭 [period]-1 本は null。
  static List<BollingerPoint?> bollingerSeries(
    List<double> values,
    int period,
    double sigma,
  ) {
    final out = List<BollingerPoint?>.filled(values.length, null);
    if (period < 2 || values.length < period) return out;
    for (var i = period - 1; i < values.length; i++) {
      out[i] = _bollingerAt(values, i, period, sigma);
    }
    return out;
  }

  /// 最新のボリンジャーバンド。計算できなければ null。
  static BollingerPoint? bollinger(
    List<double> values,
    int period,
    double sigma,
  ) {
    if (period < 2 || values.length < period) return null;
    return _bollingerAt(values, values.length - 1, period, sigma);
  }

  /// 桁落ちを避けるため、毎回 2 パスで平均と分散を出す。
  /// 期間は高々数十本なので、オンライン更新にする利点はない。
  static BollingerPoint _bollingerAt(
    List<double> values,
    int index,
    int period,
    double sigma,
  ) {
    final start = index - period + 1;
    var sum = 0.0;
    for (var i = start; i <= index; i++) {
      sum += values[i];
    }
    final mean = sum / period;
    var sqSum = 0.0;
    for (var i = start; i <= index; i++) {
      final diff = values[i] - mean;
      sqSum += diff * diff;
    }
    // 母標準偏差 (TradingView の ta.stdev と同じ)。
    final sd = math.sqrt(sqSum / period);
    return BollingerPoint(
      middle: mean,
      upper: mean + sigma * sd,
      lower: mean - sigma * sd,
      deviation: sd,
    );
  }
}

extension _LastOrNull on List<double?> {
  double? get lastOrNull_ => isEmpty ? null : this[length - 1];
}
