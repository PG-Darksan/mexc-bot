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

/// 売買の手法。今までの手法と検証済みの手法は、同時に動かせる。
enum StrategyKind {
  /// BB の σ と RSI で逆張りに入り、EMA への戻りで利確する (今までの手法)。
  classic('今までの手法'),

  /// 1 年分の検証で前半・後半とも黒字だった手法。15 分足 -4σ・RSI 5 以下で
  /// 買い、σ の倍数で利確と損切りを置く。
  verified('検証済みの手法');

  const StrategyKind(this.label);

  final String label;

  static StrategyKind fromName(String? name) => StrategyKind.values
      .firstWhere((e) => e.name == name, orElse: () => StrategyKind.classic);
}

/// 利確 (と損切り) の決め方。
enum ExitMode {
  /// 検知した瞬間の EMA からの乖離に係数を掛けた分だけ戻した所で利確する。
  /// 損切りは置かない (今までの方法)。
  emaRatio('EMA の戻り'),

  /// 入値から BB の σ の倍数だけ離した所に利確と損切りを置く。
  /// σ は検知した瞬間の BB(20) の標準偏差。
  sigma('σ の倍数');

  const ExitMode(this.label);

  final String label;

  static ExitMode fromName(String? name) => ExitMode.values
      .firstWhere((e) => e.name == name, orElse: () => ExitMode.emaRatio);
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
    this.marginByPercent = false,
    this.marginPercent = 10.0,
    this.takeProfitFactor = 0.5,
    this.minTakeProfitPercent = 0.3,
    this.maxFundingBurdenPercent = 0.1,
    this.fundingWindowHours = 2,
    this.bandBreakoutEntryEnabled = true,
    this.bandBreakoutPercent = 20.0,
    this.addOnEnabled = false,
    this.addOnLossPercent = 10.0,
    this.addOnBudgetPercent = 100.0,
    this.exitMode = ExitMode.emaRatio,
    this.takeProfitSigma = 3.0,
    this.stopLossSigma = 3.0,
    this.maxHoldHours = 0,
  });

  /// ショートの既定値 (利用者の指定どおりの条件)。
  const SideConfig.short() : this(direction: TradeDirection.short);

  /// ロングの既定値。ショートを鏡写しにした値で揃えてある。
  const SideConfig.long()
      : this(direction: TradeDirection.long, rsiThreshold: 3.0);

  /// 検証済みの手法の値 (research/report.md の 5.2)。
  ///
  /// ロングだけ。15 分足で -4σ に触れ、RSI(7) が 5 以下なら買う。利確は
  /// 入値 +3σ、損切りは入値 -3σ、12 時間で決まらなければ成行で閉じる。
  /// 買い足しと、RSI を待たない飛び出しの入り方は使わない (検証していない)。
  /// 証拠金は資産の 5% (同時 10 件まで持っても資産の半分)。
  const SideConfig.verified()
      : this(
          direction: TradeDirection.long,
          enabled: false,
          minAmount24Usdt: 1000000,
          timeframes: const [Timeframe.m15],
          rsiThreshold: 5.0,
          bbSigma: 4.0,
          bandBreakoutEntryEnabled: false,
          exitMode: ExitMode.sigma,
          takeProfitSigma: 3.0,
          stopLossSigma: 3.0,
          maxHoldHours: 12,
          marginByPercent: true,
          marginPercent: 5.0,
        );

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

  /// 1 回のエントリーに使う証拠金 (USDT)。[marginByPercent] が切ってあるときに使う。
  final double marginPerTradeUsdt;

  /// 1 回の証拠金を、資産の割合 ([marginPercent]) で決めるか。
  ///
  /// 切っていれば [marginPerTradeUsdt] の固定額で建てる。
  final bool marginByPercent;

  /// [marginByPercent] のとき、1 回の証拠金にする資産の割合 (%)。
  ///
  /// 資産は口座の USDT の合計 (建玉の証拠金や含み損益も含む)。その銘柄で
  /// 持てる建玉の上限が資産より小さい時は、その上限に対する割合にする
  /// (取引画面の「何 %」と同じ。後で買い足せる余地を残すため)。
  /// 使える残高を超える分は建てない。
  final double marginPercent;

  /// 検知時の EMA からの乖離率に掛ける係数。既定 0.5。
  final double takeProfitFactor;

  /// 利確幅がこの%未満なら見送る。API経由の往復手数料 (0.16%前後) 負け対策。
  final double minTakeProfitPercent;

  /// 資金調達を「支払う側」のとき、この%を超えていたら見送る。
  final double maxFundingBurdenPercent;

  /// 資金調達を支払う側で、負担率が上限を超え、かつ次の支払いまでが
  /// この時間以内なら見送る。まだ先なら、支払いの前に利確できる見込みがある。
  final int fundingWindowHours;

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

  // ── 利確・損切りの決め方 ─────────────────────────────────────
  /// 利確 (と損切り) の決め方。既定は今までどおりの [ExitMode.emaRatio]。
  final ExitMode exitMode;

  /// [ExitMode.sigma] のとき、入値から利確までの距離 (σ の何倍か)。
  final double takeProfitSigma;

  /// [ExitMode.sigma] のとき、入値から損切りまでの距離 (σ の何倍か)。0 なら置かない。
  final double stopLossSigma;

  /// 建ててからこの時間が過ぎたら成行で決済する。0 なら時間では決済しない。
  final int maxHoldHours;

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
    marginByPercent: marginByPercent,
    marginPercent: marginPercent,
    takeProfitFactor: takeProfitFactor,
    minTakeProfitPercent: minTakeProfitPercent,
    maxFundingBurdenPercent: maxFundingBurdenPercent,
    fundingWindowHours: fundingWindowHours,
    bandBreakoutEntryEnabled: bandBreakoutEntryEnabled,
    bandBreakoutPercent: bandBreakoutPercent,
    addOnEnabled: addOnEnabled,
    addOnLossPercent: addOnLossPercent,
    addOnBudgetPercent: addOnBudgetPercent,
    exitMode: exitMode,
    takeProfitSigma: takeProfitSigma,
    stopLossSigma: stopLossSigma,
    maxHoldHours: maxHoldHours,
  );

  /// この方向の設定に問題があれば日本語で返す。[name] はメッセージの頭に
  /// 付ける名前 (既定は向きの名前)。
  List<String> validate({String? name}) {
    final errors = <String>[];
    name ??= direction.label;
    if (timeframes.isEmpty) {
      errors.add('$name: 時間軸が 1 つも選ばれていません。');
    }
    if (minAmount24Usdt < 0) {
      errors.add('$name: 24h出来高の下限は 0 以上にして下さい。');
    }
    if (bbPeriod < 2) errors.add('$name: BB期間は 2 以上にして下さい。');
    if (rsiPeriod < 2) errors.add('$name: RSI期間は 2 以上にして下さい。');
    if (emaPeriod < 1) errors.add('$name: EMA期間は 1 以上にして下さい。');
    if (historyBars < requiredBars) {
      errors.add('$name: 保持する足が少な過ぎます。$requiredBars 本以上にして下さい。');
    }
    if (bbSigma <= 0) errors.add('$name: σ倍率は 0 より大きい値にして下さい。');
    if (rsiThreshold <= 0 || rsiThreshold > 100) {
      errors.add('$name: RSI閾値は 0 より大きく 100 以下にして下さい。');
    }
    if (leverage < 1) errors.add('$name: レバレッジは 1 以上にして下さい。');
    if (marginByPercent) {
      if (marginPercent <= 0 || marginPercent > 100) {
        errors.add('$name: 証拠金の資産に対する割合は 0 より大きく 100 以下にして下さい。');
      }
    } else if (marginPerTradeUsdt <= 0) {
      errors.add('$name: 1回あたりの証拠金は 0 より大きい値にして下さい。');
    }
    if (takeProfitFactor <= 0 || takeProfitFactor >= 1) {
      errors.add('$name: 利確係数は 0 より大きく 1 未満にして下さい。');
    }
    if (bandBreakoutEntryEnabled && bandBreakoutPercent <= 0) {
      errors.add('$name: 行き過ぎの基準 (σ のバンドから離れた割合) は 0 より大きい値にして下さい。');
    }
    if (direction.isLong &&
        bandBreakoutEntryEnabled &&
        bandBreakoutPercent >= 100) {
      errors.add('$name: 行き過ぎの基準 (σ のバンドから離れた割合) は 100% 未満にして下さい。');
    }
    if (addOnEnabled) {
      if (addOnLossPercent <= 0) {
        errors.add('$name: 買い足しを入れる含み損は 0 より大きい値にして下さい。');
      }
      if (direction.isLong && addOnLossPercent / leverage >= 100) {
        errors.add('$name: 買い足しの含み損 ÷ レバレッジ は 100% 未満にして下さい。');
      }
      if (addOnBudgetPercent <= 0 || addOnBudgetPercent > 100) {
        errors.add('$name: 買い足しに使う残り資金の割合は 0 より大きく 100 以下にして下さい。');
      }
    }
    if (exitMode == ExitMode.sigma) {
      if (takeProfitSigma <= 0) {
        errors.add('$name: 利確までの σ は 0 より大きい値にして下さい。');
      }
      if (stopLossSigma < 0) {
        errors.add('$name: 損切りまでの σ は 0 以上にして下さい (0 で置かない)。');
      }
    }
    if (maxHoldHours < 0) {
      errors.add('$name: 最長保有時間は 0 以上にして下さい (0 で時間では決済しない)。');
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
    bool? marginByPercent,
    double? marginPercent,
    double? takeProfitFactor,
    double? minTakeProfitPercent,
    double? maxFundingBurdenPercent,
    int? fundingWindowHours,
    bool? bandBreakoutEntryEnabled,
    double? bandBreakoutPercent,
    bool? addOnEnabled,
    double? addOnLossPercent,
    double? addOnBudgetPercent,
    ExitMode? exitMode,
    double? takeProfitSigma,
    double? stopLossSigma,
    int? maxHoldHours,
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
    marginByPercent: marginByPercent ?? this.marginByPercent,
    marginPercent: marginPercent ?? this.marginPercent,
    takeProfitFactor: takeProfitFactor ?? this.takeProfitFactor,
    minTakeProfitPercent: minTakeProfitPercent ?? this.minTakeProfitPercent,
    maxFundingBurdenPercent:
        maxFundingBurdenPercent ?? this.maxFundingBurdenPercent,
    fundingWindowHours:
        fundingWindowHours ?? this.fundingWindowHours,
    bandBreakoutEntryEnabled:
        bandBreakoutEntryEnabled ?? this.bandBreakoutEntryEnabled,
    bandBreakoutPercent: bandBreakoutPercent ?? this.bandBreakoutPercent,
    addOnEnabled: addOnEnabled ?? this.addOnEnabled,
    addOnLossPercent: addOnLossPercent ?? this.addOnLossPercent,
    addOnBudgetPercent: addOnBudgetPercent ?? this.addOnBudgetPercent,
    exitMode: exitMode ?? this.exitMode,
    takeProfitSigma: takeProfitSigma ?? this.takeProfitSigma,
    stopLossSigma: stopLossSigma ?? this.stopLossSigma,
    maxHoldHours: maxHoldHours ?? this.maxHoldHours,
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
    'marginByPercent': marginByPercent,
    'marginPercent': marginPercent,
    'takeProfitFactor': takeProfitFactor,
    'minTakeProfitPercent': minTakeProfitPercent,
    'maxFundingBurdenPercent': maxFundingBurdenPercent,
    'fundingWindowHours': fundingWindowHours,
    'bandBreakoutEntryEnabled': bandBreakoutEntryEnabled,
    'bandBreakoutPercent': bandBreakoutPercent,
    'addOnEnabled': addOnEnabled,
    'addOnLossPercent': addOnLossPercent,
    'addOnBudgetPercent': addOnBudgetPercent,
    'exitMode': exitMode.name,
    'takeProfitSigma': takeProfitSigma,
    'stopLossSigma': stopLossSigma,
    'maxHoldHours': maxHoldHours,
  };

  /// [defaults] は保存データに無い項目に入れる値 (既定は向きごとの既定値)。
  factory SideConfig.fromJson(
    Map<String, dynamic> json, {
    required TradeDirection direction,
    SideConfig? defaults,
  }) {
    final fallback = defaults ??
        (direction.isShort ? const SideConfig.short() : const SideConfig.long());
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
      // 割合で決める項目が入る前の保存データは、今までどおり固定額で読む。
      marginByPercent: b('marginByPercent', fallback.marginByPercent),
      marginPercent: d('marginPercent', fallback.marginPercent),
      takeProfitFactor: d('takeProfitFactor', fallback.takeProfitFactor),
      minTakeProfitPercent:
          d('minTakeProfitPercent', fallback.minTakeProfitPercent),
      maxFundingBurdenPercent: d(
        'maxFundingBurdenPercent',
        // 旧形式 (ショートだけの頃) のキーも拾う。
        d('maxShortBurdenPercent', fallback.maxFundingBurdenPercent),
      ),
      // 以前は「調達間隔の下限」(minFundingIntervalHours) だった。
      fundingWindowHours: i(
        'fundingWindowHours',
        i('minFundingIntervalHours', fallback.fundingWindowHours),
      ),
      bandBreakoutEntryEnabled:
          b('bandBreakoutEntryEnabled', fallback.bandBreakoutEntryEnabled),
      bandBreakoutPercent:
          d('bandBreakoutPercent', fallback.bandBreakoutPercent),
      addOnEnabled: b('addOnEnabled', fallback.addOnEnabled),
      addOnLossPercent: d('addOnLossPercent', fallback.addOnLossPercent),
      addOnBudgetPercent: d('addOnBudgetPercent', fallback.addOnBudgetPercent),
      // 無い保存データ (σ の決済が入る前のもの) は今までどおりの決め方で読む。
      exitMode: json.containsKey('exitMode')
          ? ExitMode.fromName(json['exitMode'] as String?)
          : fallback.exitMode,
      takeProfitSigma: d('takeProfitSigma', fallback.takeProfitSigma),
      stopLossSigma: d('stopLossSigma', fallback.stopLossSigma),
      maxHoldHours: i('maxHoldHours', fallback.maxHoldHours),
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
    this.verified = const SideConfig.verified(),
    this.verifiedMaxOpenPositions = 10,
    this.evaluationIntervalSeconds = 60,
    this.reentryCooldownMinutes = 60,
    this.maxOpenPositions = 0,
  });

  // ── 今までの手法 (方向ごとの条件) ─────────────────────────────
  final SideConfig short;
  final SideConfig long;

  // ── 検証済みの手法 ──────────────────────────────────────────
  /// 検証済みの手法の条件 (ロングだけ・σ の倍数で利確と損切り)。
  ///
  /// 使うかどうかは [SideConfig.enabled] で決める。今までの手法 ([short] /
  /// [long]) と同時に動かせる。同じ銘柄に両方から重ねて建てることはしない
  /// (一方向モードでは同じ銘柄の建玉が 1 つにまとまるため)。
  final SideConfig verified;

  /// 検証済みの手法で同時に持つ建玉の上限。0 なら上限なし。
  ///
  /// 全体の上限 [maxOpenPositions] とは別に、この手法で建てた物だけを数える。
  /// 相場全体の急落で、多くの銘柄を一度に買わないため (検証は 10 件まで)。
  final int verifiedMaxOpenPositions;

  // ── 運用 ────────────────────────────────────────────────────
  /// 判定の実行間隔 (秒)。既定 60 秒。進行中の足も含めて毎回評価する。
  final int evaluationIntervalSeconds;

  /// 決済後、同じ銘柄に再エントリーするまでの待ち時間 (分)。
  final int reentryCooldownMinutes;

  /// 同時に持つ建玉の上限 (手で建てたものも数える)。0 なら上限なし。
  ///
  /// 相場全体が急落すると、多くの銘柄が同時に条件を満たす。上限が無いと
  /// その全部を一度に買ってしまうので、資金に合わせて抑える。
  final int maxOpenPositions;

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

  /// 今までの手法の、その向きの条件。
  SideConfig sideOf(TradeDirection direction) =>
      direction.isShort ? short : long;

  /// その手法・向きで建てるときの条件。
  SideConfig sideFor(StrategyKind kind, TradeDirection direction) =>
      kind == StrategyKind.verified ? verified : sideOf(direction);

  /// 今までの手法で新規建てを行う方向。両方切っていれば空。
  List<SideConfig> get enabledSides =>
      [short, long].where((s) => s.enabled).toList(growable: false);

  /// 新規建てに使う (手法, 条件) の組。今までの手法の入っている向きと、
  /// 入っていれば検証済みの手法。
  List<(StrategyKind, SideConfig)> get activeSides => [
    for (final s in enabledSides) (StrategyKind.classic, s),
    if (verified.enabled) (StrategyKind.verified, verified),
  ];

  /// 動かしている手法の名前 (画面やログに出す)。何も無ければ空。
  List<String> get activeLabels => [
    for (final (kind, side) in activeSides)
      kind == StrategyKind.verified ? kind.label : side.direction.label,
  ];

  /// 銘柄と足を集めるときに見る条件。
  ///
  /// 全部切っていても画面には出したいので、その場合は今までの手法の両方向を見る。
  List<SideConfig> get watchedSides {
    final on = [for (final (_, side) in activeSides) side];
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

  /// 監視銘柄を選ぶときの出来高の下限。両方の向きの下限のうち低いほう。
  ///
  /// 切っている向きの下限も含める (ショート 1M・ロング 10M なら 1M 以上を
  /// 全部見る)。ここで広く集めてから、方向ごとの下限で判定時に落とす。
  /// 検証済みの手法は、使っているときだけ含める。
  double get minAmount24Usdt => [
    short.minAmount24Usdt,
    long.minAmount24Usdt,
    if (verified.enabled) verified.minAmount24Usdt,
  ].reduce(math.min);

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
      errors.add('判定間隔は 5 秒以上にして下さい。');
    }
    if (!short.enabled && !long.enabled && !verified.enabled) {
      errors.add(
        '今までの手法のショート・ロングと、検証済みの手法が全部切られています。'
        '少なくとも 1 つ入れて下さい。',
      );
    }
    if (maxOpenPositions < 0) {
      errors.add('同時に持つ建玉の上限は 0 以上にして下さい (0 で上限なし)。');
    }
    if (verifiedMaxOpenPositions < 0) {
      errors.add('検証済みの手法の同時に持つ上限は 0 以上にして下さい (0 で上限なし)。');
    }
    errors.addAll(short.validate());
    errors.addAll(long.validate());
    // 使っていない手法の値は、建てるときに使わないので問わない。
    if (verified.enabled) {
      errors.addAll(verified.validate(name: StrategyKind.verified.label));
      if (verified.direction.isShort) {
        errors.add('検証済みの手法はロングだけです。');
      }
    }
    return errors;
  }

  StrategyConfig copyWith({
    SideConfig? short,
    SideConfig? long,
    SideConfig? verified,
    int? verifiedMaxOpenPositions,
    int? evaluationIntervalSeconds,
    int? reentryCooldownMinutes,
    int? maxOpenPositions,
  }) => StrategyConfig(
    short: short ?? this.short,
    long: long ?? this.long,
    verified: verified ?? this.verified,
    verifiedMaxOpenPositions:
        verifiedMaxOpenPositions ?? this.verifiedMaxOpenPositions,
    evaluationIntervalSeconds:
        evaluationIntervalSeconds ?? this.evaluationIntervalSeconds,
    reentryCooldownMinutes:
        reentryCooldownMinutes ?? this.reentryCooldownMinutes,
    maxOpenPositions: maxOpenPositions ?? this.maxOpenPositions,
  );

  /// 片方向ぶんだけ差し替える。
  StrategyConfig withSide(SideConfig side) => side.direction.isShort
      ? copyWith(short: side)
      : copyWith(long: side);

  /// 検証済みの手法の条件を、1 年分の検証で前半・後半とも黒字だった値に戻す
  /// (research/report.md の 5.2。[SideConfig.verified] の値)。
  ///
  /// 使うかどうか・証拠金 (固定額か割合か・その値)・レバレッジ・資金調達の
  /// 見送りは今の値を残す。今までの手法には触らない。
  StrategyConfig withVerifiedPreset() {
    const preset = SideConfig.verified();
    return copyWith(
      verified: preset.copyWith(
        enabled: verified.enabled,
        leverage: verified.leverage,
        marginPerTradeUsdt: verified.marginPerTradeUsdt,
        marginByPercent: verified.marginByPercent,
        marginPercent: verified.marginPercent,
        maxFundingBurdenPercent: verified.maxFundingBurdenPercent,
        fundingWindowHours: verified.fundingWindowHours,
      ),
      verifiedMaxOpenPositions: 10,
    );
  }

  Map<String, dynamic> toJson() => {
    'short': short.toJson(),
    'long': long.toJson(),
    'verified': verified.toJson(),
    'verifiedMaxOpenPositions': verifiedMaxOpenPositions,
    'evaluationIntervalSeconds': evaluationIntervalSeconds,
    'reentryCooldownMinutes': reentryCooldownMinutes,
    'maxOpenPositions': maxOpenPositions,
  };

  factory StrategyConfig.fromJson(Map<String, dynamic> json) {
    const fallback = StrategyConfig();
    int i(String k, int f) => (json[k] as num?)?.toInt() ?? f;
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
    var shortSide =
        SideConfig.fromJson(shortJson, direction: TradeDirection.short);
    final longJson = m('long');
    var longSide = longJson == null
        ? shortSide.mirrored()
        : SideConfig.fromJson(
            {...shared, ...longJson},
            direction: TradeDirection.long,
          );

    final verifiedJson = m('verified');
    var verifiedSide = verifiedJson == null
        ? const SideConfig.verified()
        : SideConfig.fromJson(
            verifiedJson,
            direction: TradeDirection.long,
            defaults: const SideConfig.verified(),
          );
    if (verifiedJson == null) {
      // 手法を分ける前の保存データ: 「検証済みの設定」を入れると、今までの
      // 手法のロングを σ の倍数の決済にしていた。それを検証済みの手法へ移し、
      // 今までの手法は EMA の戻りの決済に戻して切る (中身を変えずに引き継ぐ)。
      if (longSide.exitMode == ExitMode.sigma) {
        verifiedSide = longSide.copyWith(
          addOnEnabled: false,
          bandBreakoutEntryEnabled: false,
        );
        longSide = longSide.copyWith(exitMode: ExitMode.emaRatio, enabled: false);
      }
      if (shortSide.exitMode == ExitMode.sigma) {
        shortSide =
            shortSide.copyWith(exitMode: ExitMode.emaRatio, enabled: false);
      }
    }

    return StrategyConfig(
      short: shortSide,
      long: longSide,
      verified: verifiedSide,
      verifiedMaxOpenPositions:
          i('verifiedMaxOpenPositions', fallback.verifiedMaxOpenPositions),
      evaluationIntervalSeconds:
          i('evaluationIntervalSeconds', fallback.evaluationIntervalSeconds),
      reentryCooldownMinutes:
          i('reentryCooldownMinutes', fallback.reentryCooldownMinutes),
      maxOpenPositions: i('maxOpenPositions', fallback.maxOpenPositions),
    );
  }
}
