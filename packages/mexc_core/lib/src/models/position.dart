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
