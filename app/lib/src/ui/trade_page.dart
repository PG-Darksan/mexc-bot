import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../data/chart_data.dart';
import '../data/chart_drawing.dart';
import '../settings/app_settings.dart';
import '../state/app_state.dart';
import 'chart_overlays.dart';
import 'format.dart';
import 'interactive_chart.dart';
import 'lock_screen.dart';
import 'price_chart.dart';

/// チャートをタップしたときに値段を入れる欄。
enum _PriceField {
  none(''),
  limit('指値'),
  trigger('発動価格'),
  takeProfit('利確'),
  stopLoss('損切り');

  const _PriceField(this.label);

  final String label;
}

/// 取引画面。チャートを見ながら、成行・指値・条件付きの注文と、利確 /
/// 損切りをチャートから入れる。
///
/// * チャート: 2 本指でつまむと拡大・縮小、なぞると過去へ。「本数」で描く本数を
///   選べる。線を引く道具 (横線 / 2 点の線 / 消す) がある。
/// * 注文の値段は、欄の横の「チャートで選ぶ」を押してからチャートをタップ
///   するか、チャートを長押しして出る選択肢から入れる。
/// * 数量は証拠金 (USDT) で入れるか、使える残高の何 % かをスライダーで選ぶ。
///
/// 注文はサーバーが取引所へ出す (取引所の鍵はサーバーにだけある)。
class TradePage extends StatefulWidget {
  const TradePage({
    super.key,
    required this.symbol,
    this.timeframe = Timeframe.m15,
    this.source,
  });

  final String symbol;
  final Timeframe timeframe;

  /// テストで差し替える。null なら公開 API から取る。
  final ChartDataSource? source;

  static Future<void> open(
    BuildContext context,
    String symbol, {
    Timeframe? timeframe,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          TradePage(symbol: symbol, timeframe: timeframe ?? Timeframe.m15),
    ),
  );

  @override
  State<TradePage> createState() => _TradePageState();
}

class _TradePageState extends State<TradePage> {
  static const List<Timeframe> _timeframes = [
    Timeframe.m1,
    Timeframe.m5,
    Timeframe.m15,
    Timeframe.h1,
    Timeframe.h4,
    Timeframe.d1,
  ];

  static const Map<Timeframe, String> _shortLabels = {
    Timeframe.m1: '1m',
    Timeframe.m5: '5m',
    Timeframe.m15: '15m',
    Timeframe.h1: '1h',
    Timeframe.h4: '4h',
    Timeframe.d1: '1D',
  };

  /// 取る本数。つまんで縮めたときに、このくらいまで遡って見られる。
  static const int _historyBars = 1000;

  late final ChartDataSource _source = widget.source ?? ChartDataSource();
  late String _symbol = widget.symbol;
  late Timeframe _timeframe = widget.timeframe;
  List<Candle> _candles = const [];
  bool _loading = false;
  String? _error;
  ContractInfo? _contract;
  List<String> _allSymbols = const [];
  Timer? _refreshTimer;

  late final ChartViewport _viewport;
  ChartTool _tool = ChartTool.none;
  Color _drawColor = ChartDrawing.defaultColor;
  bool _chartOnly = false;

  // ── 出そうとしている注文 ──
  TradeDirection _direction = TradeDirection.long;
  ManualOrderKind _kind = ManualOrderKind.market;
  TriggerExecution _triggerExecution = TriggerExecution.market;
  final _priceCtrl = TextEditingController();
  final _triggerCtrl = TextEditingController();
  final _tpCtrl = TextEditingController();
  final _slCtrl = TextEditingController();
  final _marginCtrl = TextEditingController();
  double _percent = 0;
  int? _leverage;
  _PriceField _active = _PriceField.none;
  bool _submitting = false;

  AppState? _state;

  @override
  void initState() {
    super.initState();
    for (final c in [_priceCtrl, _triggerCtrl, _tpCtrl, _slCtrl]) {
      c.addListener(_redraw);
    }
    _loadChart();
    _loadSymbols();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _refreshLatest(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_state == null) {
      _state = state;
      _viewport = ChartViewport(
        visibleBars: state.settings.chartBars.toDouble().clamp(
          ChartViewport.minBars,
          _historyBars.toDouble(),
        ),
      );
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    for (final c in [_priceCtrl, _triggerCtrl, _tpCtrl, _slCtrl, _marginCtrl]) {
      c.dispose();
    }
    _viewport.dispose();
    if (widget.source == null) _source.dispose();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  // ── 相場 ──────────────────────────────────────────────────

  Future<void> _loadChart() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _source.klines(_symbol, _timeframe, bars: _historyBars),
        _source.contract(_symbol),
      ]);
      if (!mounted) return;
      setState(() {
        _candles = results[0] as List<Candle>;
        _contract = results[1] as ContractInfo?;
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

  /// 直近の数本だけ取り直して足し込む (全部取り直すと通信が重いので)。
  Future<void> _refreshLatest() async {
    if (_loading || _candles.isEmpty || !mounted) return;
    final symbol = _symbol;
    final timeframe = _timeframe;
    try {
      final fresh = await _source.klines(symbol, timeframe, bars: 3);
      if (!mounted || symbol != _symbol || timeframe != _timeframe) return;
      final merged = List<Candle>.of(_candles);
      var added = 0;
      for (final c in fresh) {
        if (c.openTime > merged.last.openTime) {
          merged.add(c);
          added++;
        } else {
          final i = merged.lastIndexWhere((x) => x.openTime == c.openTime);
          if (i >= 0) merged[i] = c;
        }
      }
      // 過去を見ているときは、新しい足が増えても見ている所を動かさない。
      if (added > 0 && !_viewport.followsLatest) {
        _viewport.update(rightOffset: _viewport.rightOffset + added);
      }
      setState(() => _candles = merged);
    } catch (_) {
      // 取れなければ次の回に。チャートは前のまま見られる。
    }
  }

  Future<void> _loadSymbols() async {
    try {
      final names = await _source.symbols();
      if (!mounted) return;
      setState(() => _allSymbols = names);
    } catch (_) {}
  }

  void _changeSymbol(String symbol) {
    if (symbol == _symbol) return;
    setState(() {
      _symbol = symbol;
      _candles = const [];
      _contract = null;
      _priceCtrl.clear();
      _triggerCtrl.clear();
      _tpCtrl.clear();
      _slCtrl.clear();
      _active = _PriceField.none;
      _tool = ChartTool.none;
    });
    _viewport.showLatest(_viewport.visibleBars);
    _loadChart();
  }

  double? get _lastPrice => _candles.isEmpty ? null : _candles.last.close;

  // ── 値段の入れ方 ────────────────────────────────────────────

  /// 銘柄の刻みに合わせて、入力欄に入れる文字にする。
  String _priceText(double price) {
    final c = _contract;
    if (c == null || c.priceUnit <= 0) {
      return formatPrice(price).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return c.roundPrice(price, roundUp: false).toStringAsFixed(
      c.priceScale.clamp(0, 12),
    );
  }

  static double? _parse(String text) {
    final v = double.tryParse(text.trim().replaceAll(',', ''));
    return v == null || v <= 0 ? null : v;
  }

  TextEditingController _controllerOf(_PriceField field) => switch (field) {
    _PriceField.limit => _priceCtrl,
    _PriceField.trigger => _triggerCtrl,
    _PriceField.takeProfit => _tpCtrl,
    _PriceField.stopLoss => _slCtrl,
    _PriceField.none => _priceCtrl,
  };

  void _setField(_PriceField field, double price) {
    _controllerOf(field).text = _priceText(price);
  }

  void _onTapPrice(double price, int time) {
    if (_active == _PriceField.none) return;
    final field = _active;
    setState(() {
      _setField(field, price);
      _active = _PriceField.none;
    });
    HapticFeedback.selectionClick();
  }

  Future<void> _onLongPressPrice(double price, int time) async {
    final state = AppScope.of(context);
    final managed = state.snapshot.positions
        .where((p) => p.symbol == _symbol)
        .toList();
    final foreign = state.foreignPositions
        .where((p) => p.symbol == _symbol)
        .toList();
    final text = _priceText(price);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              dense: true,
              title: Text(
                '$text で',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            _choice(context, 'limitLong', Icons.call_made, Colors.green, '指値で買う (ロング)'),
            _choice(context, 'limitShort', Icons.call_received, Colors.red, '指値で売る (ショート)'),
            _choice(
              context,
              'triggerLong',
              Icons.bolt,
              Colors.green,
              'この値段になったら買う (条件付き)',
            ),
            _choice(
              context,
              'triggerShort',
              Icons.bolt,
              Colors.red,
              'この値段になったら売る (条件付き)',
            ),
            _choice(context, 'tp', Icons.flag, Colors.green, '注文の利確をここに'),
            _choice(context, 'sl', Icons.block, Colors.red, '注文の損切りをここに'),
            if (managed.isNotEmpty || foreign.isNotEmpty) ...[
              const Divider(),
              _choice(context, 'posTp', Icons.flag_circle, Colors.green, '持っている建玉の利確をここに置く'),
              _choice(context, 'posSl', Icons.do_not_disturb_on, Colors.red, '持っている建玉の損切りをここに置く'),
            ],
            const Divider(),
            _choice(context, 'hline', Icons.horizontal_rule, ChartDrawing.defaultColor, '横線を引く'),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() {
      switch (choice) {
        case 'limitLong' || 'limitShort':
          _direction = choice == 'limitLong'
              ? TradeDirection.long
              : TradeDirection.short;
          _kind = ManualOrderKind.limit;
          _setField(_PriceField.limit, price);
        case 'triggerLong' || 'triggerShort':
          _direction = choice == 'triggerLong'
              ? TradeDirection.long
              : TradeDirection.short;
          _kind = ManualOrderKind.trigger;
          _setField(_PriceField.trigger, price);
        case 'tp':
          _setField(_PriceField.takeProfit, price);
        case 'sl':
          _setField(_PriceField.stopLoss, price);
      }
    });
    switch (choice) {
      case 'hline':
        await state.setDrawings(_symbol, [
          ...state.drawingsOf(_symbol),
          ChartDrawing.horizontal(price, color: _drawColor),
        ]);
      case 'posTp' || 'posSl':
        await _applyPositionExitAt(
          price,
          takeProfit: choice == 'posTp',
          managed: managed,
          foreign: foreign,
        );
    }
  }

  Widget _choice(
    BuildContext context,
    String value,
    IconData icon,
    Color color,
    String label,
  ) => ListTile(
    dense: true,
    leading: Icon(icon, color: color),
    title: Text(label),
    onTap: () => Navigator.of(context).pop(value),
  );

  /// 持っている建玉の利確 / 損切りを、長押しした値段に置く (確かめてから)。
  Future<void> _applyPositionExitAt(
    double price, {
    required bool takeProfit,
    required List<ManagedPosition> managed,
    required List<PositionInfo> foreign,
  }) async {
    final state = AppScope.of(context);
    final what = takeProfit ? '利確' : '損切り';
    final ok = await _confirm(
      '建玉の$whatを置きます',
      '${_symbol.replaceAll('_USDT', '')} の建玉の$whatを ${_priceText(price)} に置きます。'
          '取引所へすぐ送ります。',
      action: '置く',
    );
    if (!ok) return;
    await _guard(() async {
      for (final p in managed) {
        await state.updatePositionExit(
          p.id,
          takeProfitPrice: takeProfit ? price : null,
          stopLossPrice: takeProfit ? null : price,
        );
      }
      for (final p in foreign) {
        await state.updateExchangePositionExit(
          positionId: p.positionId,
          takeProfitPrice: takeProfit ? price : null,
          stopLossPrice: takeProfit ? null : price,
        );
      }
      return '建玉の$whatを送りました';
    });
  }

  // ── 注文 ───────────────────────────────────────────────────

  int _defaultLeverage(AppState state) =>
      state.snapshot.config.sideOf(_direction).leverage;

  int _leverageOf(AppState state) => _leverage ?? _defaultLeverage(state);

  ManualOrderRequest _request(AppState state) => ManualOrderRequest(
    symbol: _symbol,
    direction: _direction,
    kind: _kind,
    marginUsdt: _parse(_marginCtrl.text) ?? 0,
    leverage: _leverageOf(state),
    price: _kind == ManualOrderKind.limit ||
            (_kind == ManualOrderKind.trigger &&
                _triggerExecution == TriggerExecution.limit)
        ? _parse(_priceCtrl.text)
        : null,
    triggerPrice: _kind == ManualOrderKind.trigger
        ? _parse(_triggerCtrl.text)
        : null,
    triggerExecution: _triggerExecution,
    takeProfitPrice: _parse(_tpCtrl.text),
    stopLossPrice: _parse(_slCtrl.text),
  );

  Future<void> _submit() async {
    final state = AppScope.of(context);
    final request = _request(state);
    final errors = request.validate(lastPrice: _lastPrice);
    if (errors.isNotEmpty) {
      _snack(errors.join('\n'));
      return;
    }
    final estimate = _estimate(state, request);
    final ok = await _confirm(
      request.direction.isLong ? '買い (ロング) の注文' : '売り (ショート) の注文',
      '${request.describe()}\n\n$estimate\n\n'
          '${request.kind == ManualOrderKind.trigger && (request.takeProfitPrice != null || request.stopLossPrice != null) ? '条件付き注文の利確 / 損切りは、発動して建ったあとにサーバーが置きます。\n\n' : ''}'
          '実際に取引所へ注文を出します。',
      action: '注文する',
      danger: request.direction.isShort,
    );
    if (!ok) return;
    await _guard(() => state.placeManualOrder(request));
  }

  /// 確かめの窓に出す、建玉の大きさの目安。
  String _estimate(AppState state, ManualOrderRequest request) {
    final notional = request.marginUsdt * request.leverage;
    final reference = request.referencePrice(_lastPrice);
    final contract = _contract;
    final vol = (contract != null && reference != null)
        ? contract.volumeForMargin(
            marginUsdt: request.marginUsdt,
            leverage: request.leverage.toDouble(),
            price: reference,
          )
        : null;
    return '建玉の大きさ 約 ${notional.toStringAsFixed(2)} USDT'
        '${vol == null ? '' : ' (約 ${vol.toStringAsFixed(contract!.volScale)} 枚)'}';
  }

  /// 送る処理を包む。待っている間はボタンを押せなくし、結果を知らせる。
  Future<void> _guard(Future<String?> Function() action) async {
    setState(() => _submitting = true);
    try {
      final text = await action();
      if (!mounted) return;
      if (text != null) _snack(text);
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('出来ませんでした'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('閉じる'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<bool> _confirm(
    String title,
    String body, {
    required String action,
    bool danger = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ── 線 ─────────────────────────────────────────────────────

  List<PriceLine> _lines(AppState state) {
    final lines = <PriceLine>[];
    for (final p in state.snapshot.positions.where((p) => p.symbol == _symbol)) {
      lines
        ..add(PriceLine(
          price: p.entryPrice,
          label: '建値 ${p.direction.label}',
          color: Colors.grey,
          dashed: true,
        ))
        ..add(PriceLine(price: p.takeProfitPrice, label: '利確', color: Colors.green));
      if (p.stopLossPrice != null) {
        lines.add(PriceLine(price: p.stopLossPrice!, label: '損切り', color: Colors.red));
      }
    }
    for (final p in state.foreignPositions.where((p) => p.symbol == _symbol)) {
      lines.add(PriceLine(
        price: p.holdAvgPrice,
        label: '建値 (手) ${p.isShort ? 'ショート' : 'ロング'}',
        color: Colors.blueGrey,
        dashed: true,
      ));
      if (p.liquidatePrice > 0) {
        lines.add(PriceLine(
          price: p.liquidatePrice,
          label: '清算',
          color: Colors.deepOrange,
          dashed: true,
        ));
      }
    }
    for (final o in state.openOrdersOf(_symbol)) {
      final price = o.linePrice;
      if (price == null || price <= 0) continue;
      lines.add(PriceLine(
        price: price,
        label: o.fromBot ? 'ボット ${o.label}' : o.label,
        color: o.kind == ExchangeOrderKind.trigger
            ? Colors.purple
            : (o.isBuy ? Colors.teal : Colors.pink),
        dashed: o.kind == ExchangeOrderKind.trigger || o.fromBot,
      ));
    }
    // これから出す注文。
    final limit = _parse(_priceCtrl.text);
    final trigger = _parse(_triggerCtrl.text);
    final tp = _parse(_tpCtrl.text);
    final sl = _parse(_slCtrl.text);
    final usesLimit = _kind == ManualOrderKind.limit ||
        (_kind == ManualOrderKind.trigger &&
            _triggerExecution == TriggerExecution.limit);
    if (usesLimit && limit != null) {
      lines.add(PriceLine(
        price: limit,
        label: '注文 指値',
        color: Colors.blue,
        emphasized: _active == _PriceField.limit,
      ));
    }
    if (_kind == ManualOrderKind.trigger && trigger != null) {
      lines.add(PriceLine(
        price: trigger,
        label: '注文 発動',
        color: Colors.deepPurple,
        emphasized: _active == _PriceField.trigger,
      ));
    }
    if (tp != null) {
      lines.add(PriceLine(
        price: tp,
        label: '注文の利確',
        color: Colors.green,
        dashed: true,
        emphasized: _active == _PriceField.takeProfit,
      ));
    }
    if (sl != null) {
      lines.add(PriceLine(
        price: sl,
        label: '注文の損切り',
        color: Colors.red,
        dashed: true,
        emphasized: _active == _PriceField.stopLoss,
      ));
    }
    return lines;
  }

  // ── 画面 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final side = state.snapshot.config.primarySide;
    final last = _lastPrice;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: _pickSymbol,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _symbol.replaceAll('_USDT', ''),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
                if (last != null)
                  Text(
                    formatPrice(last),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: _chartOnly ? '注文欄を出す' : 'チャートを大きく',
            icon: Icon(_chartOnly ? Icons.vertical_split : Icons.fullscreen),
            onPressed: () => setState(() => _chartOnly = !_chartOnly),
          ),
          const ChartOverlayButton(),
          const LockButton(),
          IconButton(
            tooltip: '取り直す',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadChart,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final chartHeight = _chartOnly
              ? math.max(200.0, constraints.maxHeight - 96)
              : math.max(
                  220.0,
                  math.min(constraints.maxHeight * 0.48, constraints.maxHeight - 220),
                );
          return Column(
            children: [
              _toolbar(context, state),
              if (_active != _PriceField.none) _activeBanner(context),
              SizedBox(
                height: chartHeight,
                child: _chart(context, state, side),
              ),
              if (!_chartOnly)
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    children: [
                      _orderPanel(context, state),
                      const SizedBox(height: 16),
                      _holdings(context, state),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _chart(BuildContext context, AppState state, SideConfig side) {
    if (_error != null && _candles.isEmpty) {
      return Center(
        child: Text(
          'チャートを取れませんでした\n$_error',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    if (_candles.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return InteractiveChart(
      candles: _candles,
      viewport: _viewport,
      bbPeriod: side.bbPeriod,
      bbSigma: side.bbSigma,
      emaPeriod: side.emaPeriod,
      sigmas: visibleChartSigmas(state.settings.chartSigmas, side.bbSigma),
      extraEmas: state.settings.chartEmas,
      lines: _lines(state),
      drawings: state.drawingsOf(_symbol),
      tool: _tool,
      drawColor: _drawColor,
      onTapPrice: _onTapPrice,
      onLongPressPrice: _onLongPressPrice,
      onDrawingsChanged: (list) => state.setDrawings(_symbol, list),
      onViewportSettled: () {
        final bars = _viewport.visibleBars.round();
        if (bars != state.settings.chartBars) {
          unawaited(
            state.updateAppSettings(state.settings.copyWith(chartBars: bars)),
          );
        }
      },
    );
  }

  Widget _toolbar(BuildContext context, AppState state) {
    final theme = Theme.of(context);
    Widget tool(ChartTool t, IconData icon, String tip) => IconButton(
      tooltip: tip,
      isSelected: _tool == t,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 20),
      selectedIcon: Icon(icon, size: 20, color: theme.colorScheme.primary),
      style: _tool == t
          ? IconButton.styleFrom(
              backgroundColor: theme.colorScheme.primaryContainer,
            )
          : null,
      onPressed: () => setState(() {
        _tool = _tool == t ? ChartTool.none : t;
        _active = _PriceField.none;
      }),
    );

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            for (final tf in _timeframes)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: ChoiceChip(
                  label: Text(
                    _shortLabels[tf] ?? tf.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: tf == _timeframe,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (_) {
                    if (tf == _timeframe) return;
                    setState(() => _timeframe = tf);
                    _viewport.showLatest(_viewport.visibleBars);
                    _loadChart();
                  },
                ),
              ),
            const SizedBox(width: 4),
            PopupMenuButton<int>(
              tooltip: '描く本数',
              onSelected: (bars) {
                _viewport.showLatest(bars.toDouble());
                unawaited(
                  state.updateAppSettings(
                    state.settings.copyWith(chartBars: bars),
                  ),
                );
              },
              itemBuilder: (context) => [
                for (final n in AppSettings.chartBarChoices)
                  PopupMenuItem(value: n, child: Text('$n 本')),
                PopupMenuItem(
                  value: math.max(10, _candles.length),
                  child: const Text('全部'),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.view_week_outlined, size: 18),
                    const SizedBox(width: 2),
                    Text(
                      '${_viewport.visibleBars.round()} 本',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            tool(ChartTool.horizontal, Icons.horizontal_rule, '横線を引く (タップ)'),
            tool(ChartTool.trend, Icons.timeline, '2 点を結ぶ線を引く (2 回タップ)'),
            tool(ChartTool.erase, Icons.auto_fix_off, '線を消す (線をタップ)'),
            IconButton(
              tooltip: '線の色',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() {
                final palette = ChartDrawing.palette;
                final i = palette.indexWhere((c) => c == _drawColor);
                _drawColor = palette[(i + 1) % palette.length];
              }),
              icon: Icon(Icons.circle, size: 18, color: _drawColor),
            ),
            IconButton(
              tooltip: 'この銘柄の線を全部消す',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.layers_clear_outlined, size: 20),
              onPressed: state.drawingsOf(_symbol).isEmpty
                  ? null
                  : () async {
                      final ok = await _confirm(
                        '線を全部消します',
                        '${_symbol.replaceAll('_USDT', '')} に引いた線を全部消します。',
                        action: '消す',
                      );
                      if (ok) await state.setDrawings(_symbol, const []);
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _activeBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
        child: Row(
          children: [
            Icon(Icons.touch_app, size: 18, color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'チャートをタップして「${_active.label}」の値段を決めて下さい',
                style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _active = _PriceField.none),
              child: const Text('やめる'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSymbol() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _SymbolPickerDialog(symbols: _allSymbols),
    );
    if (picked != null) _changeSymbol(picked);
  }

  // ── 注文欄 ─────────────────────────────────────────────────

  Widget _orderPanel(BuildContext context, AppState state) {
    final theme = Theme.of(context);
    final available = state.displayAsset?.availableBalance;
    final request = _request(state);
    final errors = request.validate(lastPrice: _lastPrice);
    final hasInput = (_parse(_marginCtrl.text) ?? 0) > 0;
    final isLong = _direction.isLong;
    final buyColor = const Color(0xFF26A69A);
    final sellColor = const Color(0xFFEF5350);
    final maxLeverage = _contract?.maxLeverage ?? 125;
    final leverage = _leverageOf(state);
    final leverageChoices = {
      for (final v in [1, 2, 3, 5, 10, 15, 20, 25, 50, 75, 100, 125, 200])
        if (v <= maxLeverage) v,
      leverage,
    }.toList()..sort();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  '注文',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  available == null
                      ? '残高: サーバーから取れていません'
                      : '使える残高 ${available.toStringAsFixed(2)} USDT',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<TradeDirection>(
              segments: [
                ButtonSegment(
                  value: TradeDirection.long,
                  label: const Text('買い (ロング)'),
                  icon: Icon(Icons.trending_up, color: buyColor),
                ),
                ButtonSegment(
                  value: TradeDirection.short,
                  label: const Text('売り (ショート)'),
                  icon: Icon(Icons.trending_down, color: sellColor),
                ),
              ],
              selected: {_direction},
              onSelectionChanged: (s) => setState(() => _direction = s.first),
            ),
            const SizedBox(height: 8),
            SegmentedButton<ManualOrderKind>(
              segments: [
                for (final k in ManualOrderKind.values)
                  ButtonSegment(value: k, label: Text(k.label)),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() {
                _kind = s.first;
                _active = _PriceField.none;
              }),
            ),
            const SizedBox(height: 8),
            if (_kind == ManualOrderKind.limit)
              _priceInput(_PriceField.limit, '指値の値段'),
            if (_kind == ManualOrderKind.trigger) ...[
              _priceInput(
                _PriceField.trigger,
                '発動価格 (この値段に届いたら出す)',
                helper: _triggerHint(),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text('発動したら', style: theme.textTheme.bodySmall),
                  const SizedBox(width: 8),
                  SegmentedButton<TriggerExecution>(
                    segments: [
                      for (final e in TriggerExecution.values)
                        ButtonSegment(value: e, label: Text(e.label)),
                    ],
                    selected: {_triggerExecution},
                    onSelectionChanged: (s) =>
                        setState(() => _triggerExecution = s.first),
                  ),
                ],
              ),
              if (_triggerExecution == TriggerExecution.limit) ...[
                const SizedBox(height: 6),
                _priceInput(_PriceField.limit, '発動したときの指値の値段'),
              ],
            ],
            if (_kind == ManualOrderKind.market)
              Text(
                'いまの値段 (${formatPrice(_lastPrice)}) ですぐ建てます。',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            // 数量
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _marginCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: '証拠金 (USDT)',
                      isDense: true,
                      suffixText: 'USDT',
                    ),
                    onChanged: (v) => setState(() {
                      final margin = _parse(v) ?? 0;
                      _percent = (available ?? 0) > 0
                          ? (margin / available! * 100).clamp(0, 100).toDouble()
                          : 0;
                    }),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: leverage,
                  items: [
                    for (final v in leverageChoices)
                      DropdownMenuItem(value: v, child: Text('$v 倍')),
                  ],
                  onChanged: (v) => setState(() => _leverage = v),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _percent,
                    min: 0,
                    max: 100,
                    divisions: 100,
                    label: '${_percent.round()}%',
                    onChanged: available == null || available <= 0
                        ? null
                        : (v) => setState(() {
                            _percent = v;
                            _marginCtrl.text = (available * v / 100)
                                .toStringAsFixed(2);
                          }),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${_percent.round()}%',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final p in const [10, 25, 50, 75, 100])
                  ActionChip(
                    label: Text('$p%', style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onPressed: available == null || available <= 0
                        ? null
                        : () => setState(() {
                            _percent = p.toDouble();
                            _marginCtrl.text = (available * p / 100)
                                .toStringAsFixed(2);
                          }),
                  ),
              ],
            ),
            if (hasInput)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _estimate(state, request),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            _priceInput(
              _PriceField.takeProfit,
              '利確 (なしでも可)',
              helper: _distanceHint(_parse(_tpCtrl.text), request),
            ),
            const SizedBox(height: 6),
            _priceInput(
              _PriceField.stopLoss,
              '損切り (なしでも可)',
              helper: _distanceHint(_parse(_slCtrl.text), request),
            ),
            if (_kind == ManualOrderKind.trigger &&
                (_parse(_tpCtrl.text) != null || _parse(_slCtrl.text) != null))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '条件付き注文の利確 / 損切りは、発動して建ったあとにサーバーが置きます。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (hasInput && errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  errors.join('\n'),
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                ),
              ),
            if (!state.connected)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'サーバーにつながっていないので、注文は出せません。',
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: isLong ? buyColor : sellColor,
                minimumSize: const Size.fromHeight(44),
              ),
              onPressed: _submitting || !state.connected || !hasInput || errors.isNotEmpty
                  ? null
                  : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(isLong ? Icons.trending_up : Icons.trending_down),
              label: Text(
                '${_kind.label}で${isLong ? '買う (ロング)' : '売る (ショート)'}',
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _triggerHint() {
    final trigger = _parse(_triggerCtrl.text);
    final last = _lastPrice;
    if (trigger == null || last == null) return null;
    final above = trigger >= last;
    return 'いま ${formatPrice(last)} → ${above ? '上がって' : '下がって'} '
        '${_priceText(trigger)} ${above ? '以上' : '以下'}になったら出します';
  }

  String? _distanceHint(double? price, ManualOrderRequest request) {
    final entry = request.referencePrice(_lastPrice);
    if (price == null || entry == null || entry <= 0) return null;
    final pct = (price - entry) / entry * 100;
    return '入値から ${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%';
  }

  Widget _priceInput(_PriceField field, String label, {String? helper}) {
    final controller = _controllerOf(field);
    final active = _active == field;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              helperText: helper,
              isDense: true,
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '消す',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(controller.clear),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filledTonal(
          tooltip: 'チャートをタップして選ぶ',
          isSelected: active,
          icon: const Icon(Icons.ads_click, size: 20),
          onPressed: () => setState(() {
            _active = active ? _PriceField.none : field;
            _tool = ChartTool.none;
            if (_active != _PriceField.none) _chartOnly = false;
          }),
        ),
      ],
    );
  }

  // ── 持っている建玉と、出ている注文 ─────────────────────────

  Widget _holdings(BuildContext context, AppState state) {
    final theme = Theme.of(context);
    final managed = state.snapshot.positions.where((p) => p.symbol == _symbol).toList();
    final foreign = state.foreignPositions.where((p) => p.symbol == _symbol).toList();
    final orders = state.openOrdersOf(_symbol);
    final exits = state.pendingExitsOf(_symbol);
    final mark = state.lastPriceOf(_symbol) ?? _lastPrice;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${_symbol.replaceAll('_USDT', '')} の建玉',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        if (managed.isEmpty && foreign.isEmpty)
          Text('持っていません。', style: theme.textTheme.bodySmall),
        for (final p in managed)
          _PositionTile(
            title: '${p.direction.label} ${p.vol} 枚 (ボット)',
            color: p.direction.isShort ? Colors.redAccent : Colors.green,
            lines: [
              '建値 ${formatPrice(p.entryPrice)} / 利確 ${formatPrice(p.takeProfitPrice)}'
                  ' / 損切り ${p.stopLossPrice == null ? 'なし' : formatPrice(p.stopLossPrice)}',
              if (mark != null) '評価損益 ${formatPnl(p.pnlAt(mark))}',
            ],
            busy: _submitting,
            onEdit: () => _editExit(
              title: '${p.direction.label} ${p.vol} 枚',
              takeProfit: p.takeProfitPrice,
              stopLoss: p.stopLossPrice,
              apply: (tp, sl) => state.updatePositionExit(
                p.id,
                takeProfitPrice: tp,
                stopLossPrice: sl,
                clearStopLoss: sl == null,
              ),
            ),
            onClose: () => _closePosition(
              '${p.direction.label} ${p.vol} 枚',
              () => state.closePosition(p.id),
            ),
          ),
        for (final p in foreign)
          _PositionTile(
            title: '${p.isShort ? 'ショート' : 'ロング'} ${p.holdVol} 枚 (手で建てたもの)',
            color: p.isShort ? Colors.redAccent : Colors.green,
            lines: [
              '建値 ${formatPrice(p.holdAvgPrice)} / ${p.leverage} 倍'
                  '${p.liquidatePrice > 0 ? ' / 清算 ${formatPrice(p.liquidatePrice)}' : ''}',
              if (mark != null)
                '評価損益 ${formatPnl(p.unrealizedPnl(mark, state.contractSizeOf(p.symbol)))}',
            ],
            busy: _submitting,
            onEdit: () => _editExit(
              title: '${p.isShort ? 'ショート' : 'ロング'} ${p.holdVol} 枚',
              takeProfit: null,
              stopLoss: null,
              apply: (tp, sl) => state.updateExchangePositionExit(
                positionId: p.positionId,
                takeProfitPrice: tp,
                stopLossPrice: sl,
              ),
              allowClear: false,
            ),
            onClose: () => _closePosition(
              '${p.isShort ? 'ショート' : 'ロング'} ${p.holdVol} 枚',
              () => state.closeExchangePosition(p.positionId),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          '出ている注文',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        if (state.snapshot.openOrders == null)
          Text(
            'サーバーがまだ注文の一覧を返していません (サーバーの更新が要るかもしれません)。',
            style: theme.textTheme.bodySmall,
          )
        else if (orders.isEmpty)
          Text('ありません。', style: theme.textTheme.bodySmall),
        for (final o in orders)
          Card(
            child: ListTile(
              dense: true,
              leading: Icon(
                o.kind == ExchangeOrderKind.trigger ? Icons.bolt : Icons.list_alt,
                color: o.isBuy ? Colors.green : Colors.redAccent,
              ),
              title: Text(o.fromBot ? 'ボット: ${o.label}' : o.label),
              subtitle: Text('${o.vol} 枚'
                  '${o.leverage == null ? '' : ' / ${o.leverage} 倍'}'
                  '${o.takeProfitPrice == null ? '' : ' / 利確 ${formatPrice(o.takeProfitPrice)}'}'
                  '${o.stopLossPrice == null ? '' : ' / 損切り ${formatPrice(o.stopLossPrice)}'}'),
              trailing: TextButton(
                onPressed: _submitting
                    ? null
                    : () async {
                        final ok = await _confirm(
                          '注文を取り消します',
                          '${o.label} (${o.vol} 枚) を取り消します。'
                              '${o.fromBot ? '\nボットの買い足し / 売り足しの指値です。取り消すと、その建玉には足さなくなります。' : ''}',
                          action: '取り消す',
                        );
                        if (!ok) return;
                        await _guard(() async {
                          await state.cancelExchangeOrder(o);
                          return '取り消しました';
                        });
                      },
                child: const Text('取消'),
              ),
            ),
          ),
        for (final e in exits)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '条件付き注文 (ID ${e.planOrderId}) が建ったら、利確 ${formatPrice(e.takeProfitPrice)} / '
              '損切り ${formatPrice(e.stopLossPrice)} をサーバーが置きます。',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Future<void> _closePosition(String what, Future<void> Function() close) async {
    final ok = await _confirm(
      '成行で決済します',
      '${_symbol.replaceAll('_USDT', '')} の $what を、いまの値段で決済します。',
      action: '決済する',
      danger: true,
    );
    if (!ok) return;
    await _guard(() async {
      await close();
      return '決済を送りました';
    });
  }

  Future<void> _editExit({
    required String title,
    required double? takeProfit,
    required double? stopLoss,
    required Future<void> Function(double? tp, double? sl) apply,
    bool allowClear = true,
  }) async {
    final tpCtrl = TextEditingController(
      text: takeProfit == null ? '' : _priceText(takeProfit),
    );
    final slCtrl = TextEditingController(
      text: stopLoss == null ? '' : _priceText(stopLoss),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$title の利確 / 損切り'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: tpCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '利確'),
            ),
            TextField(
              controller: slCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '損切り',
                helperText: allowClear ? '空にすると損切りを外します' : null,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'チャートを長押しして「持っている建玉の利確 / 損切りをここに置く」からも置けます。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('取引所へ送る'),
          ),
        ],
      ),
    );
    final tp = _parse(tpCtrl.text);
    final sl = _parse(slCtrl.text);
    tpCtrl.dispose();
    slCtrl.dispose();
    if (ok != true) return;
    await _guard(() async {
      await apply(tp, sl);
      return '利確 / 損切りを送りました';
    });
  }
}

/// 建玉 1 つ。利確 / 損切りを変える・決済するボタン付き。
class _PositionTile extends StatelessWidget {
  const _PositionTile({
    required this.title,
    required this.color,
    required this.lines,
    required this.busy,
    required this.onEdit,
    required this.onClose,
  });

  final String title;
  final Color color;
  final List<String> lines;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
            for (final line in lines) Text(line, style: theme.textTheme.bodySmall),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: busy ? null : onEdit,
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('利確 / 損切り'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : onClose,
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

/// 銘柄を名前で探す窓。
class _SymbolPickerDialog extends StatefulWidget {
  const _SymbolPickerDialog({required this.symbols});

  final List<String> symbols;

  @override
  State<_SymbolPickerDialog> createState() => _SymbolPickerDialogState();
}

class _SymbolPickerDialogState extends State<_SymbolPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toUpperCase();
    final hits = q.isEmpty
        ? widget.symbols.take(50).toList()
        : widget.symbols.where((s) => s.contains(q)).take(50).toList();
    return AlertDialog(
      title: TextField(
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(
          hintText: widget.symbols.isEmpty ? '一覧を読み込み中…' : 'BTC / ETH / SOL …',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
        ),
        onChanged: (v) => setState(() => _query = v),
        onSubmitted: (v) {
          final key = v.trim().toUpperCase();
          final hit = widget.symbols.firstWhere(
            (s) => s == key || s == '${key}_USDT',
            orElse: () => '',
          );
          if (hit.isNotEmpty) Navigator.of(context).pop(hit);
        },
      ),
      content: SizedBox(
        width: 320,
        height: 360,
        child: ListView.builder(
          itemCount: hits.length,
          itemBuilder: (context, i) => ListTile(
            dense: true,
            title: Text(hits[i].replaceAll('_USDT', '')),
            onTap: () => Navigator.of(context).pop(hits[i]),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
      ],
    );
  }
}
