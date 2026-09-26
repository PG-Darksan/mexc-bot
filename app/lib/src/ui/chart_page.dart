import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../data/chart_data.dart';
import 'format.dart';
import 'price_chart.dart';

/// 動かすラインの種類。
enum _ExitLine { takeProfit, stopLoss }

/// 相場と建玉のチャート。
///
/// ここに出すものは端末が公開APIから直接取る。売買はサーバー (または
/// ローカルのエンジン) の仕事で、絵を描くのにサーバーは通さない。
class ChartPage extends StatefulWidget {
  const ChartPage({super.key});

  @override
  State<ChartPage> createState() => _ChartPageState();
}

class _ChartPageState extends State<ChartPage> {
  static const String _defaultSymbol = 'BTC_USDT';
  static const List<Timeframe> _timeframes = [
    Timeframe.m5,
    Timeframe.m15,
    Timeframe.h1,
    Timeframe.h4,
    Timeframe.d1,
  ];

  final ChartDataSource _source = ChartDataSource();

  String _symbol = _defaultSymbol;
  Timeframe _timeframe = Timeframe.d1;
  List<Candle> _candles = const [];
  List<FearGreedPoint> _fearGreed = const [];
  List<String> _allSymbols = const [];
  bool _loadingChart = false;
  bool _loadingIndex = false;
  String? _chartError;
  String? _indexError;

  _ExitLine _editing = _ExitLine.takeProfit;
  String? _draftPositionId;
  double? _takeProfitDraft;
  double? _stopLossDraft;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadChart();
    _loadIndex();
    _loadSymbols();
  }

  /// 検索に使う銘柄の一覧。取れなくてもチャートは見られるので、黙って諦める。
  Future<void> _loadSymbols() async {
    try {
      final names = await _source.symbols();
      if (!mounted) return;
      setState(() => _allSymbols = names);
    } catch (_) {
      // 一覧が無いときは、保有銘柄と BTC だけ選べる状態のままにする。
    }
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _loadChart() async {
    setState(() {
      _loadingChart = true;
      _chartError = null;
    });
    try {
      final candles = await _source.klines(_symbol, _timeframe);
      if (!mounted) return;
      setState(() {
        _candles = candles;
        _loadingChart = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _chartError = '$e';
        _loadingChart = false;
      });
    }
  }

  Future<void> _loadIndex() async {
    setState(() {
      _loadingIndex = true;
      _indexError = null;
    });
    try {
      final points = await _source.fearGreed(days: 7);
      if (!mounted) return;
      setState(() {
        _fearGreed = points;
        _loadingIndex = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _indexError = '$e';
        _loadingIndex = false;
      });
    }
  }

  ManagedPosition? _positionOf(BotSnapshot snapshot) {
    for (final p in snapshot.positions) {
      if (p.symbol == _symbol) return p;
    }
    return null;
  }

  /// 見ている建玉が変わったら、いじっていた値を入れ直す。
  void _syncDraft(ManagedPosition? position) {
    if (position == null) {
      _draftPositionId = null;
      _takeProfitDraft = null;
      _stopLossDraft = null;
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('取引所に送りました')));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final snapshot = state.snapshot;
    final config = snapshot.config;
    final position = _positionOf(snapshot);
    _syncDraft(position);

    final symbols = <String>{
      _defaultSymbol,
      for (final p in snapshot.positions) p.symbol,
      _symbol,
    }.toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        _SymbolSearch(
          symbols: _allSymbols,
          onSelected: (s) {
            setState(() => _symbol = s);
            _loadChart();
          },
        ),
        const SizedBox(height: 12),
        _ChartCard(
          symbol: _symbol,
          symbols: symbols,
          heldSymbols: {for (final p in snapshot.positions) p.symbol},
          timeframe: _timeframe,
          timeframes: _timeframes,
          candles: _candles,
          loading: _loadingChart,
          error: _chartError,
          config: config,
          lines: _buildLines(position),
          onSymbolChanged: (s) {
            setState(() => _symbol = s);
            _loadChart();
          },
          onTimeframeChanged: (tf) {
            setState(() => _timeframe = tf);
            _loadChart();
          },
          onRefresh: _loadChart,
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
          const SizedBox(height: 16),
          _ExitLineEditor(
            position: position,
            lastPrice:
                snapshot.markPrices[position.symbol] ??
                (_candles.isEmpty ? position.entryPrice : _candles.last.close),
            takeProfit: _takeProfitDraft ?? position.takeProfitPrice,
            stopLoss: _stopLossDraft,
            editing: _editing,
            sending: _sending,
            onEditingChanged: (line) => setState(() => _editing = line),
            onTakeProfitChanged: (v) => setState(() => _takeProfitDraft = v),
            onStopLossChanged: (v) => setState(() => _stopLossDraft = v),
            onReset: () => setState(() {
              _takeProfitDraft = position.takeProfitPrice;
              _stopLossDraft = position.stopLossPrice;
            }),
            onApply: () => _applyExitLines(position),
          ),
        ],
        const SizedBox(height: 20),
        _Heading('相場のムード'),
        const SizedBox(height: 8),
        _FearGreedCard(
          points: _fearGreed,
          loading: _loadingIndex,
          error: _indexError,
          onRefresh: _loadIndex,
        ),
      ],
    );
  }

  List<PriceLine> _buildLines(ManagedPosition? position) {
    if (position == null) return const [];
    final tp = _takeProfitDraft ?? position.takeProfitPrice;
    final sl = _stopLossDraft;
    return [
      PriceLine(
        price: position.entryPrice,
        label: '建値',
        color: Colors.grey,
        dashed: true,
      ),
      PriceLine(
        price: tp,
        label: '利確',
        color: Colors.green,
        emphasized: _editing == _ExitLine.takeProfit,
      ),
      if (sl != null)
        PriceLine(
          price: sl,
          label: '損切り',
          color: Colors.red,
          emphasized: _editing == _ExitLine.stopLoss,
        ),
    ];
  }
}

/// 銘柄を名前で探す。取引できる USDT 無期限だけが候補に出る。
class _SymbolSearch extends StatelessWidget {
  const _SymbolSearch({required this.symbols, required this.onSelected});

  final List<String> symbols;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      optionsBuilder: (value) {
        final q = value.text.trim().toUpperCase();
        if (q.isEmpty) return const Iterable<String>.empty();
        return symbols.where((s) => s.contains(q)).take(20);
      },
      displayStringForOption: (s) => s.replaceAll('_USDT', ''),
      onSelected: onSelected,
      fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
        controller: controller,
        focusNode: focusNode,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(
          labelText: '銘柄を探す',
          hintText: symbols.isEmpty ? '一覧を読み込み中…' : 'BTC / ETH / SOL …',
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 18),
        ),
        onSubmitted: (text) {
          final q = text.trim().toUpperCase();
          if (q.isEmpty) return;
          // そのままの名前か、_USDT を足した名前が一覧にあれば切り替える。
          final hit = symbols.firstWhere(
            (s) => s == q || s == '${q}_USDT',
            orElse: () => '',
          );
          if (hit.isNotEmpty) onSelected(hit);
        },
      ),
      optionsViewBuilder: (context, onTap, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260, maxWidth: 260),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: options.length,
              itemBuilder: (context, i) {
                final s = options.elementAt(i);
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    s.replaceAll('_USDT', ''),
                    style: const TextStyle(fontSize: 13),
                  ),
                  onTap: () => onTap(s),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
  );
}

/// 恐怖指数。数字と前日比だけの簡単なカードにする。
class _FearGreedCard extends StatelessWidget {
  const _FearGreedCard({
    required this.points,
    required this.loading,
    required this.error,
    required this.onRefresh,
  });

  final List<FearGreedPoint> points;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = points.isEmpty ? null : points.last;
    final previous = points.length < 2 ? null : points[points.length - 2];
    final diff = (latest == null || previous == null)
        ? null
        : latest.value - previous.value;
    final diffPercent =
        (diff == null || previous == null || previous.value == 0)
        ? null
        : diff / previous.value * 100;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '恐怖指数',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 6),
                Text('(Fear & Greed)', style: theme.textTheme.bodySmall),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: loading ? null : onRefresh,
                  icon: loading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: const Text('更新'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (error != null)
              Text('取れませんでした: $error', style: theme.textTheme.bodySmall)
            else if (latest == null)
              Text('読み込み中…', style: theme.textTheme.bodySmall)
            else ...[
              _Row(
                '現在値',
                '${latest.value}  ${latest.japaneseLabel}',
                color: _colorFor(latest.value),
                bold: true,
              ),
              if (diff != null && diffPercent != null)
                _Row(
                  '前日比',
                  '${diff >= 0 ? '+' : ''}$diff '
                      '(${diffPercent >= 0 ? '+' : ''}'
                      '${diffPercent.toStringAsFixed(2)}%)',
                  color: diff >= 0 ? Colors.green : Colors.red,
                ),
              if (previous != null) _Row('前日終値', '${previous.value}'),
              _Row('取得時刻', formatTime(DateTime.now())),
            ],
          ],
        ),
      ),
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

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.color, this.bold = false});

  final String label;
  final String value;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text('$label: ', style: Theme.of(context).textTheme.bodyMedium),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              fontSize: bold ? 16 : 14,
            ),
          ),
        ],
      ),
    );
  }
}

/// 銘柄のローソク足。時間軸を選べる。
class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.symbol,
    required this.symbols,
    required this.heldSymbols,
    required this.timeframe,
    required this.timeframes,
    required this.candles,
    required this.loading,
    required this.error,
    required this.config,
    required this.lines,
    required this.onSymbolChanged,
    required this.onTimeframeChanged,
    required this.onRefresh,
    required this.onDragPrice,
  });

  final String symbol;
  final List<String> symbols;
  final Set<String> heldSymbols;
  final Timeframe timeframe;
  final List<Timeframe> timeframes;
  final List<Candle> candles;
  final bool loading;
  final String? error;
  final StrategyConfig config;
  final List<PriceLine> lines;
  final ValueChanged<String> onSymbolChanged;
  final ValueChanged<Timeframe> onTimeframeChanged;
  final VoidCallback onRefresh;
  final ValueChanged<double>? onDragPrice;

  static const _shortLabels = {
    Timeframe.m5: '5m',
    Timeframe.m15: '15m',
    Timeframe.h1: '1h',
    Timeframe.h4: '4h',
    Timeframe.d1: '1D',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final closes = [for (final c in candles) c.close];
    final rsi = closes.length > config.rsiPeriod
        ? Indicators.rsi(closes, config.rsiPeriod)
        : null;
    final last = closes.isEmpty ? null : closes.last;
    final first = closes.isEmpty ? null : closes.first;
    final change = (last == null || first == null || first == 0)
        ? null
        : (last - first) / first * 100;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${symbol.replaceAll('_USDT', '')} の値動き',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  _shortLabels[timeframe] ?? timeframe.label,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: loading ? null : onRefresh,
                  icon: loading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: const Text('更新'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 時間軸
            Wrap(
              spacing: 6,
              children: [
                for (final tf in timeframes)
                  ChoiceChip(
                    label: Text(
                      _shortLabels[tf] ?? tf.label,
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: tf == timeframe,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) => onTimeframeChanged(tf),
                  ),
              ],
            ),
            if (symbols.length > 1) ...[
              const SizedBox(height: 6),
              Wrap(
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
                      selected: s == symbol,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onSelected: (_) => onSymbolChanged(s),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            if (last != null)
              Text(
                '現在値 ${formatPrice(last)}'
                '${change == null ? '' : '  /  この期間 ${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%'}'
                '${rsi == null ? '' : '  /  RSI(${config.rsiPeriod}) ${rsi.toStringAsFixed(1)}'}',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 4),
            if (error != null)
              SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    'チャートを取れませんでした\n$error',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              )
            else if (loading && candles.isEmpty)
              const SizedBox(
                height: 280,
                child: Center(child: CircularProgressIndicator()),
              )
            else
              PriceChart(
                candles: candles,
                bbPeriod: config.bbPeriod,
                bbSigma: config.short.bbSigma,
                emaPeriod: config.emaPeriod,
                lines: lines,
                onDragPrice: onDragPrice,
              ),
          ],
        ),
      ),
    );
  }
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
    final min = base * 0.6;
    final max = base * 1.4;
    final editingTakeProfit = editing == _ExitLine.takeProfit;
    final current = editingTakeProfit ? takeProfit : (stopLoss ?? base);
    final profit = isShort
        ? (base - takeProfit) / base * 100
        : (takeProfit - base) / base * 100;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
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
                Expanded(
                  child: Text(
                    '建値 ${formatPrice(base)} / 現在 ${formatPrice(lastPrice)}',
                    style: theme.textTheme.bodySmall,
                  ),
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
                    onPressed: () =>
                        onStopLossChanged(isShort ? base * 1.2 : base * 0.8),
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
                  Expanded(
                    child: Text(
                      editingTakeProfit
                          ? '(利幅 ${profit.toStringAsFixed(2)}%)'
                          : '(建値から ${((current - base) / base * 100).toStringAsFixed(2)}%)',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    'チャートを上下になぞっても動かせます。',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                ),
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
                  label: const Text('反映'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
