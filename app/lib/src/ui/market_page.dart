import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../data/chart_data.dart';
import 'format.dart';

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

/// 銘柄一覧。出来高で絞り、24時間の動きで並べ替え、押すとチャートへ。
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

  final ChartDataSource _source = ChartDataSource();
  final TextEditingController _search = TextEditingController();

  List<TickerSnapshot> _all = const [];
  bool _loading = false;
  String? _error;
  DateTime? _fetchedAt;
  double _minVolumeM = 1;
  _SortKey _sort = _SortKey.gainers;
  Timer? _timer;

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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
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
                          '  押すとチャートが開きます',
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
                  itemBuilder: (context, i) => _TickerRow(
                    rank: i + 1,
                    ticker: rows[i],
                    held: held.contains(rows[i].symbol),
                    sort: _sort,
                    onTap: () => state.openChart(rows[i].symbol),
                  ),
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
    required this.sort,
    required this.onTap,
  });

  final int rank;
  final TickerSnapshot ticker;
  final bool held;
  final _SortKey sort;
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
      child: Padding(
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
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
