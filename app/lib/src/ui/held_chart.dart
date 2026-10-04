import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../data/chart_data.dart';
import 'chart_overlays.dart';
import 'format.dart';
import 'price_chart.dart';

/// チャートに出す建玉。ボットの建玉と、取引所にあるだけの建玉の両方を表す。
class HeldView {
  const HeldView({
    required this.id,
    required this.symbol,
    required this.direction,
    required this.entryPrice,
    required this.pnlAt,
    this.timeframe,
    this.takeProfit,
    this.stopLoss,
    this.addOn,
    this.liquidation,
    this.managed = true,
  });

  factory HeldView.managed(ManagedPosition p) => HeldView(
    id: p.id,
    symbol: p.symbol,
    direction: p.direction,
    entryPrice: p.entryPrice,
    pnlAt: p.pnlAt,
    timeframe: p.timeframe,
    takeProfit: p.takeProfitPrice,
    stopLoss: p.stopLossPrice,
    addOn: p.hasPendingAddOn ? p.addOnPrice : null,
  );

  /// ボットが管理していない取引所の建玉。利確の位置はボットが知らない。
  factory HeldView.exchange(PositionInfo p, double contractSize) => HeldView(
    id: 'exchange-${p.positionId}',
    symbol: p.symbol,
    direction: TradeDirection.fromPositionType(p.positionType),
    entryPrice: p.holdAvgPrice,
    pnlAt: (mark) => p.unrealizedPnl(mark, contractSize),
    liquidation: p.liquidatePrice > 0 ? p.liquidatePrice : null,
    managed: false,
  );

  final String id;
  final String symbol;
  final TradeDirection direction;
  final double entryPrice;
  final double Function(double mark) pnlAt;

  /// 建てたときの時間軸。分からなければ null。
  final Timeframe? timeframe;
  final double? takeProfit;
  final double? stopLoss;
  final double? addOn;
  final double? liquidation;

  /// ボットが建てて管理している建玉か。
  final bool managed;
}

/// 保有中の建玉 1 つ分のチャート。ホームに建玉の数だけ並べる。
///
/// 建値・利確・損切り・買い足しの位置を引く。見るだけで、ラインを動かして
/// 取引所へ送るのは下のチャートの仕事 ([onEditExit] でそちらへ移る)。
class HeldPositionChart extends StatefulWidget {
  const HeldPositionChart({
    super.key,
    required this.position,
    required this.source,
    required this.config,
    this.onEditExit,
    this.markPrice,
  });

  final HeldView position;
  final ChartDataSource source;
  final StrategyConfig config;

  /// 利確を動かす。ボットが管理していない建玉では null。
  final VoidCallback? onEditExit;
  final double? markPrice;

  @override
  State<HeldPositionChart> createState() => _HeldPositionChartState();
}

class _HeldPositionChartState extends State<HeldPositionChart> {
  static const Map<Timeframe, String> _timeframes = {
    Timeframe.m5: '5m',
    Timeframe.m15: '15m',
    Timeframe.h1: '1h',
    Timeframe.h4: '4h',
    Timeframe.d1: '1D',
  };

  // 建てたときの時間軸で開く。選べない足なら 1 時間足。
  late Timeframe _timeframe = _timeframes.containsKey(widget.position.timeframe)
      ? widget.position.timeframe!
      : Timeframe.h1;
  List<Candle> _candles = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final candles = await widget.source.klines(
        widget.position.symbol,
        _timeframe,
      );
      if (!mounted) return;
      setState(() {
        _candles = candles;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = AppScope.of(context).settings;
    final p = widget.position;
    final side = widget.config.sideOf(p.direction);
    final isShort = p.direction.isShort;
    final mark =
        widget.markPrice ?? (_candles.isEmpty ? null : _candles.last.close);
    final pnl = mark == null ? null : p.pnlAt(mark);
    final closes = [for (final c in _candles) c.close];
    final rsi = closes.length > side.rsiPeriod
        ? Indicators.rsi(closes, side.rsiPeriod)
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        p.symbol.replaceAll('_', ''),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        isShort ? '売り (ショート)' : '買い (ロング)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isShort ? Colors.redAccent : Colors.green,
                        ),
                      ),
                      if (!p.managed)
                        Text(
                          'ボット管理外',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                          ),
                        ),
                      if (pnl != null)
                        Text(
                          formatPnl(pnl),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: pnl >= 0 ? Colors.green : Colors.red,
                          ),
                        ),
                    ],
                  ),
                ),
                const ChartOverlayButton(),
                IconButton(
                  tooltip: '更新',
                  visualDensity: VisualDensity.compact,
                  icon: _loading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  onPressed: _loading ? null : _load,
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final MapEntry(key: tf, value: label)
                    in _timeframes.entries)
                  ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    selected: tf == _timeframe,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) {
                      setState(() => _timeframe = tf);
                      _load();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _error != null
                  ? SizedBox(
                      height: 120,
                      child: Center(
                        child: Text(
                          'チャートを取れませんでした\n$_error',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    )
                  : _loading && _candles.isEmpty
                  ? const SizedBox(
                      height: 220,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : PriceChart(
                      candles: _candles,
                      bbPeriod: side.bbPeriod,
                      bbSigma: side.bbSigma,
                      emaPeriod: side.emaPeriod,
                      sigmas: visibleChartSigmas(settings.chartSigmas, side.bbSigma),
                      extraEmas: settings.chartEmas,
                      height: 220,
                      lines: [
                        PriceLine(
                          price: p.entryPrice,
                          label: '建値',
                          color: Colors.grey,
                          dashed: true,
                        ),
                        if (p.takeProfit != null)
                          PriceLine(
                            price: p.takeProfit!,
                            label: '利確',
                            color: Colors.green,
                          ),
                        if (p.stopLoss != null)
                          PriceLine(
                            price: p.stopLoss!,
                            label: '損切り',
                            color: Colors.red,
                          ),
                        if (p.addOn != null)
                          PriceLine(
                            price: p.addOn!,
                            label: isShort ? '売り足し' : '買い足し',
                            color: Colors.amber,
                            dashed: true,
                          ),
                        if (p.liquidation != null)
                          PriceLine(
                            price: p.liquidation!,
                            label: '強制決済',
                            color: Colors.deepOrange,
                            dashed: true,
                          ),
                      ],
                    ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '建値 ${formatPrice(p.entryPrice)}'
                    '${p.takeProfit == null ? '' : '  /  利確 ${formatPrice(p.takeProfit)}'}'
                    '${mark == null ? '' : '  /  現在値 ${formatPrice(mark)}'}'
                    '${rsi == null ? '' : '  /  RSI(${side.rsiPeriod}) ${rsi.toStringAsFixed(1)}'}',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                ),
                if (widget.onEditExit != null)
                  TextButton.icon(
                    onPressed: widget.onEditExit,
                    icon: const Icon(Icons.tune, size: 14),
                    label: const Text('利確を動かす', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
