import 'package:meta/meta.dart';

import 'timeframe.dart';

/// 新規建ての注文種別。
enum EntryOrderType {
  /// 成行 (MEXC の type=5)。
  market,

  /// 指値 (MEXC の type=1)。
  limit,
}

/// 売買の方向。
enum TradeDirection {
  /// 売りから入る。RSI が高く +σ を上抜けたときに建てる。
  short('ショート'),

  /// 買いから入る。RSI が低く -σ を下抜けたときに建てる。
  long('ロング');

  const TradeDirection(this.label);

  final String label;

  bool get isShort => this == TradeDirection.short;
  bool get isLong => this == TradeDirection.long;

  TradeDirection get opposite => isShort ? TradeDirection.long : TradeDirection.short;

  /// MEXC の新規建て side。1 = 買い新規 / 3 = 売り新規。
  int get openSide => isShort ? 3 : 1;

  /// MEXC の決済 side。2 = 売り決済 / 4 = 買い決済。
  int get closeSide => isShort ? 2 : 4;

  /// MEXC の positionType。1 = ロング / 2 = ショート。
  int get positionType => isShort ? 2 : 1;

  static TradeDirection fromName(String? name) => TradeDirection.values
      .firstWhere((e) => e.name == name, orElse: () => TradeDirection.short);

  /// 取引所が返す positionType (1/2) から方向を判定する。
  static TradeDirection fromPositionType(int positionType) =>
      positionType == 1 ? TradeDirection.long : TradeDirection.short;
}

/// 片方向ぶんの売買条件。
///
/// ショートとロングで同じ項目を持ち、既定値も揃えてある。
/// RSI のしきい値だけは向きが逆になるので、ショートは「以上」、
/// ロングは「以下」で判定する (既定は 97 と 3 で左右対称)。
@immutable
class SideConfig {
  const SideConfig({
    required this.direction,
    this.enabled = true,
    this.rsiThreshold = 97.0,
    this.bbSigma = 4.0,
    this.leverage = 1,
    this.marginPerTradeUsdt = 10,
    this.limitOffsetPercent = 0.0,
    this.takeProfitFactor = 0.5,
    this.minTakeProfitPercent = 0.3,
    this.maxFundingBurdenPercent = 0.1,
    this.minFundingIntervalHours = 2,
    this.bandBreakoutEntryEnabled = true,
    this.bandBreakoutPercent = 20.0,
  });

  /// ショートの既定値 (利用者の指定どおりの条件)。
  const SideConfig.short() : this(direction: TradeDirection.short);

  /// ロングの既定値。ショートを鏡写しにした値で揃えてある。
  const SideConfig.long()
      : this(direction: TradeDirection.long, rsiThreshold: 3.0);

  final TradeDirection direction;

  /// この方向で新規建てするか。
  final bool enabled;

  /// RSI の発火しきい値。ショートは「以上」、ロングは「以下」。
  final double rsiThreshold;

  /// ボリンジャーバンドの σ 倍率。ショートは +σ 上抜け、ロングは -σ 下抜け。
  final double bbSigma;

  /// レバレッジ。
  final int leverage;

  /// 1 回のエントリーに使う証拠金 (USDT)。
  final double marginPerTradeUsdt;

  /// 指値注文時に現在値から何%離して出すか。
  ///
  /// ショートは高い側、ロングは安い側 (どちらも自分に有利な向き) に離す。
  final double limitOffsetPercent;

  /// 検知時の EMA からの乖離率に掛ける係数。既定 0.5。
  final double takeProfitFactor;

  /// 利確幅がこの%未満なら見送る。API経由の往復手数料 (0.16%前後) 負け対策。
  final double minTakeProfitPercent;

  /// 資金調達を「支払う側」のとき、この%を超えていたら見送る。
  final double maxFundingBurdenPercent;

  /// 資金調達を「支払う側」のとき、調達間隔がこの時間未満なら見送る。
  final int minFundingIntervalHours;

  /// バンドから大きく離れたら、RSI を見ずに逆張りで入るか。
  ///
  /// 行きすぎが極端なときは RSI が張り付いて動かなくなることがあるので、
  /// しきい値に届かなくても入れるようにする逃げ道。
  final bool bandBreakoutEntryEnabled;

  /// σ のバンドからこの % 以上離れていたら、RSI を見ずに入る。
  ///
  /// ショートは +σ の上、ロングは -σ の下にこれだけ離れたときが対象。
  final double bandBreakoutPercent;

  /// 反対方向の設定を、この設定を鏡写しにして作る。
  ///
  /// RSI のしきい値だけ 100 から引いた値にし、他の項目はそのまま揃える。
  SideConfig mirrored() => SideConfig(
    direction: direction.opposite,
    enabled: enabled,
    rsiThreshold: 100 - rsiThreshold,
    bbSigma: bbSigma,
    leverage: leverage,
    marginPerTradeUsdt: marginPerTradeUsdt,
    limitOffsetPercent: limitOffsetPercent,
    takeProfitFactor: takeProfitFactor,
    minTakeProfitPercent: minTakeProfitPercent,
    maxFundingBurdenPercent: maxFundingBurdenPercent,
    minFundingIntervalHours: minFundingIntervalHours,
    bandBreakoutEntryEnabled: bandBreakoutEntryEnabled,
    bandBreakoutPercent: bandBreakoutPercent,
  );

  /// この方向の設定に問題があれば日本語で返す。
  List<String> validate() {
    final errors = <String>[];
    final name = direction.label;
    if (bbSigma <= 0) errors.add('$name: σ倍率は 0 より大きい値にしてください。');
    if (rsiThreshold <= 0 || rsiThreshold > 100) {
      errors.add('$name: RSIしきい値は 0 より大きく 100 以下にしてください。');
    }
    if (leverage < 1) errors.add('$name: レバレッジは 1 以上にしてください。');
    if (marginPerTradeUsdt <= 0) {
      errors.add('$name: 1回あたりの証拠金は 0 より大きい値にしてください。');
    }
    if (takeProfitFactor <= 0 || takeProfitFactor >= 1) {
      errors.add('$name: 利確係数は 0 より大きく 1 未満にしてください。');
    }
    if (bandBreakoutEntryEnabled && bandBreakoutPercent <= 0) {
      errors.add('$name: バンドからの乖離幅は 0 より大きい値にしてください。');
    }
    if (direction.isLong &&
        bandBreakoutEntryEnabled &&
        bandBreakoutPercent >= 100) {
      errors.add('$name: バンドからの乖離幅は 100% 未満にしてください。');
    }
    return errors;
  }

  SideConfig copyWith({
    bool? enabled,
    double? rsiThreshold,
    double? bbSigma,
    int? leverage,
    double? marginPerTradeUsdt,
    double? limitOffsetPercent,
    double? takeProfitFactor,
    double? minTakeProfitPercent,
    double? maxFundingBurdenPercent,
    int? minFundingIntervalHours,
    bool? bandBreakoutEntryEnabled,
    double? bandBreakoutPercent,
  }) => SideConfig(
    direction: direction,
    enabled: enabled ?? this.enabled,
    rsiThreshold: rsiThreshold ?? this.rsiThreshold,
    bbSigma: bbSigma ?? this.bbSigma,
    leverage: leverage ?? this.leverage,
    marginPerTradeUsdt: marginPerTradeUsdt ?? this.marginPerTradeUsdt,
    limitOffsetPercent: limitOffsetPercent ?? this.limitOffsetPercent,
    takeProfitFactor: takeProfitFactor ?? this.takeProfitFactor,
    minTakeProfitPercent: minTakeProfitPercent ?? this.minTakeProfitPercent,
    maxFundingBurdenPercent:
        maxFundingBurdenPercent ?? this.maxFundingBurdenPercent,
    minFundingIntervalHours:
        minFundingIntervalHours ?? this.minFundingIntervalHours,
    bandBreakoutEntryEnabled:
        bandBreakoutEntryEnabled ?? this.bandBreakoutEntryEnabled,
    bandBreakoutPercent: bandBreakoutPercent ?? this.bandBreakoutPercent,
  );

  Map<String, dynamic> toJson() => {
    'direction': direction.name,
    'enabled': enabled,
    'rsiThreshold': rsiThreshold,
    'bbSigma': bbSigma,
    'leverage': leverage,
    'marginPerTradeUsdt': marginPerTradeUsdt,
    'limitOffsetPercent': limitOffsetPercent,
    'takeProfitFactor': takeProfitFactor,
    'minTakeProfitPercent': minTakeProfitPercent,
    'maxFundingBurdenPercent': maxFundingBurdenPercent,
    'minFundingIntervalHours': minFundingIntervalHours,
    'bandBreakoutEntryEnabled': bandBreakoutEntryEnabled,
    'bandBreakoutPercent': bandBreakoutPercent,
  };

  factory SideConfig.fromJson(
    Map<String, dynamic> json, {
    required TradeDirection direction,
  }) {
    final fallback = direction.isShort
        ? const SideConfig.short()
        : const SideConfig.long();
    double d(String k, double f) => (json[k] as num?)?.toDouble() ?? f;
    int i(String k, int f) => (json[k] as num?)?.toInt() ?? f;
    bool b(String k, bool f) => json[k] as bool? ?? f;

    return SideConfig(
      direction: direction,
      enabled: b('enabled', fallback.enabled),
      rsiThreshold: d('rsiThreshold', fallback.rsiThreshold),
      bbSigma: d('bbSigma', fallback.bbSigma),
      leverage: i('leverage', fallback.leverage),
      marginPerTradeUsdt: d('marginPerTradeUsdt', fallback.marginPerTradeUsdt),
      limitOffsetPercent: d('limitOffsetPercent', fallback.limitOffsetPercent),
      takeProfitFactor: d('takeProfitFactor', fallback.takeProfitFactor),
      minTakeProfitPercent:
          d('minTakeProfitPercent', fallback.minTakeProfitPercent),
      maxFundingBurdenPercent: d(
        'maxFundingBurdenPercent',
        // 旧形式 (ショートだけの頃) のキーも拾う。
        d('maxShortBurdenPercent', fallback.maxFundingBurdenPercent),
      ),
      minFundingIntervalHours:
          i('minFundingIntervalHours', fallback.minFundingIntervalHours),
      bandBreakoutEntryEnabled:
          b('bandBreakoutEntryEnabled', fallback.bandBreakoutEntryEnabled),
      bandBreakoutPercent:
          d('bandBreakoutPercent', fallback.bandBreakoutPercent),
    );
  }
}

/// 売買ロジックの全パラメーター。
///
/// 指標の期間や監視銘柄など方向に依らないものはここに、
/// しきい値や建玉サイズなど方向ごとに変えたいものは [short] / [long] に持つ。
@immutable
class StrategyConfig {
  const StrategyConfig({
    this.minAmount24Usdt = 5000000,
    this.timeframes = const [
      Timeframe.m15,
      Timeframe.h1,
      Timeframe.h4,
      Timeframe.d1,
    ],
    this.bbPeriod = 20,
    this.rsiPeriod = 7,
    this.emaPeriod = 5,
    this.historyBars = 300,
    this.short = const SideConfig.short(),
    this.long = const SideConfig.long(),
    this.orderType = EntryOrderType.market,
    this.useIsolatedMargin = true,
    this.attachTakeProfitToOrder = true,
    this.fundingFilterEnabled = true,
    this.evaluationIntervalSeconds = 60,
    this.reentryCooldownMinutes = 60,
    this.oneSignalPerBar = true,
  });

  // ── 銘柄の絞り込み ───────────────────────────────────────────
  /// 24時間売買代金の下限 (USDT)。既定 5,000,000。
  ///
  /// 監視する銘柄はこの下限だけで決める。銘柄数に上限は設けず、
  /// 手で選んだり外したりもしない。
  final double minAmount24Usdt;

  // ── 指標 (方向で共通) ───────────────────────────────────────
  /// 判定に使う時間軸。複数指定でき、それぞれ独立に判定する。
  final List<Timeframe> timeframes;

  /// ボリンジャーバンドの期間。既定 20。
  final int bbPeriod;

  /// RSI の期間。既定 7。
  final int rsiPeriod;

  /// 利確の基準にする EMA の期間。既定 5。
  final int emaPeriod;

  /// 指標を安定させるために保持する足の本数。
  final int historyBars;

  // ── 方向ごとの条件 ──────────────────────────────────────────
  final SideConfig short;
  final SideConfig long;

  // ── エントリー (方向で共通) ─────────────────────────────────
  final EntryOrderType orderType;

  /// 分離マージン (openType=1) を使うか。false ならクロス (2)。
  final bool useIsolatedMargin;

  /// 発注と同時に takeProfitPrice を付けるか。false なら約定後に別途設定する。
  final bool attachTakeProfitToOrder;

  // ── 資金調達率フィルタ ──────────────────────────────────────
  /// フィルタ自体の入り切り。負担率や間隔の基準は方向ごとに持つ。
  final bool fundingFilterEnabled;

  // ── 運用 ────────────────────────────────────────────────────
  /// 判定の実行間隔 (秒)。既定 60 秒。進行中の足も含めて毎回評価する。
  final int evaluationIntervalSeconds;

  /// 決済後、同じ銘柄に再エントリーするまでの待ち時間 (分)。
  final int reentryCooldownMinutes;

  /// 同じ足で 2 回以上発火させないか。
  final bool oneSignalPerBar;

  /// MEXC の openType に対応する値。
  int get openType => useIsolatedMargin ? 1 : 2;

  /// MEXC の positionMode に対応する値。一方向モード (2) で固定。
  ///
  /// 同じ銘柄に反対向きの建玉を同時に持つことはないので、ヘッジは使わない。
  int get positionModeValue => 2;

  /// MEXC の注文 type に対応する値。
  int get orderTypeValue => orderType == EntryOrderType.market ? 5 : 1;

  SideConfig sideOf(TradeDirection direction) =>
      direction.isShort ? short : long;

  /// 新規建てを行う方向。両方切っていれば空。
  List<SideConfig> get enabledSides =>
      [short, long].where((s) => s.enabled).toList(growable: false);

  /// 設定の矛盾を日本語で返す。空なら問題なし。
  List<String> validate() {
    final errors = <String>[];
    if (timeframes.isEmpty) {
      errors.add('時間軸が 1 つも選ばれていません。');
    }
    if (bbPeriod < 2) errors.add('BB期間は 2 以上にしてください。');
    if (rsiPeriod < 2) errors.add('RSI期間は 2 以上にしてください。');
    if (emaPeriod < 1) errors.add('EMA期間は 1 以上にしてください。');
    if (evaluationIntervalSeconds < 5) {
      errors.add('判定間隔は 5 秒以上にしてください。');
    }
    if (historyBars < bbPeriod + 5 || historyBars < rsiPeriod * 10) {
      errors.add('履歴本数が少なすぎます。指標期間の 10 倍以上を推奨します。');
    }
    if (!short.enabled && !long.enabled) {
      errors.add('ショートとロングの両方が切られています。少なくとも片方を入れてください。');
    }
    errors.addAll(short.validate());
    errors.addAll(long.validate());
    return errors;
  }

  StrategyConfig copyWith({
    double? minAmount24Usdt,
    List<Timeframe>? timeframes,
    int? bbPeriod,
    int? rsiPeriod,
    int? emaPeriod,
    int? historyBars,
    SideConfig? short,
    SideConfig? long,
    EntryOrderType? orderType,
    bool? useIsolatedMargin,
    bool? attachTakeProfitToOrder,
    bool? fundingFilterEnabled,
    int? evaluationIntervalSeconds,
    int? reentryCooldownMinutes,
    bool? oneSignalPerBar,
  }) => StrategyConfig(
    minAmount24Usdt: minAmount24Usdt ?? this.minAmount24Usdt,
    timeframes: timeframes ?? this.timeframes,
    bbPeriod: bbPeriod ?? this.bbPeriod,
    rsiPeriod: rsiPeriod ?? this.rsiPeriod,
    emaPeriod: emaPeriod ?? this.emaPeriod,
    historyBars: historyBars ?? this.historyBars,
    short: short ?? this.short,
    long: long ?? this.long,
    orderType: orderType ?? this.orderType,
    useIsolatedMargin: useIsolatedMargin ?? this.useIsolatedMargin,
    attachTakeProfitToOrder:
        attachTakeProfitToOrder ?? this.attachTakeProfitToOrder,
    fundingFilterEnabled: fundingFilterEnabled ?? this.fundingFilterEnabled,
    evaluationIntervalSeconds:
        evaluationIntervalSeconds ?? this.evaluationIntervalSeconds,
    reentryCooldownMinutes:
        reentryCooldownMinutes ?? this.reentryCooldownMinutes,
    oneSignalPerBar: oneSignalPerBar ?? this.oneSignalPerBar,
  );

  /// 片方向ぶんだけ差し替える。
  StrategyConfig withSide(SideConfig side) => side.direction.isShort
      ? copyWith(short: side)
      : copyWith(long: side);

  Map<String, dynamic> toJson() => {
    'minAmount24Usdt': minAmount24Usdt,
    'timeframes': timeframes.map((t) => t.name).toList(),
    'bbPeriod': bbPeriod,
    'rsiPeriod': rsiPeriod,
    'emaPeriod': emaPeriod,
    'historyBars': historyBars,
    'short': short.toJson(),
    'long': long.toJson(),
    'orderType': orderType.name,
    'useIsolatedMargin': useIsolatedMargin,
    'attachTakeProfitToOrder': attachTakeProfitToOrder,
    'fundingFilterEnabled': fundingFilterEnabled,
    'evaluationIntervalSeconds': evaluationIntervalSeconds,
    'reentryCooldownMinutes': reentryCooldownMinutes,
    'oneSignalPerBar': oneSignalPerBar,
  };

  factory StrategyConfig.fromJson(Map<String, dynamic> json) {
    const fallback = StrategyConfig();
    double d(String k, double f) => (json[k] as num?)?.toDouble() ?? f;
    int i(String k, int f) => (json[k] as num?)?.toInt() ?? f;
    bool b(String k, bool f) => json[k] as bool? ?? f;
    List<String> s(String k, List<String> f) =>
        (json[k] as List?)?.map((e) => e.toString()).toList() ?? f;
    Map<String, dynamic>? m(String k) =>
        (json[k] as Map?)?.cast<String, dynamic>();

    final tfNames = s('timeframes', const []);
    final tfs = tfNames
        .map(Timeframe.fromName)
        .whereType<Timeframe>()
        .toList(growable: false);

    // 方向ごとの設定が無い保存データ (ショート専用だった頃のもの) は、
    // フラットに置かれていた値をショートとして読み、ロングはその鏡写しにする。
    final shortJson = m('short') ?? json;
    final shortSide =
        SideConfig.fromJson(shortJson, direction: TradeDirection.short);
    final longJson = m('long');
    final longSide = longJson == null
        ? shortSide.mirrored()
        : SideConfig.fromJson(longJson, direction: TradeDirection.long);

    return StrategyConfig(
      minAmount24Usdt: d('minAmount24Usdt', fallback.minAmount24Usdt),
      timeframes: tfs.isEmpty ? fallback.timeframes : tfs,
      bbPeriod: i('bbPeriod', fallback.bbPeriod),
      rsiPeriod: i('rsiPeriod', fallback.rsiPeriod),
      emaPeriod: i('emaPeriod', fallback.emaPeriod),
      historyBars: i('historyBars', fallback.historyBars),
      short: shortSide,
      long: longSide,
      orderType: EntryOrderType.values.firstWhere(
        (e) => e.name == json['orderType'],
        orElse: () => fallback.orderType,
      ),
      useIsolatedMargin: b('useIsolatedMargin', fallback.useIsolatedMargin),
      attachTakeProfitToOrder:
          b('attachTakeProfitToOrder', fallback.attachTakeProfitToOrder),
      fundingFilterEnabled:
          b('fundingFilterEnabled', fallback.fundingFilterEnabled),
      evaluationIntervalSeconds:
          i('evaluationIntervalSeconds', fallback.evaluationIntervalSeconds),
      reentryCooldownMinutes:
          i('reentryCooldownMinutes', fallback.reentryCooldownMinutes),
      oneSignalPerBar: b('oneSignalPerBar', fallback.oneSignalPerBar),
    );
  }
}
