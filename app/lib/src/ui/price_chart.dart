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

/// ローソク足に、ボリンジャーバンド・EMA・横線を重ねて描く。
///
/// fl_chart のローソク足には線を重ねにくいので、自前で描いている。
/// 自分で座標を持つぶん、なぞった位置を値段へ正確に戻せる。
class PriceChart extends StatelessWidget {
  const PriceChart({
    super.key,
    required this.candles,
    required this.bbPeriod,
    required this.bbSigma,
    required this.emaPeriod,
    this.lines = const [],
    this.onDragPrice,
    this.height = 280,
  });

  final List<Candle> candles;
  final int bbPeriod;
  final double bbSigma;
  final int emaPeriod;
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
    final bands = _bollingerSeries(closes, bbPeriod, bbSigma);
    final emas = Indicators.emaSeries(closes, emaPeriod);

    // 値幅は、ローソク・バンド・横線がすべて入るように取る。
    var minPrice = double.infinity;
    var maxPrice = double.negativeInfinity;
    for (final c in candles) {
      minPrice = math.min(minPrice, c.low);
      maxPrice = math.max(maxPrice, c.high);
    }
    for (final b in bands) {
      if (b == null) continue;
      minPrice = math.min(minPrice, b.lower);
      maxPrice = math.max(maxPrice, b.upper);
    }
    for (final line in lines) {
      minPrice = math.min(minPrice, line.price);
      maxPrice = math.max(maxPrice, line.price);
    }
    if (!minPrice.isFinite || !maxPrice.isFinite || maxPrice <= minPrice) {
      return SizedBox(
        height: height,
        child: const Center(child: Text('値幅を計算できません')),
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
        candles: candles,
        bands: bands,
        emas: emas,
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

    if (onDragPrice == null) {
      return SizedBox(height: height, child: painter);
    }
    return SizedBox(
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) =>
            onDragPrice!(priceAt(details.localPosition.dy)),
        onTapDown: (details) => onDragPrice!(priceAt(details.localPosition.dy)),
        child: painter,
      ),
    );
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
    _paintCandles(canvas, step, x, y);
    _paintIndicators(canvas, x, y);
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

    stroke([for (final b in bands) b?.upper], bandColor, 1.2);
    stroke([for (final b in bands) b?.lower], bandColor, 1.2);
    stroke(
      [for (final b in bands) b?.middle],
      bandColor.withValues(alpha: 0.45),
      1,
    );
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
      old.minPrice != minPrice ||
      old.maxPrice != maxPrice;
}
