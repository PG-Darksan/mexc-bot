import 'dart:math' as math;

import '../api/mexc_exception.dart';
import '../api/mexc_rest_client.dart';
import '../models/contract_info.dart';
import '../models/signal.dart';
import '../models/strategy_config.dart';

/// 発注まわりだけを担当する。
///
/// MEXC の先物は side の数値で新規/決済と売買方向を表す。
/// 1=買い新規 / 2=売り決済 / 3=売り新規 / 4=買い決済。
/// どの番号を使うかは [TradeDirection] が持っている。
class TradeExecutor {
  TradeExecutor({required MexcRestClient rest, this.onLog}) : _rest = rest;

  final MexcRestClient _rest;
  final void Function(String message)? onLog;

  final math.Random _random = math.Random();

  String _newExternalOid() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final r = _random.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return 'bot$ts$r';
  }

  /// シグナルの方向どおりに新規建てする。
  ///
  /// 利確は発注と同時に takeProfitPrice を付けるのが基本。
  /// そうすればボットが落ちていても取引所側で決済される。
  Future<ManagedPosition> open({
    required SignalEvaluation evaluation,
    required ContractInfo contract,
    required StrategyConfig config,
  }) async {
    final direction = evaluation.direction;
    final side = config.sideOf(direction);
    final isShort = direction.isShort;
    final markPrice = evaluation.price;

    // 指値は自分に有利な側 (ショートは高く売る / ロングは安く買う) へ離す。
    final entryPrice = config.orderType == EntryOrderType.limit
        ? contract.roundPrice(
            markPrice *
                (isShort
                    ? 1 + side.limitOffsetPercent / 100
                    : 1 - side.limitOffsetPercent / 100),
            roundUp: isShort,
          )
        : contract.roundPrice(markPrice, roundUp: !isShort);

    final vol = contract.volumeForMargin(
      marginUsdt: side.marginPerTradeUsdt,
      leverage: side.leverage.toDouble(),
      price: entryPrice,
    );
    if (vol == null) {
      throw StateError(
        '${contract.symbol}: 証拠金 ${side.marginPerTradeUsdt} USDT では'
        '最小数量 (${contract.minVol} 枚) に届きません。',
      );
    }

    // 利確目標は「検知した瞬間の EMA」を固定して求める。以後 EMA が動いても
    // 目標は動かさない。決済注文が約定しやすい側へ刻みを丸める
    // (ショートの買い戻しは切り上げ / ロングの売りは切り下げ)。
    final takeProfit = contract.roundPrice(
      evaluation.takeProfitPrice!,
      roundUp: isShort,
    );
    final id = _newExternalOid();
    final position = ManagedPosition(
      id: id,
      symbol: contract.symbol,
      timeframe: evaluation.timeframe,
      direction: direction,
      openedAt: DateTime.now(),
      entryPrice: entryPrice,
      vol: vol,
      contractSize: contract.contractSize,
      leverage: side.leverage,
      emaAtSignal: evaluation.ema ?? 0,
      deviationAtSignal: evaluation.deviation ?? 0,
      takeProfitPrice: takeProfit,
      status: ManagedPositionStatus.open,
    );

    // 建玉が無い状態では positionId ではなく
    // leverage + openType + symbol + positionType をすべて渡す必要がある。
    try {
      await _rest.changeLeverage(
        leverage: side.leverage,
        openType: config.openType,
        symbol: contract.symbol,
        positionType: direction.positionType,
      );
    } on MexcApiException catch (e) {
      // 既に同じ値なら弾かれることがある。発注時にも leverage を渡すので続行。
      onLog?.call('${contract.symbol}: レバレッジ設定をスキップ (${e.description})');
    }

    final result = await _rest.createOrder(
      symbol: contract.symbol,
      price: entryPrice,
      vol: vol,
      side: direction.openSide,
      type: config.orderTypeValue,
      openType: config.openType,
      leverage: side.leverage,
      takeProfitPrice: config.attachTakeProfitToOrder ? takeProfit : null,
      positionMode: config.positionModeValue,
      externalOid: id,
    );

    onLog?.call(
      '${contract.symbol} ${evaluation.timeframe.label} '
      '${direction.label}発注 '
      '${vol.toStringAsFixed(contract.volScale)} 枚 @ $entryPrice '
      '→ 利確 $takeProfit (注文ID ${result.orderId})',
    );

    return position.copyWith(exchangeOrderId: result.orderId);
  }

  /// 成行で決済する。
  Future<ManagedPosition> close({
    required ManagedPosition position,
    required ContractInfo contract,
    required StrategyConfig config,
    required double markPrice,
    String? note,
  }) async {
    final closePrice = contract.roundPrice(
      markPrice,
      roundUp: position.direction.isShort,
    );
    final gross = position.pnlAt(closePrice);
    // API 経由の手数料は Web/App とは別体系 (2026-06 以降 Taker 0.08%)。
    final fee = (position.entryPrice + closePrice) *
        position.vol *
        position.contractSize *
        contract.takerFeeRate;
    final pnl = gross - fee;

    await _rest.closePosition(
      symbol: position.symbol,
      price: closePrice,
      vol: position.vol,
      side: position.direction.closeSide,
      openType: config.openType,
      positionId: position.exchangePositionId,
      // 一方向モードなので、決済は reduceOnly を付けて出す。
      reduceOnly: true,
      positionMode: config.positionModeValue,
    );

    onLog?.call(
      '${position.symbol} ${position.direction.label}決済 @ $closePrice '
      '(損益 ${pnl.toStringAsFixed(4)} USDT)',
    );

    return position.copyWith(
      status: ManagedPositionStatus.closed,
      closedAt: DateTime.now(),
      closePrice: closePrice,
      realizedPnl: pnl,
      note: note,
    );
  }
}
