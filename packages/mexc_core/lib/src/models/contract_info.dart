import 'package:meta/meta.dart';

/// `GET /api/v1/contract/detail` が返す銘柄仕様のうち、発注に必要な分。
@immutable
class ContractInfo {
  const ContractInfo({
    required this.symbol,
    required this.baseCoin,
    required this.quoteCoin,
    required this.settleCoin,
    required this.contractSize,
    required this.minVol,
    required this.maxVol,
    required this.volUnit,
    required this.volScale,
    required this.priceUnit,
    required this.priceScale,
    required this.minLeverage,
    required this.maxLeverage,
    required this.positionOpenType,
    required this.apiAllowed,
    required this.state,
    required this.takerFeeRate,
    required this.makerFeeRate,
    required this.futureType,
    this.riskBaseVol = 0,
    this.riskIncrVol = 0,
    this.riskLevelLimit = 1,
  });

  final String symbol;
  final String baseCoin;
  final String quoteCoin;
  final String settleCoin;

  /// 1 枚あたりの原資産量。実数量 = vol × contractSize。
  final double contractSize;

  final double minVol;
  final double maxVol;

  /// 建玉の上限 (段階ごと)。最初の段階の枚数と、段階ごとに増える枚数、段階の数。
  final double riskBaseVol;
  final double riskIncrVol;
  final int riskLevelLimit;

  /// この銘柄で持てる建玉の最大枚数。分からなければ 1 回の注文の上限。
  double get maxPositionVol {
    if (riskBaseVol <= 0) return maxVol;
    final levels = riskLevelLimit < 1 ? 0 : riskLevelLimit - 1;
    return riskBaseVol + riskIncrVol * levels;
  }

  /// 注文数量の刻み (枚)。
  final double volUnit;
  final int volScale;

  /// 価格の刻み。
  final double priceUnit;
  final int priceScale;

  final int minLeverage;
  final int maxLeverage;

  /// 1=分離のみ / 2=クロスのみ / 3=両方。
  final int positionOpenType;

  /// API 経由の売買が許可されているか。false の銘柄は発注できない。
  final bool apiAllowed;

  /// 0 が取引可能。
  final int state;

  final double takerFeeRate;
  final double makerFeeRate;

  /// 1 = 無期限。
  final int futureType;

  bool get isTradable => apiAllowed && state == 0;

  bool get isPerpetualUsdt => futureType == 1 && quoteCoin == 'USDT';

  /// 分離マージン (openType=1) が使えるか。
  bool get supportsIsolated => positionOpenType == 1 || positionOpenType == 3;

  /// 価格を取引所の刻みに丸める。
  ///
  /// [roundUp] が true なら切り上げ。ショートの利確指値は切り上げた方が
  /// 約定しやすい (= より高い価格で買い戻す) ため既定で切り上げる。
  double roundPrice(double price, {bool roundUp = true}) {
    if (priceUnit <= 0) return price;
    final units = _snap(price / priceUnit);
    final rounded = roundUp ? units.ceil() : units.floor();
    final value = rounded * priceUnit;
    return double.parse(value.toStringAsFixed(priceScale.clamp(0, 12)));
  }

  /// 注文数量 (枚) を刻みに合わせて切り下げる。
  double roundVolume(double vol) {
    if (volUnit <= 0) return vol;
    final units = _snap(vol / volUnit).floor();
    final value = units * volUnit;
    return double.parse(value.toStringAsFixed(volScale.clamp(0, 12)));
  }

  /// 割り算の誤差で刻みのすぐ手前になった値を、刻みちょうどに戻す。
  ///
  /// 2.8 / 0.001 は 2799.9999999999995 になるので、そのまま切り下げると
  /// 1 刻み (2.799) ずれる。
  static double _snap(double units) {
    final nearest = units.roundToDouble();
    final tolerance = 1e-9 * (nearest.abs() < 1 ? 1 : nearest.abs());
    return (units - nearest).abs() <= tolerance ? nearest : units;
  }

  /// 証拠金額 (USDT) とレバレッジから発注枚数を求める。
  ///
  /// 取引所の最小数量に満たない場合は null。
  double? volumeForMargin({
    required double marginUsdt,
    required double leverage,
    required double price,
  }) {
    if (price <= 0 || contractSize <= 0) return null;
    final notional = marginUsdt * leverage;
    final raw = notional / (price * contractSize);
    final vol = roundVolume(raw);
    if (vol < minVol) return null;
    // 1 回の注文の上限と、持てる建玉の上限を超えた分は削る。
    final cap = roundVolume(maxPositionVol < maxVol ? maxPositionVol : maxVol);
    if (vol > cap) return cap;
    return vol;
  }

  factory ContractInfo.fromJson(Map<String, dynamic> json) {
    double d(String key, [double fallback = 0]) =>
        (json[key] as num?)?.toDouble() ?? fallback;
    int i(String key, [int fallback = 0]) =>
        (json[key] as num?)?.toInt() ?? fallback;

    return ContractInfo(
      symbol: json['symbol'] as String,
      baseCoin: json['baseCoin'] as String? ?? '',
      quoteCoin: json['quoteCoin'] as String? ?? '',
      settleCoin: json['settleCoin'] as String? ?? '',
      contractSize: d('contractSize'),
      minVol: d('minVol', 1),
      maxVol: d('maxVol', double.maxFinite),
      volUnit: d('volUnit', 1),
      volScale: i('volScale'),
      priceUnit: d('priceUnit'),
      priceScale: i('priceScale'),
      minLeverage: i('minLeverage', 1),
      maxLeverage: i('maxLeverage', 1),
      positionOpenType: i('positionOpenType', 3),
      apiAllowed: json['apiAllowed'] as bool? ?? true,
      state: i('state'),
      takerFeeRate: d('takerFeeRate'),
      makerFeeRate: d('makerFeeRate'),
      futureType: i('futureType', 1),
      riskBaseVol: d('riskBaseVol'),
      riskIncrVol: d('riskIncrVol'),
      riskLevelLimit: i('riskLevelLimit', 1),
    );
  }
}
