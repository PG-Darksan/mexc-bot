import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'timeframe.dart';

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
/// 監視する銘柄の出来高、判定する時間軸、指標の期間も方向ごとに決められる。
/// RSI のしきい値だけは向きが逆になるので、ショートは「以上」、
/// ロングは「以下」で判定する (既定は 97 と 3 で左右対称)。
@immutable
class SideConfig {
  const SideConfig({
    required this.direction,
    this.enabled = true,
    this.minAmount24Usdt = 5000000,
    this.timeframes = defaultTimeframes,
    this.bbPeriod = 20,
    this.rsiPeriod = 7,
    this.emaPeriod = 5,
    this.historyBars = 300,
    this.rsiThreshold = 97.0,
    this.bbSigma = 4.0,
    this.leverage = 1,
    this.marginPerTradeUsdt = 10,
    this.takeProfitFactor = 0.5,
    this.minTakeProfitPercent = 0.3,
    this.maxFundingBurdenPercent = 0.1,
    this.minFundingIntervalHours = 2,
    this.bandBreakoutEntryEnabled = true,
    this.bandBreakoutPercent = 20.0,
    this.addOnEnabled = false,
    this.addOnLossPercent = 10.0,
    this.addOnBudgetPercent = 100.0,
  });

  /// ショートの既定値 (利用者の指定どおりの条件)。
  const SideConfig.short() : this(direction: TradeDirection.short);

  /// ロングの既定値。ショートを鏡写しにした値で揃えてある。
  const SideConfig.long()
      : this(direction: TradeDirection.long, rsiThreshold: 3.0);

  /// 時間軸の既定値。
  static const List<Timeframe> defaultTimeframes = [
    Timeframe.m15,
    Timeframe.h1,
    Timeframe.h4,
    Timeframe.d1,
  ];

  final TradeDirection direction;

  /// この方向で新規建てするか。
  final bool enabled;

  // ── 銘柄の絞り込み (方向ごと) ───────────────────────────────
  /// 24時間売買代金の下限 (USDT)。既定 5,000,000。
  ///
  /// この方向で見る銘柄はこの下限だけで決める。銘柄数に上限は設けず、
  /// 手で選んだり外したりもしない。
  final double minAmount24Usdt;

  // ── 指標 (方向ごと) ─────────────────────────────────────────
  /// この方向で判定する時間軸。複数指定でき、それぞれ独立に判定する。
  final List<Timeframe> timeframes;

  /// ボリンジャーバンドの期間。既定 20。
  final int bbPeriod;

  /// RSI の期間。既定 7。
  final int rsiPeriod;

  /// 利確の基準にする EMA の期間。既定 5。
  final int emaPeriod;

  /// 指標を安定させるために保持する足の本数。
  final int historyBars;

  // ── しきい値と建玉 ──────────────────────────────────────────
  /// RSI の発火しきい値。ショートは「以上」、ロングは「以下」。
  final double rsiThreshold;

  /// ボリンジャーバンドの σ 倍率。ショートは +σ 上抜け、ロングは -σ 下抜け。
  final double bbSigma;

  /// レバレッジ。
  final int leverage;

  /// 1 回のエントリーに使う証拠金 (USDT)。
  final double marginPerTradeUsdt;

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

  // ── 買い足し / 売り足し ─────────────────────────────────────
  /// 成行で建てたあと、逆行したところに同じ向きの指値を置くか。
  ///
  /// ロングなら建値より下に買い指値、ショートなら建値より上に売り指値。
  /// 約定すれば平均建値が有利な側へ寄る。利確の目標は動かさない。
  final bool addOnEnabled;

  /// 証拠金に対する含み損がこの % になる価格に指値を置く。
  ///
  /// レバレッジ 1 倍なら建値からの値動き % と同じ。2 倍なら値動きは半分で済む。
  final double addOnLossPercent;

  /// 成行を出したあと口座に残っている USDT のうち、指値に使う割合 (%)。
  ///
  /// 指値を置いた時点でその証拠金は凍結されるので、
  /// 100% にすると次の銘柄の新規建てに回す資金が無くなる。
  final double addOnBudgetPercent;

  /// 買い足しの指値を置く価格。建値からの値動きは 含み損% ÷ レバレッジ。
  double addOnPriceFor(double entryPrice) {
    final move = addOnLossPercent / 100 / leverage;
    return direction.isShort ? entryPrice * (1 + move) : entryPrice * (1 - move);
  }

  /// この方向の指標を出すのに必要な最低本数。
  ///
  /// Wilder 平滑は再帰なので、しきい値判定に使うには十分な助走が要る。
  int get requiredBars {
    final need = [
      bbPeriod,
      rsiPeriod + 1,
      emaPeriod,
    ].reduce((a, b) => a > b ? a : b);
    return need + rsiPeriod * 5;
  }

  /// 反対方向の設定を、この設定を鏡写しにして作る。
  ///
  /// RSI のしきい値だけ 100 から引いた値にし、他の項目はそのまま揃える。
  SideConfig mirrored() => SideConfig(
    direction: direction.opposite,
    enabled: enabled,
    minAmount24Usdt: minAmount24Usdt,
    timeframes: timeframes,
    bbPeriod: bbPeriod,
    rsiPeriod: rsiPeriod,
    emaPeriod: emaPeriod,
    historyBars: historyBars,
    rsiThreshold: 100 - rsiThreshold,
    bbSigma: bbSigma,
    leverage: leverage,
    marginPerTradeUsdt: marginPerTradeUsdt,
    takeProfitFactor: takeProfitFactor,
    minTakeProfitPercent: minTakeProfitPercent,
    maxFundingBurdenPercent: maxFundingBurdenPercent,
    minFundingIntervalHours: minFundingIntervalHours,
    bandBreakoutEntryEnabled: bandBreakoutEntryEnabled,
    bandBreakoutPercent: bandBreakoutPercent,
    addOnEnabled: addOnEnabled,
    addOnLossPercent: addOnLossPercent,
    addOnBudgetPercent: addOnBudgetPercent,
  );

  /// この方向の設定に問題があれば日本語で返す。
  List<String> validate() {
    final errors = <String>[];
    final name = direction.label;
    if (timeframes.isEmpty) {
      errors.add('$name: 時間軸が 1 つも選ばれていません。');
    }
    if (minAmount24Usdt < 0) {
      errors.add('$name: 24h出来高の下限は 0 以上にしてください。');
    }
    if (bbPeriod < 2) errors.add('$name: BB期間は 2 以上にしてください。');
    if (rsiPeriod < 2) errors.add('$name: RSI期間は 2 以上にしてください。');
    if (emaPeriod < 1) errors.add('$name: EMA期間は 1 以上にしてください。');
    if (historyBars < requiredBars) {
      errors.add('$name: 保持する足が少なすぎます。$requiredBars 本以上にしてください。');
    }
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
      errors.add('$name: 行きすぎの基準 (σ のバンドから離れた割合) は 0 より大きい値にしてください。');
    }
    if (direction.isLong &&
        bandBreakoutEntryEnabled &&
        bandBreakoutPercent >= 100) {
      errors.add('$name: 行きすぎの基準 (σ のバンドから離れた割合) は 100% 未満にしてください。');
    }
    if (addOnEnabled) {
      if (addOnLossPercent <= 0) {
        errors.add('$name: 買い足しを入れる含み損は 0 より大きい値にしてください。');
      }
      if (direction.isLong && addOnLossPercent / leverage >= 100) {
        errors.add('$name: 買い足しの含み損 ÷ レバレッジ は 100% 未満にしてください。');
      }
      if (addOnBudgetPercent <= 0 || addOnBudgetPercent > 100) {
        errors.add('$name: 買い足しに使う残り資金の割合は 0 より大きく 100 以下にしてください。');
      }
    }
    return errors;
  }

  SideConfig copyWith({
    bool? enabled,
    double? minAmount24Usdt,
    List<Timeframe>? timeframes,
    int? bbPeriod,
    int? rsiPeriod,
    int? emaPeriod,
    int? historyBars,
    double? rsiThreshold,
    double? bbSigma,
    int? leverage,
    double? marginPerTradeUsdt,
    double? takeProfitFactor,
    double? minTakeProfitPercent,
    double? maxFundingBurdenPercent,
    int? minFundingIntervalHours,
    bool? bandBreakoutEntryEnabled,
    double? bandBreakoutPercent,
    bool? addOnEnabled,
    double? addOnLossPercent,
    double? addOnBudgetPercent,
  }) => SideConfig(
    direction: direction,
    enabled: enabled ?? this.enabled,
    minAmount24Usdt: minAmount24Usdt ?? this.minAmount24Usdt,
    timeframes: timeframes ?? this.timeframes,
    bbPeriod: bbPeriod ?? this.bbPeriod,
    rsiPeriod: rsiPeriod ?? this.rsiPeriod,
    emaPeriod: emaPeriod ?? this.emaPeriod,
    historyBars: historyBars ?? this.historyBars,
    rsiThreshold: rsiThreshold ?? this.rsiThreshold,
    bbSigma: bbSigma ?? this.bbSigma,
    leverage: leverage ?? this.leverage,
    marginPerTradeUsdt: marginPerTradeUsdt ?? this.marginPerTradeUsdt,
    takeProfitFactor: takeProfitFactor ?? this.takeProfitFactor,
    minTakeProfitPercent: minTakeProfitPercent ?? this.minTakeProfitPercent,
    maxFundingBurdenPercent:
        maxFundingBurdenPercent ?? this.maxFundingBurdenPercent,
    minFundingIntervalHours:
        minFundingIntervalHours ?? this.minFundingIntervalHours,
    bandBreakoutEntryEnabled:
        bandBreakoutEntryEnabled ?? this.bandBreakoutEntryEnabled,
    bandBreakoutPercent: bandBreakoutPercent ?? this.bandBreakoutPercent,
    addOnEnabled: addOnEnabled ?? this.addOnEnabled,
    addOnLossPercent: addOnLossPercent ?? this.addOnLossPercent,
    addOnBudgetPercent: addOnBudgetPercent ?? this.addOnBudgetPercent,
  );

  Map<String, dynamic> toJson() => {
    'direction': direction.name,
    'enabled': enabled,
    'minAmount24Usdt': minAmount24Usdt,
    'timeframes': timeframes.map((t) => t.name).toList(),
    'bbPeriod': bbPeriod,
    'rsiPeriod': rsiPeriod,
    'emaPeriod': emaPeriod,
    'historyBars': historyBars,
    'rsiThreshold': rsiThreshold,
    'bbSigma': bbSigma,
    'leverage': leverage,
    'marginPerTradeUsdt': marginPerTradeUsdt,
    'takeProfitFactor': takeProfitFactor,
    'minTakeProfitPercent': minTakeProfitPercent,
    'maxFundingBurdenPercent': maxFundingBurdenPercent,
    'minFundingIntervalHours': minFundingIntervalHours,
    'bandBreakoutEntryEnabled': bandBreakoutEntryEnabled,
    'bandBreakoutPercent': bandBreakoutPercent,
    'addOnEnabled': addOnEnabled,
    'addOnLossPercent': addOnLossPercent,
    'addOnBudgetPercent': addOnBudgetPercent,
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

    final tfs = ((json['timeframes'] as List?) ?? const [])
        .map((e) => Timeframe.fromName(e.toString()))
        .whereType<Timeframe>()
        .toList(growable: false);

    return SideConfig(
      direction: direction,
      enabled: b('enabled', fallback.enabled),
      minAmount24Usdt: d('minAmount24Usdt', fallback.minAmount24Usdt),
      timeframes: tfs.isEmpty ? fallback.timeframes : tfs,
      bbPeriod: i('bbPeriod', fallback.bbPeriod),
      rsiPeriod: i('rsiPeriod', fallback.rsiPeriod),
      emaPeriod: i('emaPeriod', fallback.emaPeriod),
      historyBars: i('historyBars', fallback.historyBars),
      rsiThreshold: d('rsiThreshold', fallback.rsiThreshold),
      bbSigma: d('bbSigma', fallback.bbSigma),
      leverage: i('leverage', fallback.leverage),
      marginPerTradeUsdt: d('marginPerTradeUsdt', fallback.marginPerTradeUsdt),
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
      addOnEnabled: b('addOnEnabled', fallback.addOnEnabled),
      addOnLossPercent: d('addOnLossPercent', fallback.addOnLossPercent),
      addOnBudgetPercent: d('addOnBudgetPercent', fallback.addOnBudgetPercent),
    );
  }
}

/// 売買ロジックの全パラメーター。
///
/// 出来高の下限・時間軸・指標の期間・しきい値・建玉サイズは、
/// すべて方向ごとに [short] / [long] が持つ。ここに残すのは
/// 発注や運用のように方向で分けようのないものだけ。
@immutable
class StrategyConfig {
  const StrategyConfig({
    this.short = const SideConfig.short(),
    this.long = const SideConfig.long(),
    this.evaluationIntervalSeconds = 60,
    this.reentryCooldownMinutes = 60,
    this.oneSignalPerBar = true,
  });

  // ── 方向ごとの条件 ──────────────────────────────────────────
  final SideConfig short;
  final SideConfig long;

  // ── 運用 ────────────────────────────────────────────────────
  /// 判定の実行間隔 (秒)。既定 60 秒。進行中の足も含めて毎回評価する。
  final int evaluationIntervalSeconds;

  /// 決済後、同じ銘柄に再エントリーするまでの待ち時間 (分)。
  final int reentryCooldownMinutes;

  /// 同じ足で 2 回以上発火させないか。
  final bool oneSignalPerBar;

  /// 発注と同時に利確 (takeProfitPrice) を取引所へ預ける。常に行う。
  ///
  /// こうしておけば、アプリやサーバーが落ちていても取引所側で利確される。
  /// 切る意味が無いので設定項目にはしていない。
  bool get attachTakeProfitToOrder => true;

  /// 資金調達率のフィルタ。常に効かせる。
  ///
  /// その方向が支払う側のときだけ効く。負担率と間隔の基準は方向ごとに持つ。
  /// 切る意味が無いので設定項目にはしていない。
  bool get fundingFilterEnabled => true;

  /// MEXC の openType。分離マージン (1) で固定。
  ///
  /// 損切りを置かない作りなので、クロスマージンは使わない。
  int get openType => 1;

  /// MEXC の注文 type。成行 (5) で固定。指値は使わない。
  int get orderTypeValue => 5;

  /// MEXC の positionMode に対応する値。一方向モード (2) で固定。
  ///
  /// 同じ銘柄に反対向きの建玉を同時に持つことはないので、ヘッジは使わない。
  int get positionModeValue => 2;

  SideConfig sideOf(TradeDirection direction) =>
      direction.isShort ? short : long;

  /// 新規建てを行う方向。両方切っていれば空。
  List<SideConfig> get enabledSides =>
      [short, long].where((s) => s.enabled).toList(growable: false);

  /// 銘柄と足を集めるときに見る方向。
  ///
  /// 両方切っていても画面には出したいので、その場合は両方向を見る。
  List<SideConfig> get watchedSides {
    final on = enabledSides;
    return on.isEmpty ? [short, long] : on;
  }

  /// 集めておく時間軸 (方向ごとの指定を合わせたもの)。
  List<Timeframe> get timeframes {
    final set = <Timeframe>{};
    for (final side in watchedSides) {
      set.addAll(side.timeframes);
    }
    return set.toList(growable: false)
      ..sort((a, b) => a.seconds.compareTo(b.seconds));
  }

  /// 監視銘柄を選ぶときの出来高の下限。方向ごとの指定のうち低いほう。
  ///
  /// ここで広く集めてから、方向ごとの下限で判定時に落とす。
  double get minAmount24Usdt =>
      watchedSides.map((s) => s.minAmount24Usdt).reduce(math.min);

  /// 保持する足の本数。方向ごとの指定のうち多いほう。
  int get historyBars =>
      watchedSides.map((s) => s.historyBars).reduce(math.max);

  /// 画面に 1 つだけ出すときに使う代表の方向。
  SideConfig get primarySide => short.enabled || !long.enabled ? short : long;

  /// 代表の方向の BB 期間 (チャートなどの表示用)。
  int get bbPeriod => primarySide.bbPeriod;

  /// 代表の方向の RSI 期間 (チャートなどの表示用)。
  int get rsiPeriod => primarySide.rsiPeriod;

  /// 代表の方向の EMA 期間 (チャートなどの表示用)。
  int get emaPeriod => primarySide.emaPeriod;

  /// 設定の矛盾を日本語で返す。空なら問題なし。
  List<String> validate() {
    final errors = <String>[];
    if (evaluationIntervalSeconds < 5) {
      errors.add('判定間隔は 5 秒以上にしてください。');
    }
    if (!short.enabled && !long.enabled) {
      errors.add('ショートとロングの両方が切られています。少なくとも片方を入れてください。');
    }
    errors.addAll(short.validate());
    errors.addAll(long.validate());
    return errors;
  }

  StrategyConfig copyWith({
    SideConfig? short,
    SideConfig? long,
    int? evaluationIntervalSeconds,
    int? reentryCooldownMinutes,
    bool? oneSignalPerBar,
  }) => StrategyConfig(
    short: short ?? this.short,
    long: long ?? this.long,
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
    'short': short.toJson(),
    'long': long.toJson(),
    'evaluationIntervalSeconds': evaluationIntervalSeconds,
    'reentryCooldownMinutes': reentryCooldownMinutes,
    'oneSignalPerBar': oneSignalPerBar,
  };

  factory StrategyConfig.fromJson(Map<String, dynamic> json) {
    const fallback = StrategyConfig();
    int i(String k, int f) => (json[k] as num?)?.toInt() ?? f;
    bool b(String k, bool f) => json[k] as bool? ?? f;
    Map<String, dynamic>? m(String k) =>
        (json[k] as Map?)?.cast<String, dynamic>();

    // 出来高・時間軸・指標の期間が方向で共通だった頃の保存データを拾う。
    // 方向ごとの値があればそちらが優先される (後ろのマップが勝つ)。
    final shared = <String, dynamic>{
      for (final key in const [
        'minAmount24Usdt',
        'timeframes',
        'bbPeriod',
        'rsiPeriod',
        'emaPeriod',
        'historyBars',
      ])
        if (json.containsKey(key)) key: json[key],
    };

    // 方向ごとの設定が無い保存データ (ショート専用だった頃のもの) は、
    // フラットに置かれていた値をショートとして読み、ロングはその鏡写しにする。
    final shortJson = {...shared, ...(m('short') ?? json)};
    final shortSide =
        SideConfig.fromJson(shortJson, direction: TradeDirection.short);
    final longJson = m('long');
    final longSide = longJson == null
        ? shortSide.mirrored()
        : SideConfig.fromJson(
            {...shared, ...longJson},
            direction: TradeDirection.long,
          );

    return StrategyConfig(
      short: shortSide,
      long: longSide,
      evaluationIntervalSeconds:
          i('evaluationIntervalSeconds', fallback.evaluationIntervalSeconds),
      reentryCooldownMinutes:
          i('reentryCooldownMinutes', fallback.reentryCooldownMinutes),
      oneSignalPerBar: b('oneSignalPerBar', fallback.oneSignalPerBar),
    );
  }
}
