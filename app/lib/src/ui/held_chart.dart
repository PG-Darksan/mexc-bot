import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../data/chart_data.dart';
import 'chart_overlays.dart';
import 'format.dart';
import 'price_chart.dart';
import 'trade_page.dart';

/// チャートに出す建玉。ボットの建玉と、取引所にあるだけの建玉の両方を表す。
class HeldView {
  const HeldView({
    required this.id,
    required this.symbol,
    required this.direction,
    required this.entryPrice,
    required this.pnlAt,
    required this.vol,
    this.timeframe,
    this.takeProfit,
    this.stopLoss,
    this.addOn,
    this.liquidation,
    this.managed = true,
    this.exchangePositionId,
    this.exitKnown = true,
    this.strategy = StrategyKind.classic,
  });

  factory HeldView.managed(ManagedPosition p) => HeldView(
    id: p.id,
    symbol: p.symbol,
    direction: p.direction,
    entryPrice: p.entryPrice,
    pnlAt: p.pnlAt,
    vol: p.vol,
    timeframe: p.timeframe,
    takeProfit: p.takeProfitPrice,
    stopLoss: p.stopLossPrice,
    addOn: p.hasPendingAddOn ? p.addOnPrice : null,
    strategy: p.strategy,
  );

  /// ボットが管理していない取引所の建玉。利確 / 損切りは、サーバーが取引所
  /// から取ったもの ([exit]) を使う。古いサーバーは返さないので、そのときは
  /// [exitKnown] を false にする。
  factory HeldView.exchange(
    PositionInfo p,
    double contractSize, {
    ({double? takeProfit, double? stopLoss}) exit = (
      takeProfit: null,
      stopLoss: null,
    ),
    bool exitKnown = true,
  }) => HeldView(
    id: 'exchange-${p.positionId}',
    symbol: p.symbol,
    direction: TradeDirection.fromPositionType(p.positionType),
    entryPrice: p.holdAvgPrice,
    pnlAt: (mark) => p.unrealizedPnl(mark, contractSize),
    vol: p.holdVol,
    takeProfit: exit.takeProfit,
    stopLoss: exit.stopLoss,
    liquidation: p.liquidatePrice > 0 ? p.liquidatePrice : null,
    managed: false,
    exchangePositionId: p.positionId,
    exitKnown: exitKnown,
  );

  final String id;
  final String symbol;
  final TradeDirection direction;
  final double entryPrice;
  final double Function(double mark) pnlAt;
  final double vol;

  /// 建てたときの時間軸。分からなければ null。
  final Timeframe? timeframe;
  final double? takeProfit;
  final double? stopLoss;
  final double? addOn;
  final double? liquidation;

  /// ボットが建てて管理している建玉か。
  final bool managed;

  /// 取引所の建玉 ID (ボットが管理していない建玉だけ)。
  final int? exchangePositionId;

  /// 利確 / 損切りの位置が分かっているか。分からないまま送ると、置いて
  /// あった損切りを知らずに外してしまうので、分かるまで動かさせない。
  final bool exitKnown;

  /// どの手法で建てたか (指標の期間を合わせるのに使う)。手の建玉は今までの手法。
  final StrategyKind strategy;
}

/// 動かす線の名前 ([PriceLine.dragKey])。
enum _Exit { takeProfit, stopLoss }

/// 保有中の建玉 1 つ分のチャート。ホームに建玉の数だけ並べる。
///
/// 建値・利確・損切り・買い足しの位置を引く。利確 / 損切りの線はつかんで
/// 上下に動かし、「反映」で取引所へ送れる。成行での決済もここから出せる
/// (取引画面を開かなくてよい)。
class HeldPositionChart extends StatefulWidget {
  const HeldPositionChart({
    super.key,
    required this.position,
    required this.source,
    required this.config,
    this.markPrice,
  });

  final HeldView position;
  final ChartDataSource source;
  final StrategyConfig config;
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

  /// 動かしている途中の利確 / 損切り。動かしていなければ null。
  double? _takeProfitDraft;
  double? _stopLossDraft;

  /// 損切りを外す (ボットの建玉だけ)。
  bool _clearStopLoss = false;
  bool _sending = false;

  /// 送ったあと、取引所の値が返ってくるまで動かした線を残しておく期限。
  Timer? _settleTimer;

  bool get _dirty =>
      _takeProfitDraft != null || _stopLossDraft != null || _clearStopLoss;

  double? get _takeProfit => _takeProfitDraft ?? widget.position.takeProfit;

  double? get _stopLoss =>
      _clearStopLoss ? null : (_stopLossDraft ?? widget.position.stopLoss);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HeldPositionChart old) {
    super.didUpdateWidget(old);
    // 送ったものが反映されて取引所の値が変わったら、動かしていた線を捨てる。
    if (!_sending &&
        _settleTimer != null &&
        (old.position.takeProfit != widget.position.takeProfit ||
            old.position.stopLoss != widget.position.stopLoss)) {
      _resetDrafts();
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
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

  void _resetDrafts() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _takeProfitDraft = null;
    _stopLossDraft = null;
    _clearStopLoss = false;
  }

  double? get _mark =>
      widget.markPrice ?? (_candles.isEmpty ? null : _candles.last.close);

  /// まだ置いていない線を、いまの値段から少し離した所に出す。
  double _defaultExit(_Exit which) {
    final p = widget.position;
    final base = _mark ?? p.entryPrice;
    final isShort = p.direction.isShort;
    // 利確は建値と現在値の、利益が出る側より先。損切りは損が出る側より先。
    final profitSide = isShort
        ? (base < p.entryPrice ? base : p.entryPrice)
        : (base > p.entryPrice ? base : p.entryPrice);
    final lossSide = isShort
        ? (base > p.entryPrice ? base : p.entryPrice)
        : (base < p.entryPrice ? base : p.entryPrice);
    return switch (which) {
      _Exit.takeProfit => isShort ? profitSide * 0.97 : profitSide * 1.03,
      _Exit.stopLoss => isShort ? lossSide * 1.03 : lossSide * 0.97,
    };
  }

  /// 送る前の確かめ。おかしければ理由を返す。
  String? _problem() {
    final p = widget.position;
    final isShort = p.direction.isShort;
    final mark = _mark;
    final tp = _takeProfit;
    final sl = _stopLoss;
    if (!p.managed && tp == null && sl == null) {
      return '利確か損切りの線を置いて下さい。';
    }
    if (mark != null) {
      if (tp != null && (isShort ? tp >= mark : tp <= mark)) {
        return '${isShort ? 'ショート' : 'ロング'}の利確は現在値より'
            '${isShort ? '下' : '上'}にして下さい (すぐ決済されてしまいます)。';
      }
      if (sl != null && (isShort ? sl <= mark : sl >= mark)) {
        return '${isShort ? 'ショート' : 'ロング'}の損切りは現在値より'
            '${isShort ? '上' : '下'}にして下さい (すぐ決済されてしまいます)。';
      }
    }
    return null;
  }

  Future<void> _apply() async {
    final problem = _problem();
    if (problem != null) {
      _snack(problem);
      return;
    }
    final state = AppScope.of(context);
    final p = widget.position;
    final tp = _takeProfit;
    final sl = _stopLoss;
    setState(() => _sending = true);
    try {
      if (p.managed) {
        await state.updatePositionExit(
          p.id,
          takeProfitPrice: tp,
          stopLossPrice: sl,
          clearStopLoss: sl == null,
        );
      } else {
        // 片方だけ送ると、もう片方が外れることがあるので両方送る。
        await state.updateExchangePositionExit(
          positionId: p.exchangePositionId!,
          takeProfitPrice: tp,
          stopLossPrice: sl,
        );
      }
      if (!mounted) return;
      _snack('利確 / 損切りを取引所へ送りました');
      // 新しい値が返ってくるまで線はそのまま。返ってこなくても少しで戻す。
      _settleTimer?.cancel();
      _settleTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(_resetDrafts);
      });
    } catch (e) {
      if (mounted) _snack('送れませんでした: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _close() async {
    final p = widget.position;
    final name = p.symbol.replaceAll('_USDT', '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('成行で決済します'),
        content: Text('$name の${p.direction.label} ${p.vol} 枚を、いまの値段で決済します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('決済する'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final state = AppScope.of(context);
    setState(() => _sending = true);
    try {
      if (p.managed) {
        await state.closePosition(p.id);
      } else {
        await state.closeExchangePosition(p.exchangePositionId!);
      }
      if (mounted) _snack('決済を送りました');
    } catch (e) {
      if (mounted) _snack('決済出来ませんでした: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _onLineDragged(Object key, double price) {
    setState(() {
      _settleTimer?.cancel();
      _settleTimer = null;
      if (key == _Exit.takeProfit) {
        _takeProfitDraft = price;
      } else {
        _stopLossDraft = price;
        _clearStopLoss = false;
      }
    });
  }

  String _percentFromEntry(double price) {
    final p = widget.position;
    final move = (price - p.entryPrice) / p.entryPrice * 100;
    final gain = p.direction.isShort ? -move : move;
    return '${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(2)}%';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = AppScope.of(context).settings;
    final p = widget.position;
    final side = widget.config.sideFor(p.strategy, p.direction);
    final isShort = p.direction.isShort;
    final mark = _mark;
    final pnl = mark == null ? null : p.pnlAt(mark);
    final closes = [for (final c in _candles) c.close];
    final rsi = closes.length > side.rsiPeriod
        ? Indicators.rsi(closes, side.rsiPeriod)
        : null;
    final tp = _takeProfit;
    final sl = _stopLoss;
    // 手で建てた建玉は、サーバーが利確 / 損切りを返していれば動かせる。
    final canEdit = p.managed || (p.exchangePositionId != null && p.exitKnown);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 8),
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
                        '${isShort ? '売り (ショート)' : '買い (ロング)'} ${p.vol} 枚',
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
                  tooltip: '取引画面で開く (注文・ピンチで拡大・線を引く)',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.open_in_full, size: 18),
                  onPressed: () =>
                      TradePage.open(context, p.symbol, timeframe: _timeframe),
                ),
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
                      sigmas: visibleChartSigmas(
                        settings.chartSigmas,
                        side.bbSigma,
                      ),
                      extraEmas: settings.chartEmas,
                      height: 220,
                      onLineDragged: canEdit && !_sending
                          ? _onLineDragged
                          : null,
                      lines: [
                        PriceLine(
                          price: p.entryPrice,
                          label: '建値',
                          color: Colors.grey,
                          dashed: true,
                        ),
                        if (tp != null)
                          PriceLine(
                            price: tp,
                            label: '利確 ${formatPrice(tp)}',
                            color: Colors.green,
                            emphasized: _takeProfitDraft != null,
                            dragKey: canEdit ? _Exit.takeProfit : null,
                          ),
                        if (sl != null)
                          PriceLine(
                            price: sl,
                            label: '損切り ${formatPrice(sl)}',
                            color: Colors.red,
                            emphasized: _stopLossDraft != null,
                            dragKey: canEdit ? _Exit.stopLoss : null,
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
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 2),
              child: Text(
                '建値 ${formatPrice(p.entryPrice)}'
                '${tp == null ? '' : '  /  利確 ${formatPrice(tp)} (${_percentFromEntry(tp)})'}'
                '${sl == null ? '' : '  /  損切り ${formatPrice(sl)} (${_percentFromEntry(sl)})'}'
                '${mark == null ? '' : '  /  現在値 ${formatPrice(mark)}'}'
                '${rsi == null ? '' : '  /  RSI(${side.rsiPeriod}) ${rsi.toStringAsFixed(1)}'}',
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 2),
              child: Text(
                !canEdit
                    ? '利確 / 損切りの位置は、サーバーを新しい版にすると出ます '
                          '(右上から取引画面を開けば置けます)。'
                    : _dirty
                    ? '動かした線はまだ送っていません。「反映」で取引所へ送ります。'
                    : '利確 / 損切りの線は、右端のつまみ辺りを上下になぞると動かせます。',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: _dirty ? theme.colorScheme.primary : null,
                ),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              children: [
                if (canEdit && tp == null)
                  TextButton(
                    onPressed: _sending
                        ? null
                        : () => setState(
                            () => _takeProfitDraft = _defaultExit(
                              _Exit.takeProfit,
                            ),
                          ),
                    child: const Text('利確を置く'),
                  ),
                if (canEdit && sl == null)
                  TextButton(
                    onPressed: _sending
                        ? null
                        : () => setState(() {
                            _clearStopLoss = false;
                            _stopLossDraft = _defaultExit(_Exit.stopLoss);
                          }),
                    child: const Text('損切りを置く'),
                  ),
                // 手で建てた建玉の損切りは、取引所の仕組み上ここでは外せない。
                if (p.managed && sl != null)
                  TextButton(
                    onPressed: _sending
                        ? null
                        : () => setState(() {
                            _stopLossDraft = null;
                            _clearStopLoss = true;
                          }),
                    child: const Text('損切りを外す'),
                  ),
                if (_dirty) ...[
                  TextButton(
                    onPressed: _sending ? null : () => setState(_resetDrafts),
                    child: const Text('戻す'),
                  ),
                  FilledButton.icon(
                    onPressed: _sending ? null : _apply,
                    icon: _sending
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send, size: 16),
                    label: const Text('反映'),
                  ),
                ],
                TextButton.icon(
                  onPressed: _sending ? null : _close,
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('決済'),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
