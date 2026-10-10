import '../indicators/candle_series.dart';
import '../indicators/indicators.dart';
import '../models/contract_info.dart';
import '../models/market_data.dart';
import '../models/signal.dart';
import '../models/strategy_config.dart';
import '../models/timeframe.dart';

/// 売買条件の判定だけを行う純粋な部品。
///
/// 通信も発注もしないので単体テストしやすい。進行中の足を含めた
/// 終値の配列をそのまま受け取り、毎回すべて計算し直す。
/// ショートとロングは条件が左右対称なので、同じ手順を方向で切り替えて使う。
/// 出来高の下限・時間軸・指標の期間も方向ごとなので、判定はすべて
/// [SideConfig] の値を見る。
///
/// 入り方は 2 通りある。
/// * 通常 … RSI がしきい値に届き、かつ σ のバンドを抜けたとき。
/// * 行きすぎ … バンドから [SideConfig.bandBreakoutPercent] 以上離れたとき。
///   ここまで離れると RSI は張り付いて動かないので、RSI を見ずに入る。
class StrategyEvaluator {
  const StrategyEvaluator(this.config);

  final StrategyConfig config;

  /// 指標を出すのに必要な最低本数。期間は方向ごとなので方向で変わる。
  int requiredBarsFor(TradeDirection direction) =>
      config.sideOf(direction).requiredBars;

  /// [sideConfig] を渡すと、その条件で判定する (検証済みの手法など)。
  /// 渡さなければ今までの手法の [direction] の条件。[strategy] は結果に付ける印。
  SignalEvaluation evaluate({
    required String symbol,
    required Timeframe timeframe,
    required TradeDirection direction,
    required CandleSeries series,
    required ContractInfo contract,
    TickerSnapshot? ticker,
    FundingInfo? funding,
    DateTime? now,
    SideConfig? sideConfig,
    StrategyKind strategy = StrategyKind.classic,
  }) {
    final side = sideConfig ?? config.sideOf(direction);
    final closes = series.closes;
    final barOpenTime = series.last?.openTime ?? 0;
    final amount24 = ticker?.amount24 ?? 0;

    SignalEvaluation build({
      RejectReason? reason,
      double? rsi,
      BollingerPoint? bb,
      double? ema,
      double? deviation,
      double? bandDeviation,
      bool byBandBreakout = false,
      double? takeProfit,
      double? stopLoss,
      double? profitPercent,
      double price = 0,
    }) => SignalEvaluation(
      symbol: symbol,
      timeframe: timeframe,
      direction: direction,
      price: price,
      amount24: amount24,
      rsi: rsi,
      bbUpper: bb?.upper,
      bbLower: bb?.lower,
      bbMiddle: bb?.middle,
      ema: ema,
      deviation: deviation,
      bandDeviation: bandDeviation,
      byBandBreakout: byBandBreakout,
      takeProfitPrice: takeProfit,
      stopLossPrice: stopLoss,
      expectedProfitPercent: profitPercent,
      fundingRate: funding?.fundingRate,
      fundingIntervalHours: funding?.collectCycleHours,
      barOpenTime: barOpenTime,
      rejectReason: reason,
      strategy: strategy,
    );

    if (closes.length < side.requiredBars) {
      return build(reason: RejectReason.insufficientData);
    }
    final price = closes.last;
    if (price <= 0) {
      return build(reason: RejectReason.insufficientData, price: price);
    }
    if (!contract.isTradable) {
      return build(reason: RejectReason.notTradable, price: price);
    }

    // 指標は却下する場合も全部埋めて返す。画面で「あと何が足りないか」を見たいので。
    final rsi = Indicators.rsi(closes, side.rsiPeriod);
    final bb = Indicators.bollinger(closes, side.bbPeriod, side.bbSigma);
    final ema = Indicators.ema(closes, side.emaPeriod);

    // 判定に使うバンド (ショートは +σ、ロングは -σ) と、そこからの乖離率。
    // バンドの外側を正にして、方向によらず同じ向きで扱う。
    final boundary = bb == null
        ? null
        : (direction.isShort ? bb.upper : bb.lower);
    double? bandDeviation;
    if (boundary != null && boundary > 0) {
      bandDeviation = direction.isShort
          ? (price - boundary) / boundary
          : (boundary - price) / boundary;
    }

    // バンドから大きく離れていれば、RSI を見ずに逆張りで入る。
    final farBeyondBand = side.bandBreakoutEntryEnabled &&
        bandDeviation != null &&
        bandDeviation >= side.bandBreakoutPercent / 100;

    final deviation = (ema != null && ema > 0) ? (price - ema) / ema : null;

    // 利確の基準は決め方と入り方で変える。
    // * σ の倍数 … 入値から σ × 倍率だけ戻した所。損切りも σ × 倍率だけ外へ置く。
    // * EMA の戻り (今まで) … 行きすぎで入ったときはバンドまで、通常は検知した
    //   瞬間の EMA までの戻りを基準に、「乖離率 × 係数」だけ戻した位置に置く。
    double? takeProfit;
    double? stopLoss;
    final bySigma = side.exitMode == ExitMode.sigma;
    if (bySigma) {
      final sd = bb?.deviation;
      if (sd != null && sd > 0) {
        final tp = direction.isShort
            ? price - side.takeProfitSigma * sd
            : price + side.takeProfitSigma * sd;
        if (tp > 0) takeProfit = tp;
        if (side.stopLossSigma > 0) {
          final sl = direction.isShort
              ? price + side.stopLossSigma * sd
              : price - side.stopLossSigma * sd;
          // ロングで σ が大き過ぎて 0 以下になるときは置けない。
          if (sl > 0) stopLoss = sl;
        }
      }
    } else if (farBeyondBand) {
      takeProfit = boundary! *
          (1 +
              (direction.isShort ? bandDeviation : -bandDeviation) *
                  side.takeProfitFactor);
    } else if (ema != null && ema > 0 && deviation != null) {
      takeProfit = ema * (1 + deviation * side.takeProfitFactor);
    }

    double? profitPercent;
    if (takeProfit != null) {
      profitPercent = direction.isShort
          ? (price - takeProfit) / price * 100
          : (takeProfit - price) / price * 100;
    }

    SignalEvaluation reject(RejectReason reason) => build(
      reason: reason,
      rsi: rsi,
      bb: bb,
      ema: ema,
      deviation: deviation,
      bandDeviation: bandDeviation,
      byBandBreakout: farBeyondBand,
      takeProfit: takeProfit,
      stopLoss: stopLoss,
      profitPercent: profitPercent,
      price: price,
    );

    if (amount24 < side.minAmount24Usdt) {
      return reject(RejectReason.lowVolume);
    }

    // RSI は、ショートなら上に振り切ったとき、ロングなら下に振り切ったとき。
    // バンドから大きく離れているときは見ない。
    if (!farBeyondBand) {
      final rsiReached = rsi != null &&
          (direction.isShort
              ? rsi >= side.rsiThreshold
              : rsi <= side.rsiThreshold);
      if (!rsiReached) {
        return reject(RejectReason.rsiNotReached);
      }
    }

    // バンドは、ショートなら +σ の上、ロングなら -σ の下に抜けたとき。
    final bandBroken = bb != null &&
        (direction.isShort ? price > bb.upper : price < bb.lower);
    if (!bandBroken) {
      return reject(RejectReason.insideBand);
    }

    // 資金調達率のフィルタ。その方向が「支払う側」のときだけ効かせる。
    // まだ取れていない銘柄は、素通りさせずに見送る。
    // 起動直後に調達間隔の短い銘柄へ入ってしまうのを防ぐ。
    if (funding == null) {
      return reject(RejectReason.fundingUnknown);
    }
    // 負担率が上限を超え、かつ次の支払いまでが指定時間以内なら見送る。
    // 支払いがまだ先なら、その前に利確できる見込みがあるので入る。
    if (funding.paysFor(direction)) {
      final burdenPercent = funding.burdenRateFor(direction) * 100;
      if (burdenPercent > side.maxFundingBurdenPercent &&
          funding.hoursUntilSettle(now ?? DateTime.now()) <=
              side.fundingWindowHours) {
        return reject(RejectReason.fundingRateTooHigh);
      }
    }

    if (takeProfit == null) {
      return reject(RejectReason.profitTooSmall);
    }
    // EMA の戻りで決める通常の入り方では、乖離の向きが方向と合っていないと
    // 利確目標が逆側に出てしまう。行きすぎ (バンド基準) と σ の倍数では要らない。
    if (!farBeyondBand && !bySigma) {
      final deviationOk = deviation != null &&
          (direction.isShort ? deviation > 0 : deviation < 0);
      if (!deviationOk) {
        return reject(RejectReason.profitTooSmall);
      }
    }
    if (profitPercent == null || profitPercent < side.minTakeProfitPercent) {
      return reject(RejectReason.profitTooSmall);
    }

    return build(
      rsi: rsi,
      bb: bb,
      ema: ema,
      deviation: deviation,
      bandDeviation: bandDeviation,
      byBandBreakout: farBeyondBand,
      takeProfit: takeProfit,
      stopLoss: stopLoss,
      profitPercent: profitPercent,
      price: price,
    );
  }
}
