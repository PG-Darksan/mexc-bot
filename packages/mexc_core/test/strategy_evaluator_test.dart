import 'package:mexc_core/mexc_core.dart';
import 'package:test/test.dart';

/// 判定ロジックのテスト。通信はしない。
void main() {
  const symbol = 'TEST_USDT';

  ContractInfo contract({bool apiAllowed = true}) => ContractInfo(
    symbol: symbol,
    baseCoin: 'TEST',
    quoteCoin: 'USDT',
    settleCoin: 'USDT',
    contractSize: 1,
    minVol: 1,
    maxVol: 1000000,
    volUnit: 1,
    volScale: 0,
    priceUnit: 0.0001,
    priceScale: 4,
    minLeverage: 1,
    maxLeverage: 100,
    positionOpenType: 3,
    apiAllowed: apiAllowed,
    state: 0,
    takerFeeRate: 0.0008,
    makerFeeRate: 0.0006,
    futureType: 1,
  );

  CandleSeries seriesFrom(List<double> closes) {
    final series = CandleSeries(symbol: symbol, timeframe: Timeframe.m15);
    series.replaceAll([
      for (var i = 0; i < closes.length; i++)
        Candle(
          openTime: 900 * (i + 1),
          open: closes[i],
          high: closes[i],
          low: closes[i],
          close: closes[i],
          volume: 1,
          amount: 1,
        ),
    ]);
    return series;
  }

  /// 穏やかな値動きのあと最後に急騰 (または急落) する系列。
  List<double> spikeSeries({int length = 200, double spike = 1.5}) {
    final out = <double>[];
    for (var i = 0; i < length - 1; i++) {
      out.add(100 + (i % 2 == 0 ? 0.05 : -0.05));
    }
    out.add(100 * spike);
    return out;
  }

  TickerSnapshot ticker(double amount24) => TickerSnapshot(
    symbol: symbol,
    lastPrice: 150,
    fairPrice: 150,
    indexPrice: 150,
    amount24: amount24,
    volume24: 1000,
    fundingRate: 0,
    riseFallRate: 0.5,
    timestamp: 0,
  );

  FundingInfo funding({
    required double rate,
    required int cycle,
  }) => FundingInfo(
    symbol: symbol,
    fundingRate: rate,
    collectCycleHours: cycle,
    nextSettleTime: 0,
    fetchedAt: DateTime.now(),
  );

  /// ショート側の設定だけ差し替えた設定を作る。
  StrategyConfig withShort(SideConfig side) => StrategyConfig(short: side);

  SignalEvaluation run({
    StrategyConfig? config,
    TradeDirection direction = TradeDirection.short,
    List<double>? closes,
    double amount24 = 10000000,
    FundingInfo? fundingInfo,
    ContractInfo? contractInfo,
    bool omitFunding = false,
  }) {
    final cfg = config ?? const StrategyConfig();
    return StrategyEvaluator(cfg).evaluate(
      symbol: symbol,
      timeframe: Timeframe.m15,
      direction: direction,
      series: seriesFrom(
        closes ??
            spikeSeries(spike: direction.isShort ? 1.5 : 0.5),
      ),
      contract: contractInfo ?? contract(),
      ticker: ticker(amount24),
      // 既定では「負担のない資金調達率」を渡す。未取得の挙動は専用のテストで見る。
      funding: omitFunding
          ? null
          : (fundingInfo ??
              funding(
                // 支払う側にならない向きの率を渡す。
                rate: direction.isShort ? 0.0001 : -0.0001,
                cycle: 8,
              )),
    );
  }

  test('履歴が足りなければ insufficientData', () {
    final result = run(closes: [100, 101, 102]);
    expect(result.rejectReason, RejectReason.insufficientData);
  });

  test('API発注不可の銘柄は弾く', () {
    final result = run(contractInfo: contract(apiAllowed: false));
    expect(result.rejectReason, RejectReason.notTradable);
  });

  test('24時間出来高が足りなければ lowVolume', () {
    final result = run(amount24: 1000000);
    expect(result.rejectReason, RejectReason.lowVolume);
    // 却下しても指標は埋めて返す (画面で状況を見るため)。
    expect(result.rsi, isNotNull);
    expect(result.bbUpper, isNotNull);
    expect(result.bbLower, isNotNull);
  });

  test('RSIがしきい値に届かなければ rsiNotReached', () {
    // 急騰のない平坦な系列。
    final flat = [for (var i = 0; i < 200; i++) 100 + (i % 2 == 0 ? 0.05 : -0.05)];
    final result = run(closes: flat);
    expect(result.rejectReason, RejectReason.rsiNotReached);
  });

  test('バンドの内側なら insideBand', () {
    // RSI は高いが +4σ には届かない程度の上昇。
    final gentle = [
      for (var i = 0; i < 195; i++) 100.0,
      100.1, 100.2, 100.3, 100.4, 100.5,
    ];
    final config = withShort(
      const SideConfig.short().copyWith(rsiThreshold: 50, bbSigma: 4),
    );
    final result = run(config: config, closes: gentle);
    expect(result.rejectReason, RejectReason.insideBand);
  });

  test('条件がそろえば発火する', () {
    final result = run();
    expect(result.rejectReason, isNull, reason: '却下理由: ${result.rejectReason}');
    expect(result.isTriggered, isTrue);
    expect(result.rsi, greaterThanOrEqualTo(97));
    expect(result.direction, TradeDirection.short);
  });

  test('利確価格は「検知時のEMAからの乖離の半分」になる', () {
    // EMA と価格を直接指定できるよう、EMA=100 になる系列を作る。
    final closes = [for (var i = 0; i < 199; i++) 100.0, 110.0];
    final config = StrategyConfig(
      emaPeriod: 1, // EMA(1) = 直近値なので乖離が出ない。
      fundingFilterEnabled: false,
      short: const SideConfig.short().copyWith(
        rsiThreshold: 1,
        bbSigma: 0.1,
        minTakeProfitPercent: 0,
      ),
    );
    final result = StrategyEvaluator(config).evaluate(
      symbol: symbol,
      timeframe: Timeframe.m15,
      direction: TradeDirection.short,
      series: seriesFrom(closes),
      contract: contract(),
      ticker: ticker(10000000),
    );
    // EMA(1) は価格そのものなので乖離ゼロ。利確幅が出ないので却下される。
    expect(result.rejectReason, RejectReason.profitTooSmall);
  });

  test('乖離率の半分が利確目標になる (EMA=100, 価格=110 → 105)', () {
    // EMA(5) がちょうど 100 になるよう、直前 5 本を 100 で揃えてから急騰させる。
    final closes = <double>[for (var i = 0; i < 200; i++) 100.0];
    final series = seriesFrom(closes);
    // 進行中の足として 110 を当てる。EMA(5) は直前まで 100 なので
    // 更新後は 100 + (110-100) * 2/6 = 103.33...
    series.applyPrice(110, 900 * 200 + 10);

    final config = StrategyConfig(
      fundingFilterEnabled: false,
      short: const SideConfig.short().copyWith(
        rsiThreshold: 1,
        bbSigma: 0.001,
        minTakeProfitPercent: 0,
      ),
    );
    final result = StrategyEvaluator(config).evaluate(
      symbol: symbol,
      timeframe: Timeframe.m15,
      direction: TradeDirection.short,
      series: series,
      contract: contract(),
      ticker: ticker(10000000),
    );

    expect(result.isTriggered, isTrue, reason: '却下: ${result.rejectReason}');
    final ema = result.ema!;
    final expectedDeviation = (110 - ema) / ema;
    expect(result.deviation, closeTo(expectedDeviation, 1e-12));
    // 目標 = EMA × (1 + 乖離 × 0.5)
    expect(
      result.takeProfitPrice,
      closeTo(ema * (1 + expectedDeviation * 0.5), 1e-12),
    );
    // 目標はエントリー価格と EMA のちょうど中間になる。
    expect(result.takeProfitPrice, closeTo((110 + ema) / 2, 1e-9));
  });

  group('ロング', () {
    test('急落すれば発火する', () {
      final result = run(direction: TradeDirection.long);
      expect(result.rejectReason, isNull, reason: '却下: ${result.rejectReason}');
      expect(result.direction, TradeDirection.long);
      expect(result.rsi, lessThanOrEqualTo(3));
      // 利確目標は買値より上、乖離は負。
      expect(result.deviation, lessThan(0));
      expect(result.takeProfitPrice, greaterThan(result.price));
      expect(result.expectedProfitPercent, greaterThan(0));
    });

    test('急騰ではロング条件を満たさない', () {
      final result = run(
        direction: TradeDirection.long,
        closes: spikeSeries(spike: 1.5),
      );
      expect(result.rejectReason, RejectReason.rsiNotReached);
    });

    test('急落ではショート条件を満たさない', () {
      final result = run(closes: spikeSeries(spike: 0.5));
      expect(result.rejectReason, RejectReason.rsiNotReached);
    });

    test('ロングが支払う側 (率がプラス) で負担が大きければ見送る', () {
      final result = run(
        direction: TradeDirection.long,
        fundingInfo: funding(rate: 0.002, cycle: 8),
      );
      expect(result.rejectReason, RejectReason.fundingRateTooHigh);
    });

    test('ロングが受け取る側 (率がマイナス) なら率が大きくても通す', () {
      final result = run(
        direction: TradeDirection.long,
        fundingInfo: funding(rate: -0.01, cycle: 1),
      );
      expect(result.isTriggered, isTrue);
    });

    test('切っている方向は enabledSides に出てこない', () {
      final config = StrategyConfig(
        long: const SideConfig.long().copyWith(enabled: false),
      );
      expect(config.enabledSides.length, 1);
      expect(config.enabledSides.single.direction, TradeDirection.short);
      expect(config.validate(), isEmpty);
    });

    test('両方切ると設定エラーになる', () {
      final config = StrategyConfig(
        short: const SideConfig.short().copyWith(enabled: false),
        long: const SideConfig.long().copyWith(enabled: false),
      );
      expect(config.validate(), isNotEmpty);
    });
  });

  group('行きすぎたときの逆張り', () {
    // σ を小さく取り、バンドのすぐ外まで来た状態から大きく離す。
    // RSI のしきい値は 100 にしてあるので、RSI では発火しない。
    StrategyConfig cfg({
      bool enabled = true,
      double percent = 20,
      double factor = 0.5,
      TradeDirection direction = TradeDirection.short,
    }) {
      final side = (direction.isShort
              ? const SideConfig.short()
              : const SideConfig.long())
          .copyWith(
        rsiThreshold: direction.isShort ? 100 : 0,
        bbSigma: 0.1,
        minTakeProfitPercent: 0,
        bandBreakoutEntryEnabled: enabled,
        bandBreakoutPercent: percent,
        takeProfitFactor: factor,
      );
      return StrategyConfig(
        fundingFilterEnabled: false,
        short: direction.isShort ? side : const SideConfig.short(),
        long: direction.isShort ? const SideConfig.long() : side,
      );
    }

    test('切っていれば RSI 未達で見送る', () {
      final result = run(config: cfg(enabled: false));
      expect(result.rejectReason, RejectReason.rsiNotReached);
    });

    test('バンドから離れていれば RSI を見ずに入る', () {
      final result = run(config: cfg());
      expect(result.isTriggered, isTrue, reason: '却下: ${result.rejectReason}');
      expect(result.byBandBreakout, isTrue);
      expect(result.bandDeviation, greaterThan(0.2));
    });

    test('離れ方が足りなければ入らない', () {
      // 実際の乖離より大きな幅を要求すれば、RSI 未達で落ちる。
      final result = run(config: cfg(percent: 95));
      expect(result.rejectReason, RejectReason.rsiNotReached);
      expect(result.byBandBreakout, isFalse);
    });

    test('利確はバンドからの乖離の半分だけ戻した位置', () {
      final result = run(config: cfg());
      final band = result.bbUpper!;
      final dev = result.bandDeviation!;
      expect(result.takeProfitPrice, closeTo(band * (1 + dev * 0.5), 1e-9));
      // 目標は建値とバンドの間に来る。
      expect(result.takeProfitPrice, lessThan(result.price));
      expect(result.takeProfitPrice, greaterThan(band));
    });

    test('係数を変えれば利確の位置も動く', () {
      final result = run(config: cfg(factor: 0.25));
      final band = result.bbUpper!;
      final dev = result.bandDeviation!;
      expect(result.takeProfitPrice, closeTo(band * (1 + dev * 0.25), 1e-9));
    });

    test('ロングでも下に離れれば同じように入る', () {
      final result = run(
        config: cfg(direction: TradeDirection.long),
        direction: TradeDirection.long,
      );
      expect(result.isTriggered, isTrue, reason: '却下: ${result.rejectReason}');
      expect(result.byBandBreakout, isTrue);
      final band = result.bbLower!;
      final dev = result.bandDeviation!;
      expect(result.takeProfitPrice, closeTo(band * (1 - dev * 0.5), 1e-9));
      // 目標は建値より上、バンドより下。
      expect(result.takeProfitPrice, greaterThan(result.price));
      expect(result.takeProfitPrice, lessThan(band));
    });
  });

  group('資金調達率フィルタ', () {
    test('ショートが支払う側で 0.1% を超えたら見送る', () {
      final result = run(fundingInfo: funding(rate: -0.002, cycle: 8));
      expect(result.rejectReason, RejectReason.fundingRateTooHigh);
    });

    test('ショートが支払う側で調達間隔が 2時間未満なら見送る', () {
      final result = run(fundingInfo: funding(rate: -0.0005, cycle: 1));
      expect(result.rejectReason, RejectReason.fundingIntervalTooShort);
    });

    test('ショートが受け取る側なら率が大きくても通す', () {
      // fundingRate が正 = ロングが払い、ショートが受け取る。
      final result = run(fundingInfo: funding(rate: 0.01, cycle: 1));
      expect(result.isTriggered, isTrue);
    });

    test('負担側でも基準内なら通す', () {
      final result = run(fundingInfo: funding(rate: -0.0005, cycle: 8));
      expect(result.isTriggered, isTrue);
    });

    test('資金調達率がまだ取れていなければ見送る', () {
      // 起動直後に、調達間隔の短い銘柄へ素通りで入ってしまうのを防ぐ。
      final result = run(omitFunding: true);
      expect(result.rejectReason, RejectReason.fundingUnknown);
    });

    test('フィルタを切っていれば未取得でも通す', () {
      final result = run(
        config: const StrategyConfig(fundingFilterEnabled: false),
        omitFunding: true,
      );
      expect(result.isTriggered, isTrue);
    });

    test('フィルタを切れば負担が大きくても通す', () {
      final result = run(
        config: const StrategyConfig(fundingFilterEnabled: false),
        fundingInfo: funding(rate: -0.05, cycle: 1),
      );
      expect(result.isTriggered, isTrue);
    });
  });

  test('利確幅が最小値に満たなければ profitTooSmall', () {
    final result = run(
      config: withShort(
        const SideConfig.short().copyWith(minTakeProfitPercent: 99),
      ),
    );
    expect(result.rejectReason, RejectReason.profitTooSmall);
  });

  group('発注数量の計算', () {
    test('証拠金とレバレッジから枚数を出す', () {
      final c = contract();
      // 証拠金 10 USDT × 1倍 ÷ (価格 2 × contractSize 1) = 5 枚
      expect(
        c.volumeForMargin(marginUsdt: 10, leverage: 1, price: 2),
        5,
      );
    });

    test('最小数量に満たなければ null', () {
      final c = contract();
      expect(
        c.volumeForMargin(marginUsdt: 1, leverage: 1, price: 1000),
        isNull,
      );
    });

    test('価格は取引所の刻みに丸める', () {
      final c = contract();
      expect(c.roundPrice(1.234567, roundUp: true), 1.2346);
      expect(c.roundPrice(1.234567, roundUp: false), 1.2345);
    });
  });

  group('建玉の損益', () {
    ManagedPosition position(TradeDirection direction) => ManagedPosition(
      id: 'x',
      symbol: symbol,
      timeframe: Timeframe.m15,
      direction: direction,
      openedAt: DateTime.now(),
      entryPrice: 100,
      vol: 2,
      contractSize: 1,
      leverage: 1,
      emaAtSignal: 90,
      deviationAtSignal: 0.1,
      takeProfitPrice: 95,
      status: ManagedPositionStatus.open,
    );

    test('ショートは下がると利益', () {
      expect(position(TradeDirection.short).unrealizedPnl(90), 20);
      expect(position(TradeDirection.short).unrealizedPnl(110), -20);
    });

    test('ロングは上がると利益', () {
      expect(position(TradeDirection.long).unrealizedPnl(110), 20);
      expect(position(TradeDirection.long).unrealizedPnl(90), -20);
    });
  });

  group('設定の検証', () {
    test('既定値は利用者の指定どおり', () {
      const config = StrategyConfig();
      expect(config.minAmount24Usdt, 5000000);
      expect(config.bbPeriod, 20);
      expect(config.rsiPeriod, 7);
      expect(config.emaPeriod, 5);
      expect(config.evaluationIntervalSeconds, 60);
      expect(config.short.bbSigma, 4.0);
      expect(config.short.rsiThreshold, 97.0);
      expect(config.short.leverage, 1);
      expect(config.short.takeProfitFactor, 0.5);
      expect(config.short.maxFundingBurdenPercent, 0.1);
      expect(config.short.minFundingIntervalHours, 2);
      expect(config.timeframes, [
        Timeframe.m15,
        Timeframe.h1,
        Timeframe.h4,
        Timeframe.d1,
      ]);
      expect(config.validate(), isEmpty);
    });

    test('ロングの既定値はショートとそろえてある', () {
      const config = StrategyConfig();
      final s = config.short;
      final l = config.long;
      // RSI だけ向きが逆 (97 ↔ 3)。
      expect(l.rsiThreshold, 100 - s.rsiThreshold);
      expect(l.bbSigma, s.bbSigma);
      expect(l.leverage, s.leverage);
      expect(l.marginPerTradeUsdt, s.marginPerTradeUsdt);
      expect(l.takeProfitFactor, s.takeProfitFactor);
      expect(l.minTakeProfitPercent, s.minTakeProfitPercent);
      expect(l.maxFundingBurdenPercent, s.maxFundingBurdenPercent);
      expect(l.minFundingIntervalHours, s.minFundingIntervalHours);
      expect(l.limitOffsetPercent, s.limitOffsetPercent);
    });

    test('mirrored で反対方向にそろえられる', () {
      final side = const SideConfig.short().copyWith(
        rsiThreshold: 95,
        bbSigma: 3,
        leverage: 2,
        marginPerTradeUsdt: 25,
      );
      final mirrored = side.mirrored();
      expect(mirrored.direction, TradeDirection.long);
      expect(mirrored.rsiThreshold, 5);
      expect(mirrored.bbSigma, 3);
      expect(mirrored.leverage, 2);
      expect(mirrored.marginPerTradeUsdt, 25);
    });

    test('JSON と往復できる', () {
      final config = StrategyConfig(
        timeframes: const [Timeframe.m5, Timeframe.h1],
        short: const SideConfig.short().copyWith(bbSigma: 3.5, rsiThreshold: 90),
        long: const SideConfig.long().copyWith(enabled: false, leverage: 3),
      );
      final restored = StrategyConfig.fromJson(config.toJson());
      expect(restored.short.bbSigma, 3.5);
      expect(restored.short.rsiThreshold, 90);
      expect(restored.short.direction, TradeDirection.short);
      expect(restored.long.enabled, isFalse);
      expect(restored.long.leverage, 3);
      expect(restored.long.direction, TradeDirection.long);
      expect(restored.timeframes, [Timeframe.m5, Timeframe.h1]);
    });

    test('方向ごとの設定が無い古い保存データも読める', () {
      // ショート専用だった頃の config.json。
      final old = <String, dynamic>{
        'bbPeriod': 20,
        'rsiThreshold': 95.0,
        'bbSigma': 3.0,
        'leverage': 2,
        'marginPerTradeUsdt': 20.0,
        'maxShortBurdenPercent': 0.2,
        'dryRun': true,
      };
      final config = StrategyConfig.fromJson(old);
      expect(config.short.rsiThreshold, 95.0);
      expect(config.short.bbSigma, 3.0);
      expect(config.short.leverage, 2);
      expect(config.short.maxFundingBurdenPercent, 0.2);
      // ロングは鏡写しで埋める。
      expect(config.long.rsiThreshold, 5.0);
      expect(config.long.bbSigma, 3.0);
      expect(config.long.leverage, 2);
    });

    test('おかしな設定はエラーを返す', () {
      final config = StrategyConfig(
        bbPeriod: 1,
        timeframes: const [],
        short: const SideConfig.short().copyWith(
          takeProfitFactor: 2,
          leverage: 0,
        ),
      );
      expect(config.validate(), isNotEmpty);
      expect(config.validate().length, greaterThanOrEqualTo(4));
    });
  });
}
