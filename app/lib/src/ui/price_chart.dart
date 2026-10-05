import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import 'format.dart';

/// チャートに重ねる横線。
class PriceLine {
  const PriceLine({
    required this.price,
    required this.label,
    required this.color,
    this.dashed = false,
    this.emphasized = false,
  });

  final double price;
  final String label;
  final Color color;
  final bool dashed;

  /// いま動かしている線。太く描く。
  final bool emphasized;
}

/// 足して描くバンド / EMA の色。σ や期間ごとに決めておき、どのチャートでも同じ色にする。
Color _extraColor(num key) => switch (key) {
  1 => const Color(0xFF90A4AE),
  2 => const Color(0xFF64B5F6),
  3 => const Color(0xFFBA68C8),
  4 => const Color(0xFFFF8A65),
  5 => const Color(0xFFA1887F),
  20 => const Color(0xFF4DD0E1),
  50 => const Color(0xFFFFB74D),
  100 => const Color(0xFFF06292),
  150 => const Color(0xFF4FC3F7),
  200 => const Color(0xFFFFF176),
  _ => const Color(0xFF9E9E9E),
};

String _trimNumber(double v) {
  final text = v.toString();
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// ローソク足に、ボリンジャーバンド・EMA・横線を重ねて描く。
///
/// fl_chart のローソク足には線を重ねにくいので、自前で描いている。
/// 自分で座標を持つぶん、なぞった位置を値段へ正確に戻せる。
///
/// 指標は渡されたローソク全部で計算し、描くのは直近 [visibleBars] 本だけ。
/// EMA150 のような長い期間は、描く範囲より前の足が無いと正しく出ないため。
class PriceChart extends StatelessWidget {
  const PriceChart({
    super.key,
    required this.candles,
    required this.bbPeriod,
    required this.bbSigma,
    required this.emaPeriod,
    this.sigmas = const [],
    this.extraEmas = const [],
    this.visibleBars = defaultVisibleBars,
    this.lines = const [],
    this.onDragPrice,
    this.height = 280,
  });

  /// 描く本数の既定。取るのはこれより多め (長い EMA の助走ぶん)。
  static const int defaultVisibleBars = 200;

  final List<Candle> candles;

  /// バンドの期間と、判定に使う σ (選ばれていれば太く描く)。
  final int bbPeriod;
  final double bbSigma;

  /// 利確に使う EMA。いつも描く。
  final int emaPeriod;

  /// 描くバンドの σ と、足して描く EMA の期間 (チャートの「線の表示」で選ぶ)。
  final List<double> sigmas;
  final List<int> extraEmas;

  final int visibleBars;
  final List<PriceLine> lines;

  /// 上下になぞったときに、その位置の値段を返す。null なら動かせない。
  final ValueChanged<double>? onDragPrice;

  final double height;

  /// 右の値段ラベルに使う幅。
  static const double priceAxisWidth = 58;

  /// 下の時刻ラベルに使う高さ。
  static const double timeAxisHeight = 16;

  static const double _topPadding = 6;

  @override
  Widget build(BuildContext context) {
    if (candles.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(child: Text('データがありません')),
      );
    }

    final theme = Theme.of(context);
    final closes = [for (final c in candles) c.close];
    final start = math.max(0, candles.length - visibleBars);
    List<T> tail<T>(List<T> values) => values.sublist(start);

    final shown = tail(candles);
    final bands = tail(_bollingerSeries(closes, bbPeriod, bbSigma));
    final showStrategy = sigmas.contains(bbSigma);
    final emas = tail(_reliableEma(closes, emaPeriod));
    // σ を変えても平均と標準偏差は同じなので、判定のバンドから引き直す。
    final others = {
      for (final s in sigmas)
        if (s > 0 && s != bbSigma) s,
    }.toList()..sort();
    final extraBands = [
      for (final s in others)
        (
          upper: [
            for (final b in bands)
              b == null ? null : b.middle + b.deviation * s,
          ],
          lower: [
            for (final b in bands)
              b == null ? null : b.middle - b.deviation * s,
          ],
          color: _extraColor(s),
        ),
    ];
    final periods = {
      for (final p in extraEmas)
        if (p > 1 && p != emaPeriod) p,
    }.toList()..sort();
    final extraEmaLines = [
      for (final p in periods)
        (values: tail(_reliableEma(closes, p)), color: _extraColor(p)),
    ];

    // 値幅は、ローソク・バンド・横線がすべて入るように取る。
    var minPrice = double.infinity;
    var maxPrice = double.negativeInfinity;
    for (final c in shown) {
      minPrice = math.min(minPrice, c.low);
      maxPrice = math.max(maxPrice, c.high);
    }
    for (final b in bands) {
      if (b == null || !showStrategy) continue;
      minPrice = math.min(minPrice, b.lower);
      maxPrice = math.max(maxPrice, b.upper);
    }
    for (final band in extraBands) {
      for (final v in [...band.upper, ...band.lower]) {
        if (v == null) continue;
        minPrice = math.min(minPrice, v);
        maxPrice = math.max(maxPrice, v);
      }
    }
    for (final line in lines) {
      minPrice = math.min(minPrice, line.price);
      maxPrice = math.max(maxPrice, line.price);
    }
    if (!minPrice.isFinite || !maxPrice.isFinite || maxPrice <= minPrice) {
      return SizedBox(
        height: height,
        child: const Center(child: Text('値幅を計算出来ません')),
      );
    }
    final pad = (maxPrice - minPrice) * 0.06;
    minPrice -= pad;
    maxPrice += pad;

    final plotHeight = height - _topPadding - timeAxisHeight;

    double priceAt(double localY) {
      final ratio = ((localY - _topPadding) / plotHeight).clamp(0.0, 1.0);
      return maxPrice - (maxPrice - minPrice) * ratio;
    }

    final painter = CustomPaint(
      size: Size.infinite,
      painter: _PriceChartPainter(
        candles: shown,
        bands: bands,
        emas: emas,
        showStrategyBand: showStrategy,
        showMiddle: showStrategy || others.isNotEmpty,
        extraBands: extraBands,
        extraEmas: extraEmaLines,
        lines: lines,
        minPrice: minPrice,
        maxPrice: maxPrice,
        topPadding: _topPadding,
        timeAxisHeight: timeAxisHeight,
        priceAxisWidth: priceAxisWidth,
        gridColor: theme.dividerColor.withValues(alpha: 0.35),
        textColor: theme.colorScheme.onSurfaceVariant,
        upColor: const Color(0xFF26A69A),
        downColor: const Color(0xFFEF5350),
        bandColor: theme.colorScheme.tertiary,
        emaColor: theme.colorScheme.primary,
      ),
    );

    final chart = onDragPrice == null
        ? SizedBox(height: height, child: painter)
        : SizedBox(
            height: height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) =>
                  onDragPrice!(priceAt(details.localPosition.dy)),
              onTapDown: (details) =>
                  onDragPrice!(priceAt(details.localPosition.dy)),
              child: painter,
            ),
          );

    // どの線が何かを、チャートのすぐ下に小さく出す。
    final legend = <(String, Color)>[
      if (showStrategy)
        (
          'BB($bbPeriod) ${_trimNumber(bbSigma)}σ (判定)',
          theme.colorScheme.tertiary,
        ),
      for (final s in others) ('${_trimNumber(s)}σ', _extraColor(s)),
      ('EMA$emaPeriod (利確)', theme.colorScheme.primary),
      for (final p in periods) ('EMA$p', _extraColor(p)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        chart,
        const SizedBox(height: 4),
        Wrap(
          spacing: 10,
          runSpacing: 2,
          children: [
            for (final (label, color) in legend)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 12, height: 2, color: color),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  /// 正しい値になった所からの EMA。それより前は null (描かない)。
  ///
  /// EMA は最初の [period] 本の平均から始めるので、始めてすぐは取れなかった
  /// 過去の足の分だけずれている。期間の 2 倍の足を重ねれば、始めの影響は
  /// 2% 未満になるので、そこから描く。
  static List<double?> _reliableEma(List<double> closes, int period) {
    final series = Indicators.emaSeries(closes, period);
    final first = period - 1 + period * 2;
    for (var i = 0; i < series.length && i < first; i++) {
      series[i] = null;
    }
    return series;
  }

  /// 各時点のボリンジャーバンド。先頭 [period]-1 本は null。
  static List<BollingerPoint?> _bollingerSeries(
    List<double> closes,
    int period,
    double sigma,
  ) {
    final out = List<BollingerPoint?>.filled(closes.length, null);
    if (period < 2 || closes.length < period) return out;
    for (var i = period - 1; i < closes.length; i++) {
      var sum = 0.0;
      for (var j = i - period + 1; j <= i; j++) {
        sum += closes[j];
      }
      final mean = sum / period;
      var variance = 0.0;
      for (var j = i - period + 1; j <= i; j++) {
        final d = closes[j] - mean;
        variance += d * d;
      }
      // 母標準偏差 (TradingView と同じ)。
      final sd = math.sqrt(variance / period);
      out[i] = BollingerPoint(
        middle: mean,
        upper: mean + sd * sigma,
        lower: mean - sd * sigma,
        deviation: sd,
      );
    }
    return out;
  }
}

class _PriceChartPainter extends CustomPainter {
  _PriceChartPainter({
    required this.candles,
    required this.bands,
    required this.emas,
    required this.showStrategyBand,
    required this.showMiddle,
    required this.extraBands,
    required this.extraEmas,
    required this.lines,
    required this.minPrice,
    required this.maxPrice,
    required this.topPadding,
    required this.timeAxisHeight,
    required this.priceAxisWidth,
    required this.gridColor,
    required this.textColor,
    required this.upColor,
    required this.downColor,
    required this.bandColor,
    required this.emaColor,
  });

  final List<Candle> candles;
  final List<BollingerPoint?> bands;
  final List<double?> emas;
  final bool showStrategyBand;
  final bool showMiddle;
  final List<({List<double?> upper, List<double?> lower, Color color})>
  extraBands;
  final List<({List<double?> values, Color color})> extraEmas;
  final List<PriceLine> lines;
  final double minPrice;
  final double maxPrice;
  final double topPadding;
  final double timeAxisHeight;
  final double priceAxisWidth;
  final Color gridColor;
  final Color textColor;
  final Color upColor;
  final Color downColor;
  final Color bandColor;
  final Color emaColor;

  @override
  void paint(Canvas canvas, Size size) {
    final plotWidth = size.width - priceAxisWidth;
    final plotHeight = size.height - topPadding - timeAxisHeight;
    if (plotWidth <= 0 || plotHeight <= 0 || candles.isEmpty) return;

    double y(double price) =>
        topPadding + (maxPrice - price) / (maxPrice - minPrice) * plotHeight;
    final step = plotWidth / candles.length;
    double x(int i) => (i + 0.5) * step;

    _paintGrid(canvas, plotWidth, y);
    // 値幅に入らない線 (遠く離れた EMA など) が枠の外へはみ出さないよう、
    // ローソクと指標は描く範囲で切り取る。
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, topPadding, plotWidth, plotHeight));
    _paintCandles(canvas, step, x, y);
    _paintIndicators(canvas, x, y);
    canvas.restore();
    _paintLines(canvas, size, plotWidth, y);
    _paintTimeLabels(canvas, size, plotWidth);
  }

  void _paintGrid(Canvas canvas, double plotWidth, double Function(double) y) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    // 値段の目盛りを4本引き、右端に数字を出す。
    for (var i = 0; i <= 4; i++) {
      final price = minPrice + (maxPrice - minPrice) * i / 4;
      final yy = y(price);
      canvas.drawLine(Offset(0, yy), Offset(plotWidth, yy), grid);
      _text(
        canvas,
        formatPrice(price),
        Offset(plotWidth + 4, yy - 6),
        color: textColor,
        size: 9,
      );
    }
  }

  void _paintCandles(
    Canvas canvas,
    double step,
    double Function(int) x,
    double Function(double) y,
  ) {
    final bodyWidth = math.max(1.0, step * 0.62);
    for (var i = 0; i < candles.length; i++) {
      final c = candles[i];
      final up = c.close >= c.open;
      final paint = Paint()
        ..color = up ? upColor : downColor
        ..strokeWidth = math.max(1.0, step * 0.12);
      final cx = x(i);
      // ひげ
      canvas.drawLine(Offset(cx, y(c.high)), Offset(cx, y(c.low)), paint);
      // 実体
      final top = y(math.max(c.open, c.close));
      final bottom = y(math.min(c.open, c.close));
      final rect = Rect.fromLTRB(
        cx - bodyWidth / 2,
        top,
        cx + bodyWidth / 2,
        math.max(bottom, top + 1),
      );
      canvas.drawRect(rect, Paint()..color = paint.color);
    }
  }

  void _paintIndicators(
    Canvas canvas,
    double Function(int) x,
    double Function(double) y,
  ) {
    void stroke(List<double?> values, Color color, double width) {
      final path = Path();
      var started = false;
      for (var i = 0; i < values.length; i++) {
        final v = values[i];
        if (v == null) {
          started = false;
          continue;
        }
        final p = Offset(x(i), y(v));
        if (!started) {
          path.moveTo(p.dx, p.dy);
          started = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = width
          ..style = PaintingStyle.stroke,
      );
    }

    // 足したバンドを先に描き、判定のバンドを上に重ねる。
    for (final band in extraBands) {
      stroke(band.upper, band.color.withValues(alpha: 0.85), 0.9);
      stroke(band.lower, band.color.withValues(alpha: 0.85), 0.9);
    }
    if (showStrategyBand) {
      stroke([for (final b in bands) b?.upper], bandColor, 1.2);
      stroke([for (final b in bands) b?.lower], bandColor, 1.2);
    }
    if (showMiddle) {
      stroke(
        [for (final b in bands) b?.middle],
        bandColor.withValues(alpha: 0.45),
        1,
      );
    }
    for (final ema in extraEmas) {
      stroke(ema.values, ema.color, 1.1);
    }
    stroke(emas, emaColor, 1.4);
  }

  void _paintLines(
    Canvas canvas,
    Size size,
    double plotWidth,
    double Function(double) y,
  ) {
    for (final line in lines) {
      final yy = y(line.price);
      if (yy.isNaN) continue;
      final paint = Paint()
        ..color = line.color
        ..strokeWidth = line.emphasized ? 2.2 : 1.3;
      if (line.dashed) {
        const dash = 6.0;
        const gap = 4.0;
        var dx = 0.0;
        while (dx < plotWidth) {
          canvas.drawLine(
            Offset(dx, yy),
            Offset(math.min(dx + dash, plotWidth), yy),
            paint,
          );
          dx += dash + gap;
        }
      } else {
        canvas.drawLine(Offset(0, yy), Offset(plotWidth, yy), paint);
      }
      _text(
        canvas,
        line.label,
        Offset(2, yy - 12),
        color: line.color,
        size: 10,
        bold: true,
      );
    }
  }

  void _paintTimeLabels(Canvas canvas, Size size, double plotWidth) {
    if (candles.length < 2) return;
    final yy = size.height - timeAxisHeight + 2;
    _text(
      canvas,
      _time(candles.first.openTime),
      Offset(0, yy),
      color: textColor,
      size: 9,
    );
    final last = _time(candles.last.openTime);
    _text(
      canvas,
      last,
      Offset(plotWidth - last.length * 5.2, yy),
      color: textColor,
      size: 9,
    );
  }

  String _time(int epochSeconds) {
    final t = DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
    ).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}/${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    required Color color,
    required double size,
    bool bold = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_PriceChartPainter old) =>
      old.candles != candles ||
      old.lines != lines ||
      old.extraBands != extraBands ||
      old.extraEmas != extraEmas ||
      old.minPrice != minPrice ||
      old.maxPrice != maxPrice;
}
