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

    double? deviation;
    double? takeProfit;
    double? profitPercent;
    if (ema != null && ema > 0) {
      deviation = (price - ema) / ema;
      // 利確目標は EMA へ向かって乖離のぶんだけ戻したところ。
      // ショートは price より下、ロングは price より上に出る。
      takeProfit = ema * (1 + deviation * side.takeProfitFactor);
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
      takeProfit: takeProfit,
      profitPercent: profitPercent,
      price: price,
    );

    if (amount24 < config.minAmount24Usdt) {
      return reject(RejectReason.lowVolume);
    }

    // RSI は、ショートなら上に振り切ったとき、ロングなら下に振り切ったとき。
    final rsiReached = rsi != null &&
        (direction.isShort ? rsi >= side.rsiThreshold : rsi <= side.rsiThreshold);
    if (!rsiReached) {
      return reject(RejectReason.rsiNotReached);
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

    // 乖離の向きが方向と合っていなければ、利確目標が逆側に出てしまう。
    final deviationOk = deviation != null &&
        (direction.isShort ? deviation > 0 : deviation < 0);
    if (!deviationOk || takeProfit == null) {
      return reject(RejectReason.profitTooSmall);
    }
    if (profitPercent == null || profitPercent < side.minTakeProfitPercent) {
      return reject(RejectReason.profitTooSmall);
    }

    return build(
      rsi: rsi,
      bb: bb,
      ema: ema,
      deviation: deviation,
      takeProfit: takeProfit,
      profitPercent: profitPercent,
      price: price,
    );
  }
}
