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
///
/// 入り方は 2 通りある。
/// * 通常 … RSI がしきい値に届き、かつ σ のバンドを抜けたとき。
/// * 行きすぎ … バンドから [SideConfig.bandBreakoutPercent] 以上離れたとき。
///   ここまで離れると RSI は張り付いて動かないので、RSI を見ずに入る。
class StrategyEvaluator {
  const StrategyEvaluator(this.config);

  final StrategyConfig config;

  /// 指標を出すのに必要な最低本数。
  int get requiredBars {
    final need = [
      config.bbPeriod,
      config.rsiPeriod + 1,
      config.emaPeriod,
    ].reduce((a, b) => a > b ? a : b);
    // Wilder 平滑は再帰なので、しきい値判定に使うには十分な助走が要る。
    return need + config.rsiPeriod * 5;
  }

  SignalEvaluation evaluate({
    required String symbol,
    required Timeframe timeframe,
    required TradeDirection direction,
    required CandleSeries series,
    required ContractInfo contract,
    TickerSnapshot? ticker,
    FundingInfo? funding,
  }) {
    final side = config.sideOf(direction);
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
      expectedProfitPercent: profitPercent,
      fundingRate: funding?.fundingRate,
      fundingIntervalHours: funding?.collectCycleHours,
      barOpenTime: barOpenTime,
      rejectReason: reason,
    );

    if (closes.length < requiredBars) {
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
    final rsi = Indicators.rsi(closes, config.rsiPeriod);
    final bb = Indicators.bollinger(closes, config.bbPeriod, side.bbSigma);
    final ema = Indicators.ema(closes, config.emaPeriod);

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

    // 利確の基準は入り方で変える。
    // * 行きすぎで入ったとき … バンドまでの戻りを基準にする。
    // * 通常 … 検知した瞬間の EMA までの戻りを基準にする。
    // どちらも「乖離率 × 係数」だけ戻した位置に置く。
    double? takeProfit;
    if (farBeyondBand) {
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
      profitPercent: profitPercent,
      price: price,
    );

    if (amount24 < config.minAmount24Usdt) {
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
    if (config.fundingFilterEnabled) {
      // まだ取れていない銘柄は、素通りさせずに見送る。
      // 起動直後に調達間隔の短い銘柄へ入ってしまうのを防ぐ。
      if (funding == null) {
        return reject(RejectReason.fundingUnknown);
      }
      if (funding.paysFor(direction)) {
        final burdenPercent = funding.burdenRateFor(direction) * 100;
        if (burdenPercent > side.maxFundingBurdenPercent) {
          return reject(RejectReason.fundingRateTooHigh);
        }
        if (funding.collectCycleHours < side.minFundingIntervalHours) {
          return reject(RejectReason.fundingIntervalTooShort);
        }
      }
    }

    if (takeProfit == null) {
      return reject(RejectReason.profitTooSmall);
    }
    // 通常の入り方では、乖離の向きが方向と合っていないと
    // 利確目標が逆側に出てしまう。行きすぎで入るときはバンド基準なので要らない。
    if (!farBeyondBand) {
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
      profitPercent: profitPercent,
      price: price,
    );
  }
}
