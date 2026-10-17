import 'package:meta/meta.dart';

/// 取引所が持っている建玉 (`position/open_positions`)。
@immutable
class PositionInfo {
  const PositionInfo({
    required this.positionId,
    required this.symbol,
    required this.positionType,
    required this.openType,
    required this.state,
    required this.holdVol,
    required this.frozenVol,
    required this.closeVol,
    required this.holdAvgPrice,
    required this.openAvgPrice,
    required this.closeAvgPrice,
    required this.liquidatePrice,
    required this.im,
    required this.leverage,
    required this.realised,
    required this.profitRatio,
    required this.createTime,
    required this.updateTime,
  });

  final int positionId;
  final String symbol;

  /// 1 = ロング / 2 = ショート。
  final int positionType;

  /// 1 = 分離 / 2 = クロス。
  final int openType;

  /// 1 = 保有中 / 2 = システム保有 / 3 = 決済済み。
  final int state;

  final double holdVol;
  final double frozenVol;
  final double closeVol;
  final double holdAvgPrice;
  final double openAvgPrice;
  final double closeAvgPrice;
  final double liquidatePrice;
  final double im;
  final int leverage;
  final double realised;
  final double profitRatio;
  final int createTime;
  final int updateTime;

  bool get isShort => positionType == 2;
  bool get isOpen => state == 1 || state == 2;

  /// 現在値から評価損益 (USDT) を求める。
  ///
  /// [contractSize] は銘柄仕様の 1 枚あたり原資産量。
  double unrealizedPnl(double markPrice, double contractSize) {
    final qty = holdVol * contractSize;
    if (isShort) return (holdAvgPrice - markPrice) * qty;
    return (markPrice - holdAvgPrice) * qty;
  }

  factory PositionInfo.fromJson(Map<String, dynamic> json) {
    double d(String k) => (json[k] as num?)?.toDouble() ?? 0;
    int i(String k) => (json[k] as num?)?.toInt() ?? 0;
    return PositionInfo(
      positionId: i('positionId'),
      symbol: json['symbol'] as String? ?? '',
      positionType: i('positionType'),
      openType: i('openType'),
      state: i('state'),
      holdVol: d('holdVol'),
      frozenVol: d('frozenVol'),
      closeVol: d('closeVol'),
      holdAvgPrice: d('holdAvgPrice'),
      openAvgPrice: d('openAvgPrice'),
      closeAvgPrice: d('closeAvgPrice'),
      liquidatePrice: d('liquidatePrice'),
      im: d('im'),
      leverage: i('leverage'),
      realised: d('realised'),
      profitRatio: d('profitRatio'),
      createTime: i('createTime'),
      updateTime: i('updateTime'),
    );
  }

  Map<String, dynamic> toJson() => {
    'positionId': positionId,
    'symbol': symbol,
    'positionType': positionType,
    'openType': openType,
    'state': state,
    'holdVol': holdVol,
    'frozenVol': frozenVol,
    'closeVol': closeVol,
    'holdAvgPrice': holdAvgPrice,
    'openAvgPrice': openAvgPrice,
    'closeAvgPrice': closeAvgPrice,
    'liquidatePrice': liquidatePrice,
    'im': im,
    'leverage': leverage,
    'realised': realised,
    'profitRatio': profitRatio,
    'createTime': createTime,
    'updateTime': updateTime,
  };
}

/// 建玉に付けた利確 / 損切り (`stoporder/list/orders`)。
///
/// ボットの建玉は手元の記録で線を引くが、手で建てた建玉 (アプリから手で
/// 出した注文も) は、利確の位置を取引所に聞かないと分からない。
@immutable
class PositionStopOrder {
  const PositionStopOrder({
    required this.id,
    required this.symbol,
    required this.positionId,
    required this.positionType,
    this.takeProfitPrice,
    this.stopLossPrice,
    this.vol = 0,
    this.updateTime = 0,
  });

  final String id;
  final String symbol;

  /// 結び付いた建玉。注文に付けたまま、まだ建っていなければ 0。
  final int positionId;

  /// 1 = ロング / 2 = ショート。
  final int positionType;
  final double? takeProfitPrice;
  final double? stopLossPrice;
  final double vol;

  /// 最後に変えた時刻 (ミリ秒)。同じ建玉に何本もあれば新しい方を使う。
  final int updateTime;

  /// 取引所の 1 件から作る。発動済み・取消済みのもの (state が 1 以外) は null。
  static PositionStopOrder? fromExchangeJson(Map<String, dynamic> json) {
    final state = (json['state'] as num?)?.toInt() ?? 1;
    if (state != 1) return null;
    double? positive(String k) {
      final v = (json[k] as num?)?.toDouble();
      return v == null || v <= 0 ? null : v;
    }

    final id = '${json['id'] ?? ''}';
    if (id.isEmpty) return null;
    return PositionStopOrder(
      id: id,
      symbol: json['symbol'] as String? ?? '',
      positionId: (json['positionId'] as num?)?.toInt() ?? 0,
      positionType: (json['positionType'] as num?)?.toInt() ?? 0,
      takeProfitPrice: positive('takeProfitPrice'),
      stopLossPrice: positive('stopLossPrice'),
      vol: (json['vol'] as num?)?.toDouble() ?? 0,
      updateTime:
          (json['updateTime'] as num?)?.toInt() ??
          (json['createTime'] as num?)?.toInt() ??
          0,
    );
  }

  factory PositionStopOrder.fromJson(Map<String, dynamic> json) =>
      PositionStopOrder(
        id: '${json['id'] ?? ''}',
        symbol: json['symbol'] as String? ?? '',
        positionId: (json['positionId'] as num?)?.toInt() ?? 0,
        positionType: (json['positionType'] as num?)?.toInt() ?? 0,
        takeProfitPrice: (json['takeProfitPrice'] as num?)?.toDouble(),
        stopLossPrice: (json['stopLossPrice'] as num?)?.toDouble(),
        vol: (json['vol'] as num?)?.toDouble() ?? 0,
        updateTime: (json['updateTime'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'symbol': symbol,
    'positionId': positionId,
    'positionType': positionType,
    if (takeProfitPrice != null) 'takeProfitPrice': takeProfitPrice,
    if (stopLossPrice != null) 'stopLossPrice': stopLossPrice,
    'vol': vol,
    'updateTime': updateTime,
  };
}

/// [position] に効いている利確 / 損切り。
///
/// 建玉 ID が合うものを先に見て、無ければ同じ銘柄・同じ向きで建玉 ID の
/// 付いていないもの (注文に付けて出し、そのまま建ったもの) を見る。一方向
/// モードなので、同じ銘柄・同じ向きの建玉は 1 つしかない。何本もあれば、
/// 利確と損切りそれぞれ新しいものを使う。
({double? takeProfit, double? stopLoss}) exitOfPosition(
  PositionInfo position,
  List<PositionStopOrder> orders,
) {
  var candidates = [
    for (final o in orders)
      if (o.positionId == position.positionId) o,
  ];
  if (candidates.isEmpty) {
    candidates = [
      for (final o in orders)
        if (o.positionId == 0 &&
            o.symbol == position.symbol &&
            o.positionType == position.positionType)
          o,
    ];
  }
  candidates.sort((a, b) => b.updateTime.compareTo(a.updateTime));
  double? tp;
  double? sl;
  for (final o in candidates) {
    tp ??= o.takeProfitPrice;
    sl ??= o.stopLossPrice;
  }
  return (takeProfit: tp, stopLoss: sl);
}

/// 先物口座の残高 (`account/assets`)。
@immutable
class AccountAsset {
  const AccountAsset({
    required this.currency,
    required this.availableBalance,
    required this.equity,
    required this.positionMargin,
    required this.frozenBalance,
    required this.unrealized,
    required this.cashBalance,
  });

  final String currency;
  final double availableBalance;
  final double equity;
  final double positionMargin;
  final double frozenBalance;
  final double unrealized;
  final double cashBalance;

  factory AccountAsset.fromJson(Map<String, dynamic> json) {
    double d(String k) => (json[k] as num?)?.toDouble() ?? 0;
    return AccountAsset(
      currency: json['currency'] as String? ?? '',
      availableBalance: d('availableBalance'),
      equity: d('equity'),
      positionMargin: d('positionMargin'),
      frozenBalance: d('frozenBalance'),
      unrealized: d('unrealized'),
      cashBalance: d('cashBalance'),
    );
  }

  Map<String, dynamic> toJson() => {
    'currency': currency,
    'availableBalance': availableBalance,
    'equity': equity,
    'positionMargin': positionMargin,
    'frozenBalance': frozenBalance,
    'unrealized': unrealized,
    'cashBalance': cashBalance,
  };
}
