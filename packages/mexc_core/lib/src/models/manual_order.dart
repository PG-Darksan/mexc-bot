import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'contract_info.dart';
import 'strategy_config.dart';

/// アプリから手で出す注文の種類。
enum ManualOrderKind {
  /// いまの値段ですぐ建てる。
  market('成行'),

  /// 決めた値段に届いたら建てる (板に置く)。
  limit('指値'),

  /// 決めた値段 (発動価格) に届いたら、成行か指値で出す。
  /// 取引所の「トリガー注文」(planorder)。
  trigger('条件付き');

  const ManualOrderKind(this.label);

  final String label;

  static ManualOrderKind fromName(String? name) => ManualOrderKind.values
      .firstWhere((e) => e.name == name, orElse: () => ManualOrderKind.market);
}

/// 条件付き注文が発動したときの出し方。
enum TriggerExecution {
  market('成行'),
  limit('指値');

  const TriggerExecution(this.label);

  final String label;

  /// 取引所の orderType。1 = 指値 / 5 = 成行。
  int get orderType => this == TriggerExecution.limit ? 1 : 5;

  static TriggerExecution fromName(String? name) => TriggerExecution.values
      .firstWhere((e) => e.name == name, orElse: () => TriggerExecution.market);
}

/// アプリから手で出す新規注文。
///
/// 数量は証拠金 (USDT) とレバレッジで決める。枚数への直しと取引所の刻みへの
/// 丸めはサーバー (銘柄仕様を持っている側) でする。
@immutable
class ManualOrderRequest {
  const ManualOrderRequest({
    required this.symbol,
    required this.direction,
    required this.kind,
    required this.marginUsdt,
    required this.leverage,
    this.price,
    this.triggerPrice,
    this.triggerExecution = TriggerExecution.market,
    this.takeProfitPrice,
    this.stopLossPrice,
  });

  final String symbol;
  final TradeDirection direction;
  final ManualOrderKind kind;

  /// 証拠金 (USDT)。建玉の大きさは marginUsdt × leverage。
  final double marginUsdt;
  final int leverage;

  /// 指値の値段。指値と、条件付きを指値で出すときに使う。
  final double? price;

  /// 条件付き注文の発動価格。
  final double? triggerPrice;
  final TriggerExecution triggerExecution;

  /// 利確 / 損切り。成行と指値は発注と同時に取引所へ預ける。条件付きは、
  /// 発動して建玉ができたあとにサーバーが置く (取引所の条件付き注文には
  /// 利確 / 損切りを付けられないため)。
  final double? takeProfitPrice;
  final double? stopLossPrice;

  /// 数量を決める値段。成行は [lastPrice] (いまの値段)。
  double? referencePrice(double? lastPrice) => switch (kind) {
    ManualOrderKind.market => lastPrice,
    ManualOrderKind.limit => price,
    ManualOrderKind.trigger =>
      triggerExecution == TriggerExecution.limit
          ? (price ?? triggerPrice)
          : triggerPrice,
  };

  /// 条件付き注文の向き。発動価格がいまより上なら「以上で発動」(1)、
  /// 下なら「以下で発動」(2)。
  static int triggerTypeFor(double triggerPrice, double lastPrice) =>
      triggerPrice >= lastPrice ? 1 : 2;

  /// 中身のまちがい。空なら出してよい。
  ///
  /// [lastPrice] はいまの値段。分からなければ、値段どうしの前後は確かめない。
  List<String> validate({double? lastPrice}) {
    final errors = <String>[];
    if (symbol.trim().isEmpty) errors.add('銘柄が空です');
    if (!(marginUsdt > 0)) errors.add('証拠金 (USDT) を入れて下さい');
    if (leverage < 1 || leverage > 200) {
      errors.add('レバレッジは 1〜200 倍で入れて下さい');
    }
    switch (kind) {
      case ManualOrderKind.market:
        break;
      case ManualOrderKind.limit:
        if (!((price ?? 0) > 0)) errors.add('指値の値段を入れて下さい');
      case ManualOrderKind.trigger:
        if (!((triggerPrice ?? 0) > 0)) errors.add('発動価格を入れて下さい');
        if (triggerExecution == TriggerExecution.limit &&
            !((price ?? 0) > 0)) {
          errors.add('発動したときの指値の値段を入れて下さい');
        }
    }
    for (final (value, name) in [
      (takeProfitPrice, '利確'),
      (stopLossPrice, '損切り'),
    ]) {
      if (value != null && !(value > 0)) errors.add('$nameの値段がおかしいです');
    }
    final entry = referencePrice(lastPrice);
    if (entry != null && entry > 0) {
      final tp = takeProfitPrice;
      final sl = stopLossPrice;
      if (direction.isLong) {
        if (tp != null && tp <= entry) {
          errors.add('ロングの利確は入値 ($entry) より上にして下さい');
        }
        if (sl != null && sl >= entry) {
          errors.add('ロングの損切りは入値 ($entry) より下にして下さい');
        }
      } else {
        if (tp != null && tp >= entry) {
          errors.add('ショートの利確は入値 ($entry) より下にして下さい');
        }
        if (sl != null && sl <= entry) {
          errors.add('ショートの損切りは入値 ($entry) より上にして下さい');
        }
      }
    }
    return errors;
  }

  /// 画面と記録に出す 1 行の説明。
  String describe() {
    final side = direction.isLong ? '買い (ロング)' : '売り (ショート)';
    final how = switch (kind) {
      ManualOrderKind.market => '成行',
      ManualOrderKind.limit => '指値 $price',
      ManualOrderKind.trigger =>
        '条件付き (発動 $triggerPrice → ${triggerExecution == TriggerExecution.limit ? '指値 $price' : '成行'})',
    };
    return '$symbol $side $how / 証拠金 ${marginUsdt.toStringAsFixed(2)} USDT × '
        '$leverage 倍'
        '${takeProfitPrice == null ? '' : ' / 利確 $takeProfitPrice'}'
        '${stopLossPrice == null ? '' : ' / 損切り $stopLossPrice'}';
  }

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'direction': direction.name,
    'kind': kind.name,
    'marginUsdt': marginUsdt,
    'leverage': leverage,
    if (price != null) 'price': price,
    if (triggerPrice != null) 'triggerPrice': triggerPrice,
    'triggerExecution': triggerExecution.name,
    if (takeProfitPrice != null) 'takeProfitPrice': takeProfitPrice,
    if (stopLossPrice != null) 'stopLossPrice': stopLossPrice,
  };

  factory ManualOrderRequest.fromJson(Map<String, dynamic> json) {
    double? d(String k) => (json[k] as num?)?.toDouble();
    return ManualOrderRequest(
      symbol: json['symbol'] as String? ?? '',
      direction: TradeDirection.fromName(json['direction'] as String?),
      kind: ManualOrderKind.fromName(json['kind'] as String?),
      marginUsdt: d('marginUsdt') ?? 0,
      leverage: (json['leverage'] as num?)?.toInt() ?? 1,
      price: d('price'),
      triggerPrice: d('triggerPrice'),
      triggerExecution: TriggerExecution.fromName(
        json['triggerExecution'] as String?,
      ),
      takeProfitPrice: d('takeProfitPrice'),
      stopLossPrice: d('stopLossPrice'),
    );
  }
}

/// 手で建てる時の「何 %」を、何に対する割合にするか。
///
/// ふつうは使える残高に対する %。ただし、この銘柄で持てる建玉の上限を
/// 証拠金に直した額が使える残高より小さい時は、上限に対する % にする。
/// 残高を基準にすると、たとえば残高 800 USDT の 25% = 200 USDT で、上限が
/// 200 USDT の銘柄では上限いっぱいで建ってしまい、後からナンピンする余地が
/// 残らないため。
///
/// どちらを基準にしても、決めた額は使える残高・この銘柄の残り (上限から、
/// 持っている建玉と出ている注文の分を引いたもの)・1 回の注文の上限を超えない。
@immutable
class OrderSizeBasis {
  const OrderSizeBasis({
    required this.available,
    this.symbolLimit,
    this.symbolRoom,
    this.orderLimit,
  });

  /// 値段・レバレッジ・持っている分から作る。
  ///
  /// [heldVol] は、この銘柄の同じ向きの建玉と、出ている (建てる側の) 注文の
  /// 枚数の合計。
  factory OrderSizeBasis.of({
    required double? available,
    required ContractInfo? contract,
    required double? price,
    required int leverage,
    double heldVol = 0,
  }) {
    if (contract == null ||
        price == null ||
        !(price > 0) ||
        !(contract.contractSize > 0) ||
        leverage < 1) {
      return OrderSizeBasis(available: available);
    }
    // 1 枚あたりの証拠金。
    final perVol = contract.contractSize * price / leverage;
    double? usdt(double vol) =>
        vol.isFinite && vol > 0 && vol < _unknownVol ? vol * perVol : null;
    final maxPosition = contract.maxPositionVol;
    final limit = usdt(maxPosition);
    return OrderSizeBasis(
      available: available,
      symbolLimit: limit,
      symbolRoom: limit == null
          ? null
          : math.max(0.0, maxPosition - heldVol) * perVol,
      orderLimit: usdt(contract.maxVol),
    );
  }

  /// これ以上の枚数は「上限が分からない」とみなす (取引所が上限を返さない
  /// 時は double.maxFinite が入る)。
  static const double _unknownVol = 1e15;

  /// 使える残高 (USDT)。分からなければ null。
  final double? available;

  /// この銘柄で持てる建玉の上限を、証拠金に直した額 (USDT)。分からなければ null。
  final double? symbolLimit;

  /// 上限から、持っている建玉と出ている注文の分を引いた残り (証拠金の USDT)。
  final double? symbolRoom;

  /// 1 回の注文の上限を、証拠金に直した額 (USDT)。
  final double? orderLimit;

  /// この銘柄の上限を基準にしているか (上限が使える残高より小さい)。
  bool get basedOnSymbolLimit {
    final a = available;
    final l = symbolLimit;
    return a != null && l != null && l < a;
  }

  /// % の基準 (USDT)。使える残高が分からなければ null (割合では決められない)。
  double? get base {
    final a = available;
    if (a == null || !(a > 0)) return null;
    return basedOnSymbolLimit ? symbolLimit : a;
  }

  /// これより多くは建てられない額 (USDT)。分からなければ null。
  double? get cap {
    double? m;
    for (final v in [available, symbolRoom, orderLimit]) {
      if (v == null) continue;
      m = m == null ? v : math.min(m, v);
    }
    return m;
  }

  /// [percent] % の証拠金 (USDT)。[cap] を超えない。
  double? marginFor(double percent) {
    final b = base;
    if (b == null) return null;
    final m = b * percent.clamp(0, 100) / 100;
    final c = cap;
    return c == null ? m : math.min(m, c);
  }

  /// [margin] が基準の何 % か (0〜100)。
  double percentOf(double margin) {
    final b = base;
    if (b == null || !(b > 0)) return 0;
    return (margin / b * 100).clamp(0, 100).toDouble();
  }
}

/// 取引所に出ている (まだ約定していない) 注文の種類。
enum ExchangeOrderKind {
  /// 板に置いた指値。
  limit,

  /// 条件付き注文 (トリガー注文)。
  trigger,
}

/// 取引所に出ている注文 1 件。チャートに線を引くのと、取り消しに使う。
@immutable
class ExchangeOrder {
  const ExchangeOrder({
    required this.id,
    required this.symbol,
    required this.kind,
    required this.side,
    required this.vol,
    this.price,
    this.triggerPrice,
    this.triggerType,
    this.executeOrderType,
    this.leverage,
    this.takeProfitPrice,
    this.stopLossPrice,
    this.externalOid,
    this.createTime = 0,
  });

  /// 注文 ID。19 桁になることがあるので文字列で持つ。
  final String id;
  final String symbol;
  final ExchangeOrderKind kind;

  /// MEXC の side。1 = 買い新規 / 2 = 売り決済 (ショートを閉じる買い) /
  /// 3 = 売り新規 / 4 = 買い決済 (ロングを閉じる売り)。
  final int side;
  final double vol;

  /// 指値の値段 (条件付きを成行で出すときは null か 0)。
  final double? price;

  /// 条件付き注文の発動価格。
  final double? triggerPrice;

  /// 1 = 発動価格以上で発動 / 2 = 以下で発動。
  final int? triggerType;

  /// 条件付き注文が発動したときの出し方 (1 = 指値 / 5 = 成行)。
  final int? executeOrderType;
  final int? leverage;
  final double? takeProfitPrice;
  final double? stopLossPrice;

  /// 発注した側が付けた ID。ボットは `bot`、アプリの手動注文は `man` で始まる。
  final String? externalOid;

  /// 出した時刻 (ミリ秒)。
  final int createTime;

  /// 新規建ての注文か (決済の注文なら false)。
  bool get opens => side == 1 || side == 3;

  /// どちら向きの建玉に関わる注文か。
  TradeDirection get direction =>
      side == 1 || side == 4 ? TradeDirection.long : TradeDirection.short;

  /// 買いの注文か (ロングを建てる / ショートを閉じる)。
  bool get isBuy => side == 1 || side == 2;

  /// ボットの買い足し / 売り足しの指値か。
  bool get fromBot => externalOid?.startsWith('bot') ?? false;

  /// 線を引く値段。条件付きは発動価格、指値は値段。
  double? get linePrice => kind == ExchangeOrderKind.trigger
      ? triggerPrice
      : price;

  /// 画面に出す名前。
  String get label {
    final what = switch (side) {
      1 => '買い',
      2 => '買い戻し',
      3 => '売り',
      _ => '売り決済',
    };
    if (kind == ExchangeOrderKind.trigger) {
      final when = triggerType == 2 ? '以下' : '以上';
      final how = executeOrderType == 1 && (price ?? 0) > 0
          ? '指値 $price'
          : '成行';
      return '条件 $triggerPrice $whenで$what ($how)';
    }
    return '指値$what $price';
  }

  /// `order/list/open_orders` の 1 件から作る。
  factory ExchangeOrder.fromOpenOrderJson(Map<String, dynamic> json) {
    double? d(String k) => (json[k] as num?)?.toDouble();
    double? positive(String k) {
      final v = d(k);
      return v == null || v <= 0 ? null : v;
    }

    return ExchangeOrder(
      id: '${json['orderId'] ?? json['id'] ?? ''}',
      symbol: json['symbol'] as String? ?? '',
      kind: ExchangeOrderKind.limit,
      side: (json['side'] as num?)?.toInt() ?? 1,
      vol: (d('vol') ?? 0) - (d('dealVol') ?? 0),
      price: d('price'),
      leverage: (json['leverage'] as num?)?.toInt(),
      takeProfitPrice: positive('takeProfitPrice'),
      stopLossPrice: positive('stopLossPrice'),
      externalOid: json['externalOid'] as String?,
      createTime: (json['createTime'] as num?)?.toInt() ?? 0,
    );
  }

  /// `planorder/list/orders` の 1 件から作る。
  factory ExchangeOrder.fromPlanOrderJson(Map<String, dynamic> json) {
    double? d(String k) => (json[k] as num?)?.toDouble();
    return ExchangeOrder(
      id: '${json['id'] ?? json['orderId'] ?? ''}',
      symbol: json['symbol'] as String? ?? '',
      kind: ExchangeOrderKind.trigger,
      side: (json['side'] as num?)?.toInt() ?? 1,
      vol: d('vol') ?? 0,
      price: d('price'),
      triggerPrice: d('triggerPrice'),
      triggerType: (json['triggerType'] as num?)?.toInt(),
      executeOrderType: (json['orderType'] as num?)?.toInt(),
      leverage: (json['leverage'] as num?)?.toInt(),
      createTime: (json['createTime'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'symbol': symbol,
    'kind': kind.name,
    'side': side,
    'vol': vol,
    if (price != null) 'price': price,
    if (triggerPrice != null) 'triggerPrice': triggerPrice,
    if (triggerType != null) 'triggerType': triggerType,
    if (executeOrderType != null) 'executeOrderType': executeOrderType,
    if (leverage != null) 'leverage': leverage,
    if (takeProfitPrice != null) 'takeProfitPrice': takeProfitPrice,
    if (stopLossPrice != null) 'stopLossPrice': stopLossPrice,
    if (externalOid != null) 'externalOid': externalOid,
    'createTime': createTime,
  };

  factory ExchangeOrder.fromJson(Map<String, dynamic> json) {
    double? d(String k) => (json[k] as num?)?.toDouble();
    return ExchangeOrder(
      id: '${json['id'] ?? ''}',
      symbol: json['symbol'] as String? ?? '',
      kind: ExchangeOrderKind.values.firstWhere(
        (e) => e.name == json['kind'],
        orElse: () => ExchangeOrderKind.limit,
      ),
      side: (json['side'] as num?)?.toInt() ?? 1,
      vol: d('vol') ?? 0,
      price: d('price'),
      triggerPrice: d('triggerPrice'),
      triggerType: (json['triggerType'] as num?)?.toInt(),
      executeOrderType: (json['executeOrderType'] as num?)?.toInt(),
      leverage: (json['leverage'] as num?)?.toInt(),
      takeProfitPrice: d('takeProfitPrice'),
      stopLossPrice: d('stopLossPrice'),
      externalOid: json['externalOid'] as String?,
      createTime: (json['createTime'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 条件付き注文に付けた利確 / 損切り。発動して建玉ができたらサーバーが置く。
@immutable
class PendingExit {
  const PendingExit({
    required this.planOrderId,
    required this.symbol,
    required this.direction,
    required this.createdAt,
    this.takeProfitPrice,
    this.stopLossPrice,
    this.baseVol = 0,
  });

  final String planOrderId;
  final String symbol;
  final TradeDirection direction;
  final DateTime createdAt;
  final double? takeProfitPrice;
  final double? stopLossPrice;

  /// 注文を出したときに、同じ銘柄・同じ向きの建玉が何枚あったか。
  /// これより増えたら「発動して建った」とみなす (前からある建玉に、取り消された
  /// 注文の利確 / 損切りを付けてしまわないため)。
  final double baseVol;

  Map<String, dynamic> toJson() => {
    'planOrderId': planOrderId,
    'symbol': symbol,
    'direction': direction.name,
    'createdAt': createdAt.toIso8601String(),
    if (takeProfitPrice != null) 'takeProfitPrice': takeProfitPrice,
    if (stopLossPrice != null) 'stopLossPrice': stopLossPrice,
    'baseVol': baseVol,
  };

  factory PendingExit.fromJson(Map<String, dynamic> json) => PendingExit(
    planOrderId: '${json['planOrderId'] ?? ''}',
    symbol: json['symbol'] as String? ?? '',
    direction: TradeDirection.fromName(json['direction'] as String?),
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.now(),
    takeProfitPrice: (json['takeProfitPrice'] as num?)?.toDouble(),
    stopLossPrice: (json['stopLossPrice'] as num?)?.toDouble(),
    baseVol: (json['baseVol'] as num?)?.toDouble() ?? 0,
  );
}
