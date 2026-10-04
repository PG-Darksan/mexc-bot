import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../data/chart_data.dart';
import 'chart_overlays.dart';
import 'format.dart';
import 'price_chart.dart';

/// 並べ替えの基準。
enum _SortKey {
  gainers('上昇率', Icons.trending_up),
  losers('下落率', Icons.trending_down),
  range('値幅', Icons.swap_vert),
  volume('出来高', Icons.bar_chart);

  const _SortKey(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 銘柄一覧。出来高で絞り、24時間の動きで並べ替え、押すとその場にチャート。
///
/// ここに出すものは公開APIから端末が直接取る。鍵は要らない。
class MarketPage extends StatefulWidget {
  const MarketPage({super.key});

  @override
  State<MarketPage> createState() => _MarketPageState();
}

class _MarketPageState extends State<MarketPage> {
  /// 出来高の下限の選択肢 (M USDT)。
  static const List<double> _volumeChoices = [1, 3, 5, 10, 30, 50, 100];

  /// 自動で取り直す間隔。ticker は 1 リクエストで全部返るので軽い。
  static const Duration _refreshEvery = Duration(seconds: 60);

  /// その場に出すチャートで選べる時間軸。
  static const List<Timeframe> _chartTimeframes = [
    Timeframe.m5,
    Timeframe.m15,
    Timeframe.h1,
    Timeframe.h4,
    Timeframe.d1,
  ];

  final ChartDataSource _source = ChartDataSource();
  final TextEditingController _search = TextEditingController();

  List<TickerSnapshot> _all = const [];
  bool _loading = false;
  String? _error;
  DateTime? _fetchedAt;
  double _minVolumeM = 1;
  _SortKey _sort = _SortKey.gainers;
  Timer? _timer;

  /// いまチャートを開いている銘柄。押した行のすぐ下に出す。
  String? _openSymbol;
  Timeframe _chartTimeframe = Timeframe.h1;
  List<Candle> _candles = const [];
  bool _chartLoading = false;
  String? _chartError;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(_refreshEvery, (_) => _load());
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search.dispose();
    _source.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _source.tickers();
      if (!mounted) return;
      setState(() {
        _all = list;
        _fetchedAt = DateTime.now();
        _loading = false;
      });
      // 開いているチャートも一緒に新しくする。
      if (_openSymbol != null) unawaited(_loadCandles());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 行を押したときの開け閉め。同じ行をもう一度押すと閉じる。
  void _toggle(String symbol) {
    setState(() {
      if (_openSymbol == symbol) {
        _openSymbol = null;
        _candles = const [];
        _chartError = null;
        return;
      }
      _openSymbol = symbol;
      _candles = const [];
      _chartError = null;
    });
    if (_openSymbol != null) unawaited(_loadCandles());
  }

  Future<void> _loadCandles() async {
    final symbol = _openSymbol;
    if (symbol == null) return;
    setState(() {
      _chartLoading = true;
      _chartError = null;
    });
    try {
      final candles = await _source.klines(symbol, _chartTimeframe);
      // 待っている間に別の銘柄へ切り替わっていたら捨てる。
      if (!mounted || _openSymbol != symbol) return;
      setState(() {
        _candles = candles;
        _chartLoading = false;
      });
    } catch (e) {
      if (!mounted || _openSymbol != symbol) return;
      setState(() {
        _chartError = '$e';
        _chartLoading = false;
      });
    }
  }

  /// 絞り込みと並べ替えを済ませた一覧。
  List<TickerSnapshot> get _visible {
    final minAmount = _minVolumeM * 1000000;
    final query = _search.text.trim().toUpperCase();
    final list = _all
        .where((t) => t.amount24 >= minAmount)
        .where((t) => query.isEmpty || t.symbol.contains(query))
        .toList();
    switch (_sort) {
      case _SortKey.gainers:
        list.sort((a, b) => b.riseFallRate.compareTo(a.riseFallRate));
      case _SortKey.losers:
        list.sort((a, b) => a.riseFallRate.compareTo(b.riseFallRate));
      case _SortKey.range:
        list.sort((a, b) => b.range24Percent.compareTo(a.range24Percent));
      case _SortKey.volume:
        list.sort((a, b) => b.amount24.compareTo(a.amount24));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final held = {for (final p in state.snapshot.positions) p.symbol};
    final theme = Theme.of(context);
    final rows = _visible;

    return Column(
      children: [
        // ── 絞り込みと並べ替え ──
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        hintText: '銘柄を探す (BTC / ETH …)',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: _search.clear,
                              ),
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _loading ? null : _load,
                    icon: _loading
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
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _VolumeFilter(
                    value: _minVolumeM,
                    choices: _volumeChoices,
                    onChanged: (v) => setState(() => _minVolumeM = v),
                  ),
                  SegmentedButton<_SortKey>(
                    segments: [
                      for (final k in _SortKey.values)
                        ButtonSegment(
                          value: k,
                          icon: Icon(k.icon, size: 14),
                          label: Text(
                            k.label,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                    selected: {_sort},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    onSelectionChanged: (s) => setState(() => _sort = s.first),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _error != null
                    ? '取れませんでした: $_error'
                    : '${rows.length} 銘柄 '
                          '(24h出来高 ${_minVolumeM.toStringAsFixed(0)}M USDT 以上'
                          '${_fetchedAt == null ? '' : ' / ${formatTimeShort(_fetchedAt)} 取得'})'
                          '  押すとその場にチャートが開きます',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: _error != null ? theme.colorScheme.error : null,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // ── 一覧 ──
        Expanded(
          child: _all.isEmpty && _loading
              ? const Center(child: CircularProgressIndicator())
              : rows.isEmpty
              ? const Center(child: Text('条件に合う銘柄がありません'))
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final ticker = rows[i];
                    final open = _openSymbol == ticker.symbol;
                    return Column(
                      children: [
                        _TickerRow(
                          rank: i + 1,
                          ticker: ticker,
                          held: held.contains(ticker.symbol),
                          open: open,
                          onTap: () => _toggle(ticker.symbol),
                        ),
                        // 押した行のすぐ下にチャートを出す。
                        if (open)
                          _InlineChart(
                            ticker: ticker,
                            candles: _candles,
                            loading: _chartLoading,
                            error: _chartError,
                            timeframe: _chartTimeframe,
                            timeframes: _chartTimeframes,
                            side: state.snapshot.config.primarySide,
                            position: state.snapshot.positions
                                .where((p) => p.symbol == ticker.symbol)
                                .firstOrNull,
                            onTimeframeChanged: (tf) {
                              setState(() => _chartTimeframe = tf);
                              unawaited(_loadCandles());
                            },
                            onRefresh: () => unawaited(_loadCandles()),
                            onClose: () => _toggle(ticker.symbol),
                            onOpenHome: () => state.openChart(ticker.symbol),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 出来高の下限を選ぶ小さなメニュー。
class _VolumeFilter extends StatelessWidget {
  const _VolumeFilter({
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  final double value;
  final List<double> choices;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: '24h出来高の下限',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final c in choices)
          PopupMenuItem(
            value: c,
            child: Text('${c.toStringAsFixed(0)}M USDT 以上'),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_alt_outlined, size: 14),
            const SizedBox(width: 4),
            Text(
              '出来高 ${value.toStringAsFixed(0)}M 以上',
              style: const TextStyle(fontSize: 12),
            ),
            const Icon(Icons.arrow_drop_down, size: 16),
          ],
        ),
      ),
    );
  }
}

/// 1 銘柄ぶんの行。押すとチャートへ。
class _TickerRow extends StatelessWidget {
  const _TickerRow({
    required this.rank,
    required this.ticker,
    required this.held,
    required this.open,
    required this.onTap,
  });

  final int rank;
  final TickerSnapshot ticker;
  final bool held;

  /// この行のチャートを開いているか。開いている行は色を付ける。
  final bool open;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final change = ticker.changePercent;
    final changeColor = change > 0
        ? Colors.green
        : change < 0
        ? Colors.red
        : theme.colorScheme.onSurfaceVariant;
    final name = ticker.symbol.replaceAll('_USDT', '');

    return InkWell(
      onTap: onTap,
      child: Container(
        color: open
            ? theme.colorScheme.primary.withValues(alpha: 0.07)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '$rank',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (held) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.14,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '保有中',
                            style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '出来高 ${formatUsdtCompact(ticker.amount24)}'
                    '   値幅 ${ticker.range24Percent.toStringAsFixed(1)}%',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatPrice(ticker.lastPrice),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: changeColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    formatSignedPercent(change),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: changeColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
            Icon(
              open ? Icons.expand_less : Icons.show_chart,
              size: 18,
              color: open
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 押した行のすぐ下に出すチャート。
///
/// 建玉があれば建値・利確・買い足しの位置も引く。ラインを動かして
/// 取引所へ送るのはホームのチャートの仕事なので、ここでは見るだけ。
class _InlineChart extends StatelessWidget {
  const _InlineChart({
    required this.ticker,
    required this.candles,
    required this.loading,
    required this.error,
    required this.timeframe,
    required this.timeframes,
    required this.side,
    required this.position,
    required this.onTimeframeChanged,
    required this.onRefresh,
    required this.onClose,
    required this.onOpenHome,
  });

  final TickerSnapshot ticker;
  final List<Candle> candles;
  final bool loading;
  final String? error;
  final Timeframe timeframe;
  final List<Timeframe> timeframes;

  /// バンドと EMA の期間に使う側 (代表の向き)。
  final SideConfig side;

  final ManagedPosition? position;
  final ValueChanged<Timeframe> onTimeframeChanged;
  final VoidCallback onRefresh;
  final VoidCallback onClose;
  final VoidCallback onOpenHome;

  static const Map<Timeframe, String> _shortLabels = {
    Timeframe.m5: '5m',
    Timeframe.m15: '15m',
    Timeframe.h1: '1h',
    Timeframe.h4: '4h',
    Timeframe.d1: '1D',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = position;

    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
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
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onSelected: (_) => onTimeframeChanged(tf),
                      ),
                  ],
                ),
              ),
              const ChartOverlayButton(),
              IconButton(
                tooltip: '更新',
                visualDensity: VisualDensity.compact,
                icon: loading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 16),
                onPressed: loading ? null : onRefresh,
              ),
              IconButton(
                tooltip: '閉じる',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 16),
                onPressed: onClose,
              ),
            ],
          ),
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
              height: 220,
              child: Center(child: CircularProgressIndicator()),
            )
          else
            PriceChart(
              candles: candles,
              bbPeriod: side.bbPeriod,
              bbSigma: side.bbSigma,
              emaPeriod: side.emaPeriod,
              sigmas: AppScope.of(context).settings.chartSigmas,
              extraEmas: AppScope.of(context).settings.chartEmas,
              height: 220,
              lines: [
                if (p != null) ...[
                  PriceLine(
                    price: p.entryPrice,
                    label: '建値',
                    color: Colors.grey,
                    dashed: true,
                  ),
                  PriceLine(
                    price: p.takeProfitPrice,
                    label: '利確',
                    color: Colors.green,
                  ),
                  if (p.stopLossPrice != null)
                    PriceLine(
                      price: p.stopLossPrice!,
                      label: '損切り',
                      color: Colors.red,
                    ),
                  if (p.hasPendingAddOn && p.addOnPrice != null)
                    PriceLine(
                      price: p.addOnPrice!,
                      label: p.direction.isShort ? '売り足し' : '買い足し',
                      color: Colors.amber,
                      dashed: true,
                    ),
                ],
              ],
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '現在値 ${formatPrice(ticker.lastPrice)}  /  '
                  'BB(${side.bbPeriod}) ${side.bbSigma}σ / '
                  'EMA(${side.emaPeriod})'
                  '${p == null ? '' : '  /  建値 ${formatPrice(p.entryPrice)}'}',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                ),
              ),
              if (p != null)
                TextButton.icon(
                  onPressed: onOpenHome,
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: const Text(
                    'ホームで利確を動かす',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
