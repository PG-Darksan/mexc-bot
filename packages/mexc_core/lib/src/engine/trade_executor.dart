import 'dart:math' as math;

import '../api/mexc_exception.dart';
import '../api/mexc_rest_client.dart';
import '../models/contract_info.dart';
import '../models/signal.dart';
import '../models/strategy_config.dart';

/// 買い足し / 売り足しの指値をどこに何枚置くかの計算結果。
///
/// 通信を伴わない純粋な計算なので、発注とは切り離してテストできる。
class AddOnPlan {
  const AddOnPlan({required this.price, required this.vol, required this.marginUsdt});

  /// 指値の価格 (取引所の刻みに丸めたあと)。
  final double price;

  /// 枚数。
  final double vol;

  /// この注文に充てる証拠金 (USDT)。
  final double marginUsdt;

  /// 建値と残り資金から計画を立てる。数量が最小に届かなければ null。
  ///
  /// ロングは建値より下に買い指値 (刻みは切り下げ)、ショートは建値より上に
  /// 売り指値 (切り上げ)。どちらも「約定したら平均建値が有利になる側」。
  static AddOnPlan? compute({
    required SideConfig side,
    required ContractInfo contract,
    required double entryPrice,
    required double availableUsdt,
    double heldVol = 0,
  }) {
    if (!side.addOnEnabled || availableUsdt <= 0) return null;
    final raw = side.addOnPriceFor(entryPrice);
    if (raw <= 0) return null;
    final price = contract.roundPrice(raw, roundUp: side.direction.isShort);
    if (price <= 0) return null;
    final margin = availableUsdt * side.addOnBudgetPercent / 100;
    final vol = contract.volumeForMargin(
      marginUsdt: margin,
      leverage: side.leverage.toDouble(),
      price: price,
    );
    if (vol == null) return null;
    // 今の建玉と合わせて、持てる建玉の上限を超えない分だけにする。
    final room = contract.roundVolume(contract.maxPositionVol - heldVol);
    final capped = vol > room ? room : vol;
    if (capped < contract.minVol) return null;
    return AddOnPlan(price: price, vol: capped, marginUsdt: margin);
  }
}

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
    double? availableUsdt,
  }) async {
    final direction = evaluation.direction;
    final side = config.sideOf(direction);
    final isShort = direction.isShort;
    final markPrice = evaluation.price;

    // 成行で出す。約定しやすい側へ刻みを丸める。
    final entryPrice = contract.roundPrice(markPrice, roundUp: !isShort);

    // 設定の証拠金が残高を超えていれば、残高で建てられる分にする
    // (手数料の分だけ余らせる)。
    var margin = side.marginPerTradeUsdt;
    if (availableUsdt != null && availableUsdt > 0) {
      final usable = availableUsdt * 0.99;
      if (usable < margin) {
        onLog?.call(
          '${contract.symbol}: 証拠金を残高に合わせて '
          '${usable.toStringAsFixed(2)} USDT に減らします',
        );
        margin = usable;
      }
    }
    final vol = contract.volumeForMargin(
      marginUsdt: margin,
      leverage: side.leverage.toDouble(),
      price: entryPrice,
    );
    if (vol == null) {
      throw StateError(
        '${contract.symbol}: 証拠金 ${margin.toStringAsFixed(2)} USDT では'
        '最小数量 (${contract.minVol} 枚) に届きません。',
      );
    }
    final wanted = margin * side.leverage / (entryPrice * contract.contractSize);
    if (vol < contract.roundVolume(wanted)) {
      onLog?.call(
        '${contract.symbol}: 持てる上限に合わせて ${vol.toStringAsFixed(contract.volScale)} 枚で建てます',
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
      // 利確は必ず発注と同時に取引所へ預ける。落ちていても決済される。
      takeProfitPrice: takeProfit,
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

  /// 成行で建てたあと、逆行した所に同じ向きの指値 (買い足し / 売り足し) を置く。
  ///
  /// 口座に残っている USDT のうち設定の割合を証拠金にする。指値が約定すると
  /// 平均建値が有利な側へ寄る。利確の目標は変えない (取引所に預けた利確は
  /// 約定後に枚数を合わせて置き直す)。
  Future<ManagedPosition> placeAddOn({
    required ManagedPosition position,
    required ContractInfo contract,
    required StrategyConfig config,
    required double availableUsdt,
  }) async {
    final side = config.sideOf(position.direction);
    final plan = AddOnPlan.compute(
      side: side,
      contract: contract,
      entryPrice: position.entryPrice,
      availableUsdt: availableUsdt,
      heldVol: position.vol,
    );
    if (plan == null) {
      throw StateError(
        '${contract.symbol}: 残り ${availableUsdt.toStringAsFixed(2)} USDT の '
        '${side.addOnBudgetPercent}% では最小数量 (${contract.minVol} 枚) に届きません。',
      );
    }

    final result = await _rest.createOrder(
      symbol: contract.symbol,
      price: plan.price,
      vol: plan.vol,
      side: position.direction.openSide,
      // 指値 (type=1)。価格に届くまで板に残り、証拠金はその間凍結される。
      type: 1,
      openType: config.openType,
      leverage: side.leverage,
      positionMode: config.positionModeValue,
      externalOid: _newExternalOid(),
    );

    onLog?.call(
      '${contract.symbol} ${position.direction.label}の'
      '${position.direction.isShort ? "売り足し" : "買い足し"}指値 '
      '${plan.vol.toStringAsFixed(contract.volScale)} 枚 @ ${plan.price} '
      '(含み損 ${side.addOnLossPercent}% の所 / 証拠金 '
      '${plan.marginUsdt.toStringAsFixed(2)} USDT / 注文ID ${result.orderId})',
    );

    return position.copyWith(
      addOnOrderId: result.orderId,
      addOnPrice: plan.price,
      addOnVol: plan.vol,
      addOnFilled: false,
    );
  }

  /// 残っている買い足しの指値を取り消す。無ければ何もしない。
  Future<void> cancelAddOn(ManagedPosition position) async {
    final id = position.addOnOrderId;
    if (id == null || position.addOnFilled) return;
    await _rest.cancelOrders([id]);
    onLog?.call('${position.symbol}: 買い足しの指値 (注文ID $id) を取り消しました');
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
