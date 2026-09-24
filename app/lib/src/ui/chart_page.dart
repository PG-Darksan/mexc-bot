import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../data/chart_data.dart';
import 'format.dart';

/// 動かすラインの種類。
enum _ExitLine { takeProfit, stopLoss }

/// 相場と建玉のチャート。
///
/// ここで出すものは端末が公開APIから直接取る。売買はサーバー (または
/// ローカルのエンジン) の仕事で、絵を描くのにサーバーは通さない。
class ChartPage extends StatefulWidget {
  const ChartPage({super.key});

  @override
  State<ChartPage> createState() => _ChartPageState();
}

class _ChartPageState extends State<ChartPage> {
  static const String _defaultSymbol = 'BTC_USDT';

  final ChartDataSource _source = ChartDataSource();

  String _symbol = _defaultSymbol;
  Timeframe _timeframe = Timeframe.h1;
  List<Candle> _candles = const [];
  List<FearGreedPoint> _fearGreed = const [];
  bool _loading = false;
  String? _error;

  /// 置き直している最中のライン。反映するまで取引所には送らない。
  _ExitLine _editing = _ExitLine.takeProfit;
  String? _draftPositionId;
  double? _takeProfitDraft;
  double? _stopLossDraft;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final candles = await _source.klines(_symbol, _timeframe);
      // 恐怖指数は銘柄に依らないので、一度取れていれば取り直さない。
      final fng = _fearGreed.isEmpty
          ? await _source.fearGreed()
          : _fearGreed;
      if (!mounted) return;
      setState(() {
        _candles = candles;
        _fearGreed = fng;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// いま見ている銘柄の建玉。無ければ null。
  ManagedPosition? _positionOf(BotSnapshot snapshot) {
    for (final p in snapshot.positions) {
      if (p.symbol == _symbol) return p;
    }
    return null;
  }

  /// 建玉が変わったら、いじっていた値を入れ直す。
  void _syncDraft(ManagedPosition? position) {
    if (position == null) {
      if (_draftPositionId != null) {
        _draftPositionId = null;
        _takeProfitDraft = null;
        _stopLossDraft = null;
      }
      return;
    }
    if (_draftPositionId != position.id) {
      _draftPositionId = position.id;
      _takeProfitDraft = position.takeProfitPrice;
      _stopLossDraft = position.stopLossPrice;
    }
  }

  Future<void> _applyExitLines(ManagedPosition position) async {
    setState(() => _sending = true);
    await AppScope.of(context).updatePositionExit(
      position.id,
      takeProfitPrice: _takeProfitDraft,
      stopLossPrice: _stopLossDraft,
      clearStopLoss: _stopLossDraft == null,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('取引所に送りました')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final snapshot = state.snapshot;
    final position = _positionOf(snapshot);
    _syncDraft(position);

    final symbols = <String>{
      _defaultSymbol,
      for (final p in snapshot.positions) p.symbol,
      if (_symbol.isNotEmpty) _symbol,
    }.toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _SymbolPicker(
            symbols: symbols,
            selected: _symbol,
            heldSymbols: {for (final p in snapshot.positions) p.symbol},
            onSelected: (s) {
              setState(() => _symbol = s);
              _load();
            },
          ),
          const SizedBox(height: 8),
          _TimeframePicker(
            selected: _timeframe,
            onSelected: (tf) {
              setState(() => _timeframe = tf);
              _load();
            },
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('チャートを取れませんでした: $_error'),
              ),
            )
          else
            _PriceChart(
              candles: _candles,
              loading: _loading,
              position: position,
              takeProfit: _takeProfitDraft,
              stopLoss: _stopLossDraft,
              editing: _editing,
              onDragPrice: position == null
                  ? null
                  : (price) => setState(() {
                      if (_editing == _ExitLine.takeProfit) {
                        _takeProfitDraft = price;
                      } else {
                        _stopLossDraft = price;
                      }
                    }),
            ),
          if (position != null) ...[
            const SizedBox(height: 12),
            _ExitLineEditor(
              position: position,
              lastPrice: snapshot.markPrices[position.symbol] ??
                  (_candles.isEmpty ? position.entryPrice : _candles.last.close),
              takeProfit: _takeProfitDraft ?? position.takeProfitPrice,
              stopLoss: _stopLossDraft,
              editing: _editing,
              sending: _sending,
              onEditingChanged: (line) => setState(() => _editing = line),
              onTakeProfitChanged: (v) =>
                  setState(() => _takeProfitDraft = v),
              onStopLossChanged: (v) => setState(() => _stopLossDraft = v),
              onReset: () => setState(() {
                _takeProfitDraft = position.takeProfitPrice;
                _stopLossDraft = position.stopLossPrice;
              }),
              onApply: () => _applyExitLines(position),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            '恐怖指数 (Crypto Fear & Greed Index)',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _FearGreedChart(points: _fearGreed, loading: _loading),
        ],
      ),
    );
  }
}

class _SymbolPicker extends StatelessWidget {
  const _SymbolPicker({
    required this.symbols,
    required this.selected,
    required this.heldSymbols,
    required this.onSelected,
  });

  final List<String> symbols;
  final String selected;
  final Set<String> heldSymbols;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final s in symbols)
          ChoiceChip(
            label: Text(
              heldSymbols.contains(s)
                  ? '${s.replaceAll('_USDT', '')} ●'
                  : s.replaceAll('_USDT', ''),
              style: const TextStyle(fontSize: 12),
            ),
            selected: s == selected,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onSelected: (_) => onSelected(s),
          ),
      ],
    );
  }
}

class _TimeframePicker extends StatelessWidget {
  const _TimeframePicker({required this.selected, required this.onSelected});

  final Timeframe selected;
  final ValueChanged<Timeframe> onSelected;

  static const _shown = [
    Timeframe.m15,
    Timeframe.h1,
    Timeframe.h4,
    Timeframe.d1,
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      children: [
        for (final tf in _shown)
          ChoiceChip(
            label: Text(tf.label, style: const TextStyle(fontSize: 12)),
            selected: tf == selected,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onSelected: (_) => onSelected(tf),
          ),
      ],
    );
  }
}

/// 終値の折れ線に、建値・利確・損切りの水平線を重ねる。
class _PriceChart extends StatelessWidget {
  const _PriceChart({
    required this.candles,
    required this.loading,
    required this.position,
    required this.takeProfit,
    required this.stopLoss,
    required this.editing,
    required this.onDragPrice,
  });

  static const double height = 260;

  final List<Candle> candles;
  final bool loading;
  final ManagedPosition? position;
  final double? takeProfit;
  final double? stopLoss;
  final _ExitLine editing;

  /// チャートを上下になぞったときに呼ばれる。null なら動かせない。
  final ValueChanged<double>? onDragPrice;

  @override
  Widget build(BuildContext context) {
    if (loading && candles.isEmpty) {
      return const SizedBox(
        height: height,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (candles.isEmpty) {
      return const SizedBox(
        height: height,
        child: Center(child: Text('データがありません')),
      );
    }

    final theme = Theme.of(context);
    final closes = [for (final c in candles) c.close];
    var minY = closes.reduce((a, b) => a < b ? a : b);
    var maxY = closes.reduce((a, b) => a > b ? a : b);
    // 線が枠に張り付かないよう、上下に少し余白を足す。
    for (final line in [position?.entryPrice, takeProfit, stopLoss]) {
      if (line == null) continue;
      if (line < minY) minY = line;
      if (line > maxY) maxY = line;
    }
    final pad = (maxY - minY) * 0.08;
    minY -= pad;
    maxY += pad;

    final chart = LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        minX: 0,
        maxX: (candles.length - 1).toDouble(),
        clipData: const FlClipData.all(),
        lineTouchData: const LineTouchData(enabled: false),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(
            color: theme.dividerColor.withValues(alpha: 0.3),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 58,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  formatPrice(value),
                  style: const TextStyle(fontSize: 9),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ),
        ),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            if (position != null)
              HorizontalLine(
                y: position!.entryPrice,
                color: theme.colorScheme.onSurfaceVariant,
                strokeWidth: 1,
                dashArray: const [4, 4],
                label: _lineLabel('建値', theme.colorScheme.onSurfaceVariant),
              ),
            if (takeProfit != null)
              HorizontalLine(
                y: takeProfit!,
                color: Colors.green,
                strokeWidth: editing == _ExitLine.takeProfit ? 2.5 : 1.5,
                label: _lineLabel('利確', Colors.green),
              ),
            if (stopLoss != null)
              HorizontalLine(
                y: stopLoss!,
                color: Colors.red,
                strokeWidth: editing == _ExitLine.stopLoss ? 2.5 : 1.5,
                label: _lineLabel('損切り', Colors.red),
              ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (var i = 0; i < candles.length; i++)
                FlSpot(i.toDouble(), candles[i].close),
            ],
            isCurved: false,
            barWidth: 1.6,
            color: theme.colorScheme.primary,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
            ),
          ),
        ],
      ),
    );

    if (onDragPrice == null) {
      return SizedBox(height: height, child: chart);
    }

    // なぞった高さを値段に直す。左の目盛り幅ぶんは描画からずれるが、
    // 数字は下の欄に出るので、大まかに合わせられれば足りる。
    return SizedBox(
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final local = box.globalToLocal(details.globalPosition);
          final ratio = (1 - (local.dy / height)).clamp(0.0, 1.0);
          onDragPrice!(minY + (maxY - minY) * ratio);
        },
        child: chart,
      ),
    );
  }

  static HorizontalLineLabel _lineLabel(String text, Color color) =>
      HorizontalLineLabel(
        show: true,
        alignment: Alignment.topRight,
        padding: const EdgeInsets.only(right: 4, bottom: 2),
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.bold,
        ),
        labelResolver: (_) => text,
      );
}

/// 利確 / 損切りラインを動かして取引所へ送る欄。
class _ExitLineEditor extends StatelessWidget {
  const _ExitLineEditor({
    required this.position,
    required this.lastPrice,
    required this.takeProfit,
    required this.stopLoss,
    required this.editing,
    required this.sending,
    required this.onEditingChanged,
    required this.onTakeProfitChanged,
    required this.onStopLossChanged,
    required this.onReset,
    required this.onApply,
  });

  final ManagedPosition position;
  final double lastPrice;
  final double takeProfit;
  final double? stopLoss;
  final _ExitLine editing;
  final bool sending;
  final ValueChanged<_ExitLine> onEditingChanged;
  final ValueChanged<double> onTakeProfitChanged;
  final ValueChanged<double?> onStopLossChanged;
  final VoidCallback onReset;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isShort = position.direction.isShort;
    final base = position.entryPrice;
    // 建値を真ん中に、上下 40% を動かせる範囲にする。
    final min = base * 0.6;
    final max = base * 1.4;
    final editingTakeProfit = editing == _ExitLine.takeProfit;
    final current = editingTakeProfit ? takeProfit : (stopLoss ?? base);

    final profit = isShort
        ? (base - takeProfit) / base * 100
        : (takeProfit - base) / base * 100;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${position.direction.label} ${position.vol} 枚',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isShort ? Colors.redAccent : Colors.green,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '建値 ${formatPrice(base)} / 現在 ${formatPrice(lastPrice)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<_ExitLine>(
              segments: const [
                ButtonSegment(
                  value: _ExitLine.takeProfit,
                  label: Text('利確', style: TextStyle(fontSize: 12)),
                ),
                ButtonSegment(
                  value: _ExitLine.stopLoss,
                  label: Text('損切り', style: TextStyle(fontSize: 12)),
                ),
              ],
              selected: {editing},
              onSelectionChanged: (s) => onEditingChanged(s.first),
            ),
            const SizedBox(height: 8),
            if (!editingTakeProfit && stopLoss == null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '損切りは置いていません。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => onStopLossChanged(
                      isShort ? base * 1.2 : base * 0.8,
                    ),
                    child: const Text('置く', style: TextStyle(fontSize: 12)),
                  ),
                ],
              )
            else ...[
              Row(
                children: [
                  Text(
                    editingTakeProfit ? '利確' : '損切り',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    formatPrice(current),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    editingTakeProfit
                        ? '(利幅 ${profit.toStringAsFixed(2)}%)'
                        : '(建値から ${((current - base) / base * 100).toStringAsFixed(2)}%)',
                    style: theme.textTheme.bodySmall,
                  ),
                  const Spacer(),
                  if (!editingTakeProfit)
                    TextButton(
                      onPressed: () => onStopLossChanged(null),
                      child: const Text('外す', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
              Slider(
                value: current.clamp(min, max),
                min: min,
                max: max,
                onChanged: (v) => editingTakeProfit
                    ? onTakeProfitChanged(v)
                    : onStopLossChanged(v),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  'チャートを上下になぞっても動かせます。',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                ),
                const Spacer(),
                TextButton(
                  onPressed: sending ? null : onReset,
                  child: const Text('戻す', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  onPressed: sending ? null : onApply,
                  icon: sending
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send, size: 16),
                  label: const Text('取引所に反映'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 恐怖指数の折れ線。0 が極度の恐怖、100 が極度の強欲。
class _FearGreedChart extends StatelessWidget {
  const _FearGreedChart({required this.points, required this.loading});

  static const double height = 170;

  final List<FearGreedPoint> points;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: loading
              ? const CircularProgressIndicator()
              : const Text('恐怖指数を取れていません'),
        ),
      );
    }

    final theme = Theme.of(context);
    final latest = points.last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${latest.value}',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: _colorFor(latest.value),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              latest.japaneseLabel,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _colorFor(latest.value),
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              '${points.length} 日分',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: height,
          child: LineChart(
            LineChartData(
              minY: 0,
              maxY: 100,
              minX: 0,
              maxX: (points.length - 1).toDouble(),
              lineTouchData: const LineTouchData(enabled: false),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: 25,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: theme.dividerColor.withValues(alpha: 0.3),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: 25,
                    reservedSize: 28,
                    getTitlesWidget: (value, meta) => Text(
                      value.toInt().toString(),
                      style: const TextStyle(fontSize: 9),
                    ),
                  ),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < points.length; i++)
                      FlSpot(i.toDouble(), points[i].value.toDouble()),
                  ],
                  isCurved: true,
                  curveSmoothness: 0.2,
                  barWidth: 2,
                  color: _colorFor(latest.value),
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: _colorFor(latest.value).withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '0 に近いほど「極度の恐怖」、100 に近いほど「極度の強欲」。'
            '逆張りの目安に使います。出どころは alternative.me です。',
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
          ),
        ),
      ],
    );
  }

  static Color _colorFor(int value) => switch (value) {
    < 25 => Colors.red,
    < 45 => Colors.orange,
    < 55 => Colors.grey,
    < 75 => Colors.lightGreen,
    _ => Colors.green,
  };
}
