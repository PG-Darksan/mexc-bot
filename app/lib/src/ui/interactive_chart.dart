import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../data/chart_drawing.dart';
import 'format.dart';
import 'price_chart.dart';

/// チャートの上で指を動かしたときに何をするか。
enum ChartTool {
  /// なぞると過去へ動く。タップで値段を拾う。
  none,

  /// タップした値段に横線を引く。
  horizontal,

  /// 2 回タップした 2 点を結ぶ線を引く。
  trend,

  /// タップした線を消す。
  erase,
}

/// 描く範囲 (何本を、どこまで過去へずらして描くか)。
///
/// 画面と指の動きの両方から書き換えるので、チャートの外に持たせる。
class ChartViewport extends ChangeNotifier {
  ChartViewport({double visibleBars = 120, double rightOffset = -3})
    : _visibleBars = visibleBars,
      _rightOffset = rightOffset;

  /// 描くのに使う本数 (小数のまま持つと、ピンチが滑らかになる)。
  double _visibleBars;

  /// 右端から何本ぶん過去へずらしているか。負なら右に空きを置く。
  double _rightOffset;

  static const double minBars = 10;

  double get visibleBars => _visibleBars;
  double get rightOffset => _rightOffset;

  /// いちばん新しい足が右端に見えているか (新しい足が来たら付いていく)。
  bool get followsLatest => _rightOffset <= 0.5;

  void update({double? visibleBars, double? rightOffset}) {
    final v = visibleBars ?? _visibleBars;
    final r = rightOffset ?? _rightOffset;
    if (v == _visibleBars && r == _rightOffset) return;
    _visibleBars = v;
    _rightOffset = r;
    notifyListeners();
  }

  /// 本数を決めて、いちばん新しい足を右端に戻す。
  void showLatest(double visibleBars) {
    _visibleBars = visibleBars;
    _rightOffset = -3;
    notifyListeners();
  }
}

/// 取引画面のチャート。
///
/// * 2 本指でつまむと拡大・縮小 (本数が変わる)、1 本指でなぞると過去へ動く。
///   パソコンではホイールで拡大・縮小、ドラッグで動かす。
/// * タップすると、その値段と時刻を返す (注文の値段に使う)。長押しは
///   「ここで何をするか」の選択肢を出すために返す。
/// * [tool] で、横線・2 点の線を引く / 消す。
/// * 値幅は「いま見えている足」で決める。範囲の外にある横線 (遠い利確など)
///   は上下の端に矢印で出す (全部入れるとローソクが潰れて見えなくなるため)。
class InteractiveChart extends StatefulWidget {
  const InteractiveChart({
    super.key,
    required this.candles,
    required this.viewport,
    required this.bbPeriod,
    required this.bbSigma,
    required this.emaPeriod,
    this.sigmas = const [],
    this.extraEmas = const [],
    this.lines = const [],
    this.drawings = const [],
    this.tool = ChartTool.none,
    this.drawColor = ChartDrawing.defaultColor,
    this.onTapPrice,
    this.onLongPressPrice,
    this.onDrawingsChanged,
    this.onViewportSettled,
  });

  final List<Candle> candles;
  final ChartViewport viewport;
  final int bbPeriod;
  final double bbSigma;
  final int emaPeriod;
  final List<double> sigmas;
  final List<int> extraEmas;
  final List<PriceLine> lines;
  final List<ChartDrawing> drawings;
  final ChartTool tool;
  final Color drawColor;

  /// 普通の状態でタップした所の値段と時刻 (エポック秒)。
  final void Function(double price, int time)? onTapPrice;

  /// 長押しを離した所の値段と時刻。
  final void Function(double price, int time)? onLongPressPrice;

  /// 線を引いた / 消したとき。全部の線を渡す。
  final ValueChanged<List<ChartDrawing>>? onDrawingsChanged;

  /// ピンチやなぞりが終わったとき (本数を覚えるのに使う)。
  final VoidCallback? onViewportSettled;

  static const double priceAxisWidth = 66;
  static const double timeAxisHeight = 18;
  static const double topPadding = 8;

  @override
  State<InteractiveChart> createState() => _InteractiveChartState();
}

class _InteractiveChartState extends State<InteractiveChart> {
  // 指標は足全部で計算しておき、描くときに見えている分だけ使う。
  List<BollingerPoint?> _bands = const [];
  List<double?> _ema = const [];
  List<({List<double?> values, Color color})> _extraEmas = const [];

  double _startBars = 0;
  double _startOffset = 0;
  double _startFocalX = 0;
  double _startFocalIndex = 0;

  /// 指で押さえている所 (十字線を出す)。
  Offset? _crosshair;

  /// 2 点の線の 1 点目。
  ({int time, double price})? _trendStart;

  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _computeIndicators();
    widget.viewport.addListener(_onViewport);
  }

  @override
  void didUpdateWidget(InteractiveChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.viewport, widget.viewport)) {
      old.viewport.removeListener(_onViewport);
      widget.viewport.addListener(_onViewport);
    }
    if (!identical(old.candles, widget.candles) ||
        old.bbPeriod != widget.bbPeriod ||
        old.bbSigma != widget.bbSigma ||
        old.emaPeriod != widget.emaPeriod ||
        !_sameList(old.extraEmas, widget.extraEmas)) {
      _computeIndicators();
    }
    if (old.tool != widget.tool) _trendStart = null;
  }

  @override
  void dispose() {
    widget.viewport.removeListener(_onViewport);
    super.dispose();
  }

  static bool _sameList<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _onViewport() => setState(() {});

  void _computeIndicators() {
    final closes = [for (final c in widget.candles) c.close];
    _bands = PriceChart.bollingerSeries(closes, widget.bbPeriod, widget.bbSigma);
    _ema = PriceChart.reliableEma(closes, widget.emaPeriod);
    final periods = {
      for (final p in widget.extraEmas)
        if (p > 1 && p != widget.emaPeriod) p,
    }.toList()..sort();
    _extraEmas = [
      for (final p in periods)
        (values: PriceChart.reliableEma(closes, p), color: chartLineColor(p)),
    ];
  }

  // ── 座標 ────────────────────────────────────────────────────

  int get _count => widget.candles.length;
  double get _plotWidth =>
      math.max(1, _size.width - InteractiveChart.priceAxisWidth);
  double get _plotHeight => math.max(
    1,
    _size.height -
        InteractiveChart.topPadding -
        InteractiveChart.timeAxisHeight,
  );

  double get _barWidth => _plotWidth / widget.viewport.visibleBars;

  /// 右端の足の番号 (小数。足の数より大きければ右に空きがある)。
  double get _endIndex => _count - 1 - widget.viewport.rightOffset;

  double _xOfIndex(double i) => _plotWidth - (_endIndex - i + 0.5) * _barWidth;

  double _indexAtX(double x) => _endIndex - ((_plotWidth - x) / _barWidth - 0.5);

  /// 足 1 本の長さ (秒)。2 本以上なければ 1 時間とみなす。
  int get _interval {
    final c = widget.candles;
    if (c.length < 2) return 3600;
    final d = c[c.length - 1].openTime - c[c.length - 2].openTime;
    return d > 0 ? d : 3600;
  }

  /// 足の番号 (小数) → 時刻 (エポック秒)。足の外は間隔で延ばす。
  int _timeOfIndex(double i) {
    final c = widget.candles;
    if (c.isEmpty) return 0;
    if (i <= 0) return c.first.openTime + (i * _interval).round();
    if (i >= c.length - 1) {
      return c.last.openTime + ((i - (c.length - 1)) * _interval).round();
    }
    final lo = i.floor();
    final frac = i - lo;
    return c[lo].openTime + ((c[lo + 1].openTime - c[lo].openTime) * frac).round();
  }

  /// 時刻 → 足の番号 (小数)。
  double _indexOfTime(int t) {
    final c = widget.candles;
    if (c.isEmpty) return 0;
    if (t <= c.first.openTime) return (t - c.first.openTime) / _interval;
    if (t >= c.last.openTime) {
      return c.length - 1 + (t - c.last.openTime) / _interval;
    }
    var lo = 0;
    var hi = c.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (c[mid].openTime <= t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = c[hi].openTime - c[lo].openTime;
    return lo + (span == 0 ? 0 : (t - c[lo].openTime) / span);
  }

  ({double min, double max}) _priceRange() {
    final c = widget.candles;
    final from = math.max(0, (_endIndex - widget.viewport.visibleBars).floor());
    final to = math.min(c.length - 1, _endIndex.ceil());
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (var i = from; i <= to; i++) {
      lo = math.min(lo, c[i].low);
      hi = math.max(hi, c[i].high);
    }
    if (widget.sigmas.contains(widget.bbSigma)) {
      for (var i = from; i <= to && i < _bands.length; i++) {
        final b = _bands[i];
        if (b == null) continue;
        lo = math.min(lo, b.lower);
        hi = math.max(hi, b.upper);
      }
    }
    if (!lo.isFinite || !hi.isFinite) {
      final last = c.isEmpty ? 1.0 : c.last.close;
      lo = last * 0.99;
      hi = last * 1.01;
    }
    if (hi <= lo) {
      hi = lo * 1.01 + 1e-9;
      lo = lo * 0.99;
    }
    final pad = (hi - lo) * 0.08;
    return (min: lo - pad, max: hi + pad);
  }

  double _priceAtY(double y, ({double min, double max}) range) {
    final ratio = (y - InteractiveChart.topPadding) / _plotHeight;
    return range.max - (range.max - range.min) * ratio;
  }

  double _yOfPrice(double price, ({double min, double max}) range) =>
      InteractiveChart.topPadding +
      (range.max - price) / (range.max - range.min) * _plotHeight;

  ({double price, int time}) _pointAt(Offset p) {
    final range = _priceRange();
    return (
      price: _priceAtY(p.dy, range),
      time: _timeOfIndex(_indexAtX(p.dx).roundToDouble()),
    );
  }

  // ── 指の動き ────────────────────────────────────────────────

  double get _maxOffset =>
      math.max(0.0, _count - widget.viewport.visibleBars * 0.2);
  double get _minOffset => -math.max(3.0, widget.viewport.visibleBars * 0.5);
  double get _maxBars => math.max(ChartViewport.minBars, _count + 10.0);

  void _onScaleStart(ScaleStartDetails d) {
    _startBars = widget.viewport.visibleBars;
    _startOffset = widget.viewport.rightOffset;
    _startFocalX = d.localFocalPoint.dx;
    _startFocalIndex = _indexAtX(_startFocalX);
    setState(() => _crosshair = null);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_size == Size.zero || _count == 0) return;
    if (d.pointerCount >= 2 && d.scale > 0) {
      // つまんだ所の足が、指の下から動かないように本数とずれを決める。
      final bars = (_startBars / d.scale).clamp(ChartViewport.minBars, _maxBars);
      final barWidth = _plotWidth / bars;
      final focalX = d.localFocalPoint.dx;
      final end = _startFocalIndex + ((_plotWidth - focalX) / barWidth - 0.5);
      final offset = (_count - 1 - end)
          .clamp(-math.max(3.0, bars * 0.5), math.max(0.0, _count - bars * 0.2))
          .toDouble();
      widget.viewport.update(visibleBars: bars, rightOffset: offset);
    } else {
      final dx = d.localFocalPoint.dx - _startFocalX;
      final offset = (_startOffset + dx / _barWidth).clamp(_minOffset, _maxOffset);
      widget.viewport.update(rightOffset: offset);
    }
  }

  void _onScaleEnd(ScaleEndDetails d) => widget.onViewportSettled?.call();

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _count == 0) return;
    // ホイールを手前に回すと縮小 (本数が増える)。
    final factor = event.scrollDelta.dy > 0 ? 1.15 : 1 / 1.15;
    final focalIndex = _indexAtX(event.localPosition.dx);
    final bars = (widget.viewport.visibleBars * factor).clamp(
      ChartViewport.minBars,
      _maxBars,
    );
    final barWidth = _plotWidth / bars;
    final end =
        focalIndex + ((_plotWidth - event.localPosition.dx) / barWidth - 0.5);
    final offset = (_count - 1 - end)
        .clamp(-math.max(3.0, bars * 0.5), math.max(0.0, _count - bars * 0.2))
        .toDouble();
    widget.viewport.update(visibleBars: bars, rightOffset: offset);
    widget.onViewportSettled?.call();
  }

  void _onTapUp(TapUpDetails d) {
    if (_count == 0) return;
    final local = d.localPosition;
    if (local.dx > _plotWidth) return;
    final point = _pointAt(local);
    switch (widget.tool) {
      case ChartTool.none:
        setState(() => _crosshair = local);
        widget.onTapPrice?.call(point.price, point.time);
      case ChartTool.horizontal:
        widget.onDrawingsChanged?.call([
          ...widget.drawings,
          ChartDrawing.horizontal(point.price, color: widget.drawColor),
        ]);
      case ChartTool.trend:
        final start = _trendStart;
        if (start == null) {
          setState(() => _trendStart = (time: point.time, price: point.price));
        } else {
          setState(() => _trendStart = null);
          if (start.time != point.time) {
            widget.onDrawingsChanged?.call([
              ...widget.drawings,
              ChartDrawing.trend(
                timeA: start.time,
                priceA: start.price,
                timeB: point.time,
                priceB: point.price,
                color: widget.drawColor,
              ),
            ]);
          }
        }
      case ChartTool.erase:
        final hit = _drawingAt(local);
        if (hit != null) {
          widget.onDrawingsChanged?.call([
            for (final d in widget.drawings)
              if (d.id != hit.id) d,
          ]);
        }
    }
  }

  /// [p] のそばにある線 (14px 以内でいちばん近いもの)。
  ChartDrawing? _drawingAt(Offset p) {
    final range = _priceRange();
    ChartDrawing? best;
    var bestDist = 14.0;
    for (final d in widget.drawings) {
      double dist;
      if (d.kind == DrawingKind.horizontal) {
        dist = (p.dy - _yOfPrice(d.price1, range)).abs();
      } else {
        final a = Offset(
          _xOfIndex(_indexOfTime(d.time1!)),
          _yOfPrice(d.price1, range),
        );
        final b = Offset(
          _xOfIndex(_indexOfTime(d.time2!)),
          _yOfPrice(d.price2!, range),
        );
        dist = _distanceToRay(p, a, b);
      }
      if (dist < bestDist) {
        bestDist = dist;
        best = d;
      }
    }
    return best;
  }

  /// a から b を通って右へ伸びる線までの距離。
  static double _distanceToRay(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = math.max(0.0, ((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2);
    return (p - (a + ab * t)).distance;
  }

  void _onLongPressStart(LongPressStartDetails d) =>
      setState(() => _crosshair = d.localPosition);

  void _onLongPressMove(LongPressMoveUpdateDetails d) =>
      setState(() => _crosshair = d.localPosition);

  void _onLongPressEnd(LongPressEndDetails d) {
    if (_count == 0) return;
    final point = _pointAt(d.localPosition);
    widget.onLongPressPrice?.call(point.price, point.time);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.candles.isEmpty) {
      return const Center(child: Text('データがありません'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        final range = _priceRange();
        final crosshair = _crosshair;
        final crossPoint = crosshair == null ? null : _pointAt(crosshair);
        return Listener(
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            onTapUp: _onTapUp,
            onLongPressStart: _onLongPressStart,
            onLongPressMoveUpdate: _onLongPressMove,
            onLongPressEnd: _onLongPressEnd,
            child: CustomPaint(
              size: Size.infinite,
              painter: _TradeChartPainter(
                candles: widget.candles,
                bands: _bands,
                ema: _ema,
                extraEmas: _extraEmas,
                sigmas: widget.sigmas,
                bbSigma: widget.bbSigma,
                lines: widget.lines,
                drawings: widget.drawings,
                trendStart: _trendStart,
                crosshair: crosshair,
                crossPrice: crossPoint?.price,
                crossTime: crossPoint?.time,
                range: range,
                endIndex: _endIndex,
                visibleBars: widget.viewport.visibleBars,
                indexOfTime: _indexOfTime,
                gridColor: theme.dividerColor.withValues(alpha: 0.35),
                textColor: theme.colorScheme.onSurfaceVariant,
                bandColor: theme.colorScheme.tertiary,
                emaColor: theme.colorScheme.primary,
                surfaceColor: theme.colorScheme.surface,
                crossColor: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TradeChartPainter extends CustomPainter {
  _TradeChartPainter({
    required this.candles,
    required this.bands,
    required this.ema,
    required this.extraEmas,
    required this.sigmas,
    required this.bbSigma,
    required this.lines,
    required this.drawings,
    required this.trendStart,
    required this.crosshair,
    required this.crossPrice,
    required this.crossTime,
    required this.range,
    required this.endIndex,
    required this.visibleBars,
    required this.indexOfTime,
    required this.gridColor,
    required this.textColor,
    required this.bandColor,
    required this.emaColor,
    required this.surfaceColor,
    required this.crossColor,
  });

  final List<Candle> candles;
  final List<BollingerPoint?> bands;
  final List<double?> ema;
  final List<({List<double?> values, Color color})> extraEmas;
  final List<double> sigmas;
  final double bbSigma;
  final List<PriceLine> lines;
  final List<ChartDrawing> drawings;
  final ({int time, double price})? trendStart;
  final Offset? crosshair;
  final double? crossPrice;
  final int? crossTime;
  final ({double min, double max}) range;
  final double endIndex;
  final double visibleBars;
  final double Function(int time) indexOfTime;
  final Color gridColor;
  final Color textColor;
  final Color bandColor;
  final Color emaColor;
  final Color surfaceColor;
  final Color crossColor;

  static const _up = Color(0xFF26A69A);
  static const _down = Color(0xFFEF5350);

  late double _plotW;
  late double _plotH;

  double _barW() => _plotW / visibleBars;
  double _x(double i) => _plotW - (endIndex - i + 0.5) * _barW();
  double _y(double price) =>
      InteractiveChart.topPadding +
      (range.max - price) / (range.max - range.min) * _plotH;

  @override
  void paint(Canvas canvas, Size size) {
    _plotW = size.width - InteractiveChart.priceAxisWidth;
    _plotH =
        size.height - InteractiveChart.topPadding - InteractiveChart.timeAxisHeight;
    if (_plotW <= 0 || _plotH <= 0 || candles.isEmpty) return;

    final from = math.max(0, (endIndex - visibleBars).floor() - 1);
    final to = math.min(candles.length - 1, endIndex.ceil() + 1);

    _paintGrid(canvas, size);
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(0, InteractiveChart.topPadding, _plotW, _plotH),
    );
    _paintIndicators(canvas, from, to);
    _paintCandles(canvas, from, to);
    _paintDrawings(canvas);
    canvas.restore();
    _paintLines(canvas, size);
    _paintTimeLabels(canvas, size, from, to);
    _paintCrosshair(canvas, size);
  }

  void _paintGrid(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 5; i++) {
      final price = range.min + (range.max - range.min) * i / 5;
      final yy = _y(price);
      canvas.drawLine(Offset(0, yy), Offset(_plotW, yy), grid);
      _text(
        canvas,
        formatPrice(price),
        Offset(_plotW + 4, yy - 6),
        color: textColor,
        size: 9.5,
      );
    }
  }

  void _paintCandles(Canvas canvas, int from, int to) {
    final step = _barW();
    final bodyWidth = math.max(1.0, step * 0.62);
    for (var i = from; i <= to; i++) {
      final c = candles[i];
      final paint = Paint()
        ..color = c.close >= c.open ? _up : _down
        ..strokeWidth = math.max(1.0, step * 0.12);
      final cx = _x(i.toDouble());
      if (cx < -step || cx > _plotW + step) continue;
      canvas.drawLine(Offset(cx, _y(c.high)), Offset(cx, _y(c.low)), paint);
      final top = _y(math.max(c.open, c.close));
      final bottom = _y(math.min(c.open, c.close));
      canvas.drawRect(
        Rect.fromLTRB(
          cx - bodyWidth / 2,
          top,
          cx + bodyWidth / 2,
          math.max(bottom, top + 1),
        ),
        Paint()..color = paint.color,
      );
    }
  }

  void _paintIndicators(Canvas canvas, int from, int to) {
    void stroke(double? Function(int i) value, Color color, double width) {
      final path = Path();
      var started = false;
      for (var i = from; i <= to; i++) {
        final v = value(i);
        if (v == null) {
          started = false;
          continue;
        }
        final p = Offset(_x(i.toDouble()), _y(v));
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

    BollingerPoint? band(int i) => i < bands.length ? bands[i] : null;
    final others = {
      for (final s in sigmas)
        if (s > 0 && s != bbSigma) s,
    };
    for (final s in others) {
      final color = chartLineColor(s).withValues(alpha: 0.85);
      stroke((i) {
        final b = band(i);
        return b == null ? null : b.middle + b.deviation * s;
      }, color, 0.9);
      stroke((i) {
        final b = band(i);
        return b == null ? null : b.middle - b.deviation * s;
      }, color, 0.9);
    }
    final showStrategy = sigmas.contains(bbSigma);
    if (showStrategy) {
      stroke((i) => band(i)?.upper, bandColor, 1.2);
      stroke((i) => band(i)?.lower, bandColor, 1.2);
    }
    if (showStrategy || others.isNotEmpty) {
      stroke((i) => band(i)?.middle, bandColor.withValues(alpha: 0.45), 1);
    }
    for (final e in extraEmas) {
      stroke((i) => i < e.values.length ? e.values[i] : null, e.color, 1.1);
    }
    stroke((i) => i < ema.length ? ema[i] : null, emaColor, 1.4);
  }

  void _paintDrawings(Canvas canvas) {
    for (final d in drawings) {
      final paint = Paint()
        ..color = d.color
        ..strokeWidth = 1.6;
      if (d.kind == DrawingKind.horizontal) {
        final yy = _y(d.price1);
        canvas.drawLine(Offset(0, yy), Offset(_plotW, yy), paint);
        continue;
      }
      final a = Offset(_x(indexOfTime(d.time1!)), _y(d.price1));
      final b = Offset(_x(indexOfTime(d.time2!)), _y(d.price2!));
      // 2 点目より先は右端まで伸ばす (トレンドラインとして使うため)。
      var end = b;
      if (b.dx != a.dx) {
        final slope = (b.dy - a.dy) / (b.dx - a.dx);
        end = Offset(_plotW, b.dy + slope * (_plotW - b.dx));
      }
      canvas.drawLine(a, end, paint);
      canvas.drawCircle(a, 3, Paint()..color = d.color);
      canvas.drawCircle(b, 3, Paint()..color = d.color);
    }
    final start = trendStart;
    if (start != null) {
      final p = Offset(_x(indexOfTime(start.time)), _y(start.price));
      canvas.drawCircle(p, 5, Paint()..color = ChartDrawing.defaultColor);
    }
  }

  void _paintLines(Canvas canvas, Size size) {
    final top = InteractiveChart.topPadding;
    final bottom = top + _plotH;
    for (final line in lines) {
      final raw = _y(line.price);
      if (raw.isNaN) continue;
      final above = raw < top;
      final below = raw > bottom;
      final yy = raw.clamp(top, bottom);
      final paint = Paint()
        ..color = line.color
        ..strokeWidth = line.emphasized ? 2.2 : 1.3;
      if (!above && !below) {
        if (line.dashed) {
          var dx = 0.0;
          while (dx < _plotW) {
            canvas.drawLine(
              Offset(dx, yy),
              Offset(math.min(dx + 6, _plotW), yy),
              paint,
            );
            dx += 10;
          }
        } else {
          canvas.drawLine(Offset(0, yy), Offset(_plotW, yy), paint);
        }
      }
      // 名前は左に、値段は右の目盛りに色付きの札で出す。範囲の外なら矢印。
      final arrow = above ? '↑ ' : (below ? '↓ ' : '');
      _text(
        canvas,
        '$arrow${line.label}',
        Offset(2, above ? top + 1 : (below ? bottom - 13 : yy - 13)),
        color: line.color,
        size: 10,
        bold: true,
      );
      final tag = formatPrice(line.price);
      final rect = Rect.fromLTWH(_plotW + 1, yy - 7, size.width - _plotW - 1, 14);
      canvas.drawRect(rect, Paint()..color = line.color.withValues(alpha: 0.9));
      _text(
        canvas,
        tag,
        Offset(_plotW + 4, yy - 6),
        color: Colors.white,
        size: 9.5,
        bold: true,
      );
    }
  }

  void _paintTimeLabels(Canvas canvas, Size size, int from, int to) {
    final yy = size.height - InteractiveChart.timeAxisHeight + 3;
    // 4 か所くらいに時刻を出す。
    const ticks = 4;
    for (var k = 0; k < ticks; k++) {
      final i = (endIndex - visibleBars * (k + 0.5) / ticks).round();
      if (i < 0 || i >= candles.length) continue;
      final label = _time(candles[i].openTime);
      final xx = _x(i.toDouble()) - label.length * 2.6;
      if (xx < 0 || xx > _plotW - 20) continue;
      _text(canvas, label, Offset(xx, yy), color: textColor, size: 9);
    }
  }

  void _paintCrosshair(Canvas canvas, Size size) {
    final p = crosshair;
    final price = crossPrice;
    if (p == null || price == null) return;
    final paint = Paint()
      ..color = crossColor
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(0, p.dy), Offset(_plotW, p.dy), paint);
    canvas.drawLine(
      Offset(p.dx, InteractiveChart.topPadding),
      Offset(p.dx, InteractiveChart.topPadding + _plotH),
      paint,
    );
    final rect = Rect.fromLTWH(
      _plotW + 1,
      p.dy - 7,
      size.width - _plotW - 1,
      14,
    );
    canvas.drawRect(rect, Paint()..color = crossColor);
    _text(
      canvas,
      formatPrice(price),
      Offset(_plotW + 4, p.dy - 6),
      color: surfaceColor,
      size: 9.5,
      bold: true,
    );
    final t = crossTime;
    if (t != null) {
      final label = _time(t);
      final x = (p.dx - label.length * 2.6).clamp(0.0, _plotW - 60);
      _text(
        canvas,
        label,
        Offset(x, InteractiveChart.topPadding + 2),
        color: textColor,
        size: 9.5,
        bold: true,
      );
    }
  }

  String _time(int epochSeconds) {
    final t = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).toLocal();
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
  bool shouldRepaint(_TradeChartPainter old) => true;
}
