import 'package:meta/meta.dart';

import 'strategy_config.dart';
import 'timeframe.dart';

/// シグナルを見送った理由。画面に出して「なぜ入らないか」を追えるようにする。
enum RejectReason {
  insufficientData('履歴が足りない'),
  notTradable('API発注不可の銘柄'),
  lowVolume('24h出来高が不足'),
  rsiNotReached('RSIがしきい値に届かない'),
  insideBand('バンド内'),
  fundingRateTooHigh('資金調達率の負担が大きい'),
  fundingIntervalTooShort('資金調達の間隔が短い'),
  fundingUnknown('資金調達率が未取得'),
  alreadyHolding('同じ銘柄を保有中'),
  cooldown('クールダウン中'),
  maxPositions('同時保有数の上限'),
  profitTooSmall('利確幅が小さすぎる'),
  volumeTooSmall('発注数量が最小未満'),
  insufficientBalance('残高不足');

  const RejectReason(this.label);

  final String label;
}

/// 1 銘柄 1 時間軸 1 方向ぶんの評価結果。
@immutable
class SignalEvaluation {
  const SignalEvaluation({
    required this.symbol,
    required this.timeframe,
    required this.direction,
    required this.price,
    required this.amount24,
    required this.rsi,
    required this.bbUpper,
    required this.bbLower,
    required this.bbMiddle,
    required this.ema,
    required this.deviation,
    required this.bandDeviation,
    this.byBandBreakout = false,
    required this.takeProfitPrice,
    required this.expectedProfitPercent,
    required this.fundingRate,
    required this.fundingIntervalHours,
    required this.barOpenTime,
    this.rejectReason,
  });

  final String symbol;
  final Timeframe timeframe;

  /// この評価がどちら向きの建玉を狙ったものか。
  final TradeDirection direction;

  /// 判定時点の価格 (進行中の足の終値)。
  final double price;

  final double amount24;
  final double? rsi;
  final double? bbUpper;
  final double? bbLower;
  final double? bbMiddle;
  final double? ema;

  /// 価格の EMA からの乖離率 (0.05 = +5%)。ロングでは負になる。
  final double? deviation;

  /// 判定に使うσのバンドからの乖離率 (0.2 = バンドの 20% 外側)。
  ///
  /// バンドの外側なら正、内側なら負。方向によらず「外側が正」で揃える。
  final double? bandDeviation;

  /// RSI を見ずに、バンドからの大きな乖離だけで発火したか。
  final bool byBandBreakout;

  final double? takeProfitPrice;

  /// エントリー価格に対する利確幅 (%)。方向に関わらず正の値。
  final double? expectedProfitPercent;

  final double? fundingRate;
  final int? fundingIntervalHours;

  /// 判定に使った進行中の足の開始時刻。同じ足での二重発火を防ぐのに使う。
  final int barOpenTime;

  /// null ならエントリー条件を満たしている。
  final RejectReason? rejectReason;

  bool get isTriggered => rejectReason == null;

  /// 判定に使うバンドの側 (ショートは +σ、ロングは -σ)。
  double? get bbBoundary => direction.isShort ? bbUpper : bbLower;

  /// 却下理由だけ差し替えた複製。
  SignalEvaluation rejected(RejectReason reason) => SignalEvaluation(
    symbol: symbol,
    timeframe: timeframe,
    direction: direction,
    price: price,
    amount24: amount24,
    rsi: rsi,
    bbUpper: bbUpper,
    bbLower: bbLower,
    bbMiddle: bbMiddle,
    ema: ema,
    deviation: deviation,
    bandDeviation: bandDeviation,
    byBandBreakout: byBandBreakout,
    takeProfitPrice: takeProfitPrice,
    expectedProfitPercent: expectedProfitPercent,
    fundingRate: fundingRate,
    fundingIntervalHours: fundingIntervalHours,
    barOpenTime: barOpenTime,
    rejectReason: reason,
  );

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'timeframe': timeframe.name,
    'direction': direction.name,
    'price': price,
    'amount24': amount24,
    'rsi': rsi,
    'bbUpper': bbUpper,
    'bbLower': bbLower,
    'bbMiddle': bbMiddle,
    'ema': ema,
    'deviation': deviation,
    'bandDeviation': bandDeviation,
    'byBandBreakout': byBandBreakout,
    'takeProfitPrice': takeProfitPrice,
    'expectedProfitPercent': expectedProfitPercent,
    'fundingRate': fundingRate,
    'fundingIntervalHours': fundingIntervalHours,
    'barOpenTime': barOpenTime,
    'rejectReason': rejectReason?.name,
  };

  factory SignalEvaluation.fromJson(Map<String, dynamic> json) =>
      SignalEvaluation(
        symbol: json['symbol'] as String,
        timeframe:
            Timeframe.fromName(json['timeframe'] as String? ?? '') ??
            Timeframe.m15,
        direction: TradeDirection.fromName(json['direction'] as String?),
        price: (json['price'] as num?)?.toDouble() ?? 0,
        amount24: (json['amount24'] as num?)?.toDouble() ?? 0,
        rsi: (json['rsi'] as num?)?.toDouble(),
        bbUpper: (json['bbUpper'] as num?)?.toDouble(),
        bbLower: (json['bbLower'] as num?)?.toDouble(),
        bbMiddle: (json['bbMiddle'] as num?)?.toDouble(),
        ema: (json['ema'] as num?)?.toDouble(),
        deviation: (json['deviation'] as num?)?.toDouble(),
        bandDeviation: (json['bandDeviation'] as num?)?.toDouble(),
        byBandBreakout: json['byBandBreakout'] as bool? ?? false,
        takeProfitPrice: (json['takeProfitPrice'] as num?)?.toDouble(),
        expectedProfitPercent:
            (json['expectedProfitPercent'] as num?)?.toDouble(),
        fundingRate: (json['fundingRate'] as num?)?.toDouble(),
        fundingIntervalHours: (json['fundingIntervalHours'] as num?)?.toInt(),
        barOpenTime: (json['barOpenTime'] as num?)?.toInt() ?? 0,
        rejectReason: RejectReason.values
            .where((e) => e.name == json['rejectReason'])
            .firstOrNull,
      );
}

/// bot が建てたポジションの状態。
enum ManagedPositionStatus { pending, open, closed, failed }

/// bot が管理する 1 ポジション。取引所の建玉と紐づく。
@immutable
class ManagedPosition {
  const ManagedPosition({
    required this.id,
    required this.symbol,
    required this.timeframe,
    required this.direction,
    required this.openedAt,
    required this.entryPrice,
    required this.vol,
    required this.contractSize,
    required this.leverage,
    required this.emaAtSignal,
    required this.deviationAtSignal,
    required this.takeProfitPrice,
    required this.status,
    this.stopLossPrice,
    this.exchangeOrderId,
    this.exchangePositionId,
    this.closedAt,
    this.closePrice,
    this.realizedPnl,
    this.note,
  });

  /// externalOid と同じ値。取引所側と突き合わせるのに使う。
  final String id;

  final String symbol;
  final Timeframe timeframe;
  final TradeDirection direction;
  final DateTime openedAt;
  final double entryPrice;
  final double vol;
  final double contractSize;
  final int leverage;

  /// 検知した瞬間の EMA 値。利確目標はこれを基準に固定する。
  final double emaAtSignal;

  /// 検知時の乖離率。
  final double deviationAtSignal;

  final double takeProfitPrice;
  final double? stopLossPrice;
  final ManagedPositionStatus status;
  final String? exchangeOrderId;
  final int? exchangePositionId;
  final DateTime? closedAt;
  final double? closePrice;
  final double? realizedPnl;
  final String? note;

  /// 建玉の名目価値 (USDT)。
  double get notional => entryPrice * vol * contractSize;

  /// 現在値での評価損益。
  double unrealizedPnl(double markPrice) => pnlAt(markPrice);

  /// 指定した決済価格での損益 (手数料を含めない)。
  double pnlAt(double closePrice) {
    final diff = direction.isShort
        ? entryPrice - closePrice
        : closePrice - entryPrice;
    return diff * vol * contractSize;
  }

  ManagedPosition copyWith({
    ManagedPositionStatus? status,
    String? exchangeOrderId,
    int? exchangePositionId,
    DateTime? closedAt,
    double? closePrice,
    double? realizedPnl,
    String? note,
  }) => ManagedPosition(
    id: id,
    symbol: symbol,
    timeframe: timeframe,
    direction: direction,
    openedAt: openedAt,
    entryPrice: entryPrice,
    vol: vol,
    contractSize: contractSize,
    leverage: leverage,
    emaAtSignal: emaAtSignal,
    deviationAtSignal: deviationAtSignal,
    takeProfitPrice: takeProfitPrice,
    stopLossPrice: stopLossPrice,
    status: status ?? this.status,
    exchangeOrderId: exchangeOrderId ?? this.exchangeOrderId,
    exchangePositionId: exchangePositionId ?? this.exchangePositionId,
    closedAt: closedAt ?? this.closedAt,
    closePrice: closePrice ?? this.closePrice,
    realizedPnl: realizedPnl ?? this.realizedPnl,
    note: note ?? this.note,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'symbol': symbol,
    'timeframe': timeframe.name,
    'direction': direction.name,
    'openedAt': openedAt.toIso8601String(),
    'entryPrice': entryPrice,
    'vol': vol,
    'contractSize': contractSize,
    'leverage': leverage,
    'emaAtSignal': emaAtSignal,
    'deviationAtSignal': deviationAtSignal,
    'takeProfitPrice': takeProfitPrice,
    'stopLossPrice': stopLossPrice,
    'status': status.name,
    'exchangeOrderId': exchangeOrderId,
    'exchangePositionId': exchangePositionId,
    'closedAt': closedAt?.toIso8601String(),
    'closePrice': closePrice,
    'realizedPnl': realizedPnl,
    'note': note,
  };

  factory ManagedPosition.fromJson(Map<String, dynamic> json) =>
      ManagedPosition(
        id: json['id'] as String,
        symbol: json['symbol'] as String,
        timeframe:
            Timeframe.fromName(json['timeframe'] as String? ?? '') ??
            Timeframe.m15,
        direction: TradeDirection.fromName(json['direction'] as String?),
        openedAt: DateTime.parse(json['openedAt'] as String),
        entryPrice: (json['entryPrice'] as num).toDouble(),
        vol: (json['vol'] as num).toDouble(),
        contractSize: (json['contractSize'] as num?)?.toDouble() ?? 1,
        leverage: (json['leverage'] as num?)?.toInt() ?? 1,
        emaAtSignal: (json['emaAtSignal'] as num?)?.toDouble() ?? 0,
        deviationAtSignal:
            (json['deviationAtSignal'] as num?)?.toDouble() ?? 0,
        takeProfitPrice: (json['takeProfitPrice'] as num?)?.toDouble() ?? 0,
        stopLossPrice: (json['stopLossPrice'] as num?)?.toDouble(),
        status: ManagedPositionStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => ManagedPositionStatus.open,
        ),
        exchangeOrderId: json['exchangeOrderId'] as String?,
        exchangePositionId: (json['exchangePositionId'] as num?)?.toInt(),
        closedAt: json['closedAt'] == null
            ? null
            : DateTime.tryParse(json['closedAt'] as String),
        closePrice: (json['closePrice'] as num?)?.toDouble(),
        realizedPnl: (json['realizedPnl'] as num?)?.toDouble(),
        note: json['note'] as String?,
      );
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
