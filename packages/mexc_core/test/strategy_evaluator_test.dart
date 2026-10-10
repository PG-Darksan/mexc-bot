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
    double? settleInHours,
  }) => FundingInfo(
    symbol: symbol,
    fundingRate: rate,
    collectCycleHours: cycle,
    nextSettleTime: settleInHours == null
        ? 0
        : DateTime.now().millisecondsSinceEpoch +
              (settleInHours * 3600000).round(),
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
      short: const SideConfig.short().copyWith(
        emaPeriod: 1, // EMA(1) = 直近値なので乖離が出ない。
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
      // 資金調達のフィルタは常に効くので、負担のない率を渡しておく。
      funding: funding(rate: 0.0001, cycle: 8),
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
      funding: funding(rate: 0.0001, cycle: 8),
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

    test('ロングが支払う側 (率がプラス) で負担が大きく、支払いが近ければ見送る', () {
      final result = run(
        direction: TradeDirection.long,
        fundingInfo: funding(rate: 0.002, cycle: 8, settleInHours: 1),
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
    test('支払う側で負担率が上限を超え、支払いまで 2 時間以内なら見送る', () {
      final result = run(
        fundingInfo: funding(rate: -0.002, cycle: 8, settleInHours: 1.5),
      );
      expect(result.rejectReason, RejectReason.fundingRateTooHigh);
    });

    test('負担率が上限を超えても、支払いがまだ先なら入る', () {
      final result = run(
        fundingInfo: funding(rate: -0.002, cycle: 8, settleInHours: 5),
      );
      expect(result.isTriggered, isTrue, reason: '却下: ${result.rejectReason}');
    });

    test('負担率が上限以内なら、支払いが近くても入る', () {
      final result = run(
        fundingInfo: funding(rate: -0.0005, cycle: 1, settleInHours: 0.2),
      );
      expect(result.isTriggered, isTrue, reason: '却下: ${result.rejectReason}');
    });

    test('精算の時刻が分からなければ、間隔の区切り (UTC) で求める', () {
      final info = funding(rate: -0.002, cycle: 8);
      // 07:30 UTC なら、次の精算は 08:00 UTC。
      final now = DateTime.utc(2026, 10, 5, 7, 30);
      expect(info.hoursUntilSettle(now), closeTo(0.5, 1e-9));
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

    test('フィルタは常に効く (切る設定は無い)', () {
      const config = StrategyConfig();
      expect(config.fundingFilterEnabled, isTrue);
      // 保存データで切ろうとしても効かない。
      expect(
        StrategyConfig.fromJson({'fundingFilterEnabled': false})
            .fundingFilterEnabled,
        isTrue,
      );
      // 利確を取引所へ預けるのも常に行う。
      expect(config.attachTakeProfitToOrder, isTrue);
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

  group('買い足し / 売り足しの計画', () {
    test('ロングは建値の下、ショートは建値の上に置く', () {
      final long = const SideConfig.long().copyWith(
        addOnEnabled: true,
        addOnLossPercent: 10,
        addOnBudgetPercent: 100,
      );
      final planL = AddOnPlan.compute(
        side: long,
        contract: contract(),
        entryPrice: 100,
        availableUsdt: 1000,
      )!;
      expect(planL.price, 90);
      // 1000 USDT × 1 倍 ÷ 90 = 11.1 → 11 枚。
      expect(planL.vol, 11);
      expect(planL.marginUsdt, 1000);

      final short = const SideConfig.short().copyWith(
        addOnEnabled: true,
        addOnLossPercent: 10,
        addOnBudgetPercent: 50,
      );
      final planS = AddOnPlan.compute(
        side: short,
        contract: contract(),
        entryPrice: 100,
        availableUsdt: 1000,
      )!;
      expect(planS.price, 110);
      // 500 USDT ÷ 110 = 4.5 → 4 枚。
      expect(planS.vol, 4);
      expect(planS.marginUsdt, 500);
    });

    test('含み損はレバレッジで割った値動きになる', () {
      final side = const SideConfig.long().copyWith(
        addOnEnabled: true,
        addOnLossPercent: 10,
        leverage: 2,
      );
      final plan = AddOnPlan.compute(
        side: side,
        contract: contract(),
        entryPrice: 100,
        availableUsdt: 1000,
      )!;
      // 証拠金の 10% の損 = 値動き 5%。
      expect(plan.price, 95);
      // 2 倍なので 1000 × 2 ÷ 95 = 21.05 → 21 枚。
      expect(plan.vol, 21);
    });

    test('切ってある・資金が無い・最小数量に届かないときは置かない', () {
      final on = const SideConfig.long().copyWith(addOnEnabled: true);
      expect(
        AddOnPlan.compute(
          side: const SideConfig.long(),
          contract: contract(),
          entryPrice: 100,
          availableUsdt: 1000,
        ),
        isNull,
      );
      expect(
        AddOnPlan.compute(
          side: on,
          contract: contract(),
          entryPrice: 100,
          availableUsdt: 0,
        ),
        isNull,
      );
      // 50 USDT では 90 USDT の 1 枚に届かない。
      expect(
        AddOnPlan.compute(
          side: on,
          contract: contract(),
          entryPrice: 100,
          availableUsdt: 50,
        ),
        isNull,
      );
    });

    test('建玉の記録に買い足しを持たせて往復できる', () {
      final position = ManagedPosition(
        id: 'p',
        symbol: symbol,
        timeframe: Timeframe.m15,
        direction: TradeDirection.long,
        openedAt: DateTime.now(),
        entryPrice: 100,
        vol: 2,
        contractSize: 1,
        leverage: 1,
        emaAtSignal: 95,
        deviationAtSignal: -0.05,
        takeProfitPrice: 97,
        status: ManagedPositionStatus.open,
      ).copyWith(addOnOrderId: '42', addOnPrice: 90, addOnVol: 11);
      expect(position.hasPendingAddOn, isTrue);

      final restored = ManagedPosition.fromJson(position.toJson());
      expect(restored.addOnOrderId, '42');
      expect(restored.addOnPrice, 90);
      expect(restored.addOnVol, 11);
      expect(restored.addOnFilled, isFalse);

      // 約定したら枚数と建値を取引所の値に合わせる。
      final filled = restored.copyWith(
        vol: 13,
        entryPrice: 91.5,
        addOnFilled: true,
      );
      expect(filled.hasPendingAddOn, isFalse);
      expect(filled.pnlAt(97), closeTo((97 - 91.5) * 13, 1e-9));

      // 取り消したら記録も消える。
      expect(restored.copyWith(clearAddOn: true).addOnOrderId, isNull);
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
      expect(config.short.fundingWindowHours, 2);
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
      expect(l.fundingWindowHours, s.fundingWindowHours);
      expect(l.minAmount24Usdt, s.minAmount24Usdt);
      expect(l.timeframes, s.timeframes);
      expect(l.bbPeriod, s.bbPeriod);
      expect(l.rsiPeriod, s.rsiPeriod);
      expect(l.emaPeriod, s.emaPeriod);
      expect(l.historyBars, s.historyBars);
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
        short: const SideConfig.short().copyWith(
          bbSigma: 3.5,
          rsiThreshold: 90,
          timeframes: const [Timeframe.m5, Timeframe.h1],
        ),
        long: const SideConfig.long().copyWith(
          enabled: false,
          leverage: 3,
          timeframes: const [Timeframe.h4],
        ),
      );
      final restored = StrategyConfig.fromJson(config.toJson());
      expect(restored.short.bbSigma, 3.5);
      expect(restored.short.rsiThreshold, 90);
      expect(restored.short.direction, TradeDirection.short);
      expect(restored.long.enabled, isFalse);
      expect(restored.long.leverage, 3);
      expect(restored.long.direction, TradeDirection.long);
      expect(restored.short.timeframes, [Timeframe.m5, Timeframe.h1]);
      expect(restored.long.timeframes, [Timeframe.h4]);
      // ロングを切ってあるので、集めるのはショートの足だけ。
      expect(restored.timeframes, [Timeframe.m5, Timeframe.h1]);
    });

    test('出来高と時間軸は方向ごとに持てる', () {
      final config = StrategyConfig(
        short: const SideConfig.short().copyWith(
          minAmount24Usdt: 20000000,
          timeframes: const [Timeframe.m15],
          rsiPeriod: 14,
        ),
        long: const SideConfig.long().copyWith(
          minAmount24Usdt: 3000000,
          timeframes: const [Timeframe.h4, Timeframe.d1],
          rsiPeriod: 7,
        ),
      );
      // 監視銘柄は広いほうで集めて、判定で方向ごとに落とす。
      expect(config.minAmount24Usdt, 3000000);
      expect(config.timeframes, [
        Timeframe.m15,
        Timeframe.h4,
        Timeframe.d1,
      ]);
      expect(config.validate(), isEmpty);

      final restored = StrategyConfig.fromJson(config.toJson());
      expect(restored.short.minAmount24Usdt, 20000000);
      expect(restored.short.rsiPeriod, 14);
      expect(restored.long.minAmount24Usdt, 3000000);
      expect(restored.long.timeframes, [Timeframe.h4, Timeframe.d1]);
    });

    test('出来高の下限は方向ごとに効く', () {
      // ショートだけ下限を上げ、出来高がその間に入る銘柄を出す。
      final config = StrategyConfig(
        short: const SideConfig.short().copyWith(minAmount24Usdt: 90000000),
        long: const SideConfig.long().copyWith(minAmount24Usdt: 1000000),
      );
      final result = StrategyEvaluator(config).evaluate(
        symbol: symbol,
        timeframe: Timeframe.m15,
        direction: TradeDirection.short,
        series: seriesFrom(spikeSeries()),
        contract: contract(),
        ticker: ticker(10000000),
      );
      expect(result.rejectReason, RejectReason.lowVolume);
    });

    test('時間軸が共通だった頃の保存データは両方向に写る', () {
      final old = <String, dynamic>{
        'minAmount24Usdt': 8000000.0,
        'timeframes': ['m5', 'h1'],
        'rsiPeriod': 9,
        'short': {'direction': 'short', 'rsiThreshold': 95.0},
        'long': {'direction': 'long', 'rsiThreshold': 5.0},
      };
      final config = StrategyConfig.fromJson(old);
      for (final side in [config.short, config.long]) {
        expect(side.minAmount24Usdt, 8000000.0);
        expect(side.timeframes, [Timeframe.m5, Timeframe.h1]);
        expect(side.rsiPeriod, 9);
      }
    });

    test('買い足しの設定は JSON と往復でき、おかしな値は弾く', () {
      final config = StrategyConfig(
        short: const SideConfig.short().copyWith(
          addOnEnabled: true,
          addOnLossPercent: 15,
          addOnBudgetPercent: 50,
        ),
      );
      final restored = StrategyConfig.fromJson(config.toJson());
      expect(restored.short.addOnEnabled, isTrue);
      expect(restored.short.addOnLossPercent, 15);
      expect(restored.short.addOnBudgetPercent, 50);
      // ロングは既定のまま (切ってある)。
      expect(restored.long.addOnEnabled, isFalse);
      expect(config.validate(), isEmpty);

      final bad = StrategyConfig(
        long: const SideConfig.long().copyWith(
          addOnEnabled: true,
          addOnLossPercent: 0,
          addOnBudgetPercent: 150,
        ),
      );
      expect(bad.validate().length, 2);
      // 切ってあれば値がおかしくても文句を言わない。
      expect(
        bad.copyWith(long: bad.long.copyWith(addOnEnabled: false)).validate(),
        isEmpty,
      );
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
        short: const SideConfig.short().copyWith(
          bbPeriod: 1,
          timeframes: const [],
          takeProfitFactor: 2,
          leverage: 0,
        ),
      );
      expect(config.validate(), isNotEmpty);
      expect(config.validate().length, greaterThanOrEqualTo(4));
    });
  });

  // ショート 1M・ロング 10M なら、ショートを切っていても 1M 以上を全部見る。
  test('監視銘柄の出来高の下限は、両方の向きの低いほう', () {
    final config = StrategyConfig(
      short: const SideConfig.short().copyWith(
        enabled: false,
        minAmount24Usdt: 1000000,
      ),
      long: const SideConfig.long().copyWith(minAmount24Usdt: 10000000),
    );
    expect(config.minAmount24Usdt, 1000000);
  });

  group('建てられる上限', () {
    ContractInfo contract({double maxVol = 1000, double riskBaseVol = 300}) =>
        ContractInfo(
          symbol: 'TAKE_USDT',
          baseCoin: 'TAKE',
          quoteCoin: 'USDT',
          settleCoin: 'USDT',
          contractSize: 10,
          minVol: 1,
          maxVol: maxVol,
          volUnit: 1,
          volScale: 0,
          priceUnit: 0.00001,
          priceScale: 5,
          minLeverage: 1,
          maxLeverage: 50,
          positionOpenType: 3,
          apiAllowed: true,
          state: 0,
          takerFeeRate: 0.0002,
          makerFeeRate: 0,
          futureType: 1,
          riskBaseVol: riskBaseVol,
          riskIncrVol: 50,
          riskLevelLimit: 3,
        );

    test('持てる建玉の上限は、段階の数だけ足した枚数', () {
      expect(contract().maxPositionVol, 400);
    });

    test('証拠金が上限を超えていれば、持てる最大の枚数にする', () {
      // 1000 USDT ÷ (0.2 USDT × 10) = 500 枚 → 上限の 400 枚。
      final vol = contract().volumeForMargin(
        marginUsdt: 1000,
        leverage: 1,
        price: 0.2,
      );
      expect(vol, 400);
    });

    test('1 回の注文の上限の方が小さければ、そちらに合わせる', () {
      final vol = contract(maxVol: 250).volumeForMargin(
        marginUsdt: 1000,
        leverage: 1,
        price: 0.2,
      );
      expect(vol, 250);
    });
  });

  group('σ の倍数で決める利確・損切り', () {
    StrategyConfig sigmaConfig({double tp = 3, double sl = 3}) =>
        const StrategyConfig().copyWith(
          short: const SideConfig.short().copyWith(
            exitMode: ExitMode.sigma,
            takeProfitSigma: tp,
            stopLossSigma: sl,
          ),
          long: const SideConfig.long().copyWith(
            exitMode: ExitMode.sigma,
            takeProfitSigma: tp,
            stopLossSigma: sl,
          ),
        );

    test('ロングは入値 + 3σ で利確、入値 - 3σ で損切り', () {
      final closes = spikeSeries(spike: 0.5);
      final result = run(
        config: sigmaConfig(),
        direction: TradeDirection.long,
        closes: closes,
      );
      expect(result.rejectReason, isNull, reason: '却下: ${result.rejectReason}');
      final sd = Indicators.bollinger(closes, 20, 4)!.deviation;
      expect(result.takeProfitPrice, closeTo(result.price + 3 * sd, 1e-9));
      expect(result.stopLossPrice, closeTo(result.price - 3 * sd, 1e-9));
    });

    test('ショートは入値 - σ で利確、入値 + σ で損切り', () {
      final closes = spikeSeries(spike: 1.5);
      final result = run(config: sigmaConfig(tp: 1, sl: 2), closes: closes);
      expect(result.rejectReason, isNull, reason: '却下: ${result.rejectReason}');
      final sd = Indicators.bollinger(closes, 20, 4)!.deviation;
      expect(result.takeProfitPrice, closeTo(result.price - sd, 1e-9));
      expect(result.stopLossPrice, closeTo(result.price + 2 * sd, 1e-9));
    });

    test('損切りの σ が 0 なら損切りは置かない', () {
      final result = run(config: sigmaConfig(sl: 0));
      expect(result.isTriggered, isTrue);
      expect(result.stopLossPrice, isNull);
    });

    test('ロングで損切りが 0 以下になる所なら損切りは置かない', () {
      final result = run(
        config: sigmaConfig(sl: 1000),
        direction: TradeDirection.long,
      );
      expect(result.isTriggered, isTrue);
      expect(result.stopLossPrice, isNull);
    });

    test('今までの決め方では損切りは付かない', () {
      final result = run();
      expect(result.isTriggered, isTrue);
      expect(result.stopLossPrice, isNull);
    });

    test('評価結果の損切りは JSON と往復できる', () {
      final result = run(config: sigmaConfig());
      final restored = SignalEvaluation.fromJson(result.toJson());
      expect(restored.stopLossPrice, result.stopLossPrice);
    });

    test('設定は JSON と往復でき、無い古い保存データは今までの決め方で読む', () {
      final config = sigmaConfig(tp: 2.5, sl: 1.5).copyWith(
        long: sigmaConfig().long.copyWith(maxHoldHours: 6),
      );
      final restored = StrategyConfig.fromJson(
        config.copyWith(maxOpenPositions: 7).toJson(),
      );
      expect(restored.maxOpenPositions, 7);
      expect(restored.short.exitMode, ExitMode.sigma);
      expect(restored.short.takeProfitSigma, 2.5);
      expect(restored.short.stopLossSigma, 1.5);
      expect(restored.long.maxHoldHours, 6);

      final old = const StrategyConfig().toJson();
      (old['short'] as Map).remove('exitMode');
      (old['long'] as Map).remove('exitMode');
      final legacy = StrategyConfig.fromJson(old);
      expect(legacy.short.exitMode, ExitMode.emaRatio);
      expect(legacy.long.maxHoldHours, 0);
      expect(legacy.maxOpenPositions, 0);
    });

    test('おかしな値は弾く', () {
      final bad = const SideConfig.long().copyWith(
        exitMode: ExitMode.sigma,
        takeProfitSigma: 0,
        stopLossSigma: -1,
        maxHoldHours: -1,
      );
      expect(bad.validate(), hasLength(3));
      expect(
        const StrategyConfig(maxOpenPositions: -1).validate(),
        contains(contains('同時に持つ建玉の上限')),
      );
    });

    test('検証した値に戻しても、使うか・証拠金・レバレッジと今までの手法は変えない', () {
      final before = const StrategyConfig().copyWith(
        verified: const SideConfig.verified().copyWith(
          enabled: true,
          rsiThreshold: 20,
          maxHoldHours: 3,
          leverage: 2,
          marginPercent: 7,
        ),
        verifiedMaxOpenPositions: 3,
      );
      final preset = before.withVerifiedPreset();
      expect(preset.validate(), isEmpty);
      expect(preset.verified.enabled, isTrue);
      expect(preset.verified.timeframes, [Timeframe.m15]);
      expect(preset.verified.rsiThreshold, 5);
      expect(preset.verified.maxHoldHours, 12);
      expect(preset.verifiedMaxOpenPositions, 10);
      expect(preset.verified.leverage, 2);
      expect(preset.verified.marginPercent, 7);
      expect(preset.short, same(before.short));
      expect(preset.long, same(before.long));
    });

    test('建玉の記録は最長保有時間を持って往復でき、期限が出せる', () {
      final opened = DateTime(2026, 1, 1, 9);
      final position = ManagedPosition(
        id: 'p',
        symbol: symbol,
        timeframe: Timeframe.m15,
        direction: TradeDirection.long,
        openedAt: opened,
        entryPrice: 100,
        vol: 1,
        contractSize: 1,
        leverage: 1,
        emaAtSignal: 0,
        deviationAtSignal: 0,
        takeProfitPrice: 106,
        stopLossPrice: 94,
        status: ManagedPositionStatus.open,
        maxHoldMinutes: 720,
      );
      final restored = ManagedPosition.fromJson(position.toJson());
      expect(restored.maxHoldMinutes, 720);
      expect(restored.closeDeadline, DateTime(2026, 1, 1, 21));
      // 利確を動かしても期限は残る。
      expect(restored.copyWith(takeProfitPrice: 110).maxHoldMinutes, 720);
      // 期限の無い建玉。
      expect(
        ManagedPosition.fromJson(
          (position.toJson())..remove('maxHoldMinutes'),
        ).closeDeadline,
        isNull,
      );
    });
  });

  group('検証済みの手法 (今までの手法と同時に動かす)', () {
    test('既定では切ってあり、入れると今までの手法と一緒に動く', () {
      const base = StrategyConfig();
      expect(base.verified.enabled, isFalse);
      expect(base.activeLabels, ['ショート', 'ロング']);
      final both = base.copyWith(
        verified: base.verified.copyWith(enabled: true),
      );
      expect(both.validate(), isEmpty);
      expect(both.activeLabels, ['ショート', 'ロング', '検証済みの手法']);
      expect(
        both.sideFor(StrategyKind.verified, TradeDirection.long),
        same(both.verified),
      );
      expect(
        both.sideFor(StrategyKind.classic, TradeDirection.long),
        same(both.long),
      );
      // 監視する銘柄は、検証済みの手法の出来高の下限 (1M) まで広げる。
      expect(base.minAmount24Usdt, 5000000);
      expect(both.minAmount24Usdt, 1000000);
      expect(both.timeframes, contains(Timeframe.m15));
    });

    test('今までの手法を全部切っても、検証済みの手法だけで動かせる', () {
      final only = const StrategyConfig().copyWith(
        short: const SideConfig.short().copyWith(enabled: false),
        long: const SideConfig.long().copyWith(enabled: false),
        verified: const SideConfig.verified().copyWith(enabled: true),
      );
      expect(only.validate(), isEmpty);
      expect(only.activeLabels, ['検証済みの手法']);
      expect(only.watchedSides, [same(only.verified)]);
      final none = only.copyWith(
        verified: only.verified.copyWith(enabled: false),
      );
      expect(none.validate(), contains(contains('全部切られています')));
    });

    test('値は 15 分足・-4σ・RSI 5 以下・σ 3 で利確と損切り・12 時間・同時 10 件', () {
      const v = SideConfig.verified();
      expect(v.direction, TradeDirection.long);
      expect(v.timeframes, [Timeframe.m15]);
      expect(v.bbSigma, 4);
      expect(v.rsiThreshold, 5);
      expect(v.exitMode, ExitMode.sigma);
      expect(v.takeProfitSigma, 3);
      expect(v.stopLossSigma, 3);
      expect(v.maxHoldHours, 12);
      expect(v.addOnEnabled, isFalse);
      expect(v.bandBreakoutEntryEnabled, isFalse);
      expect(v.minAmount24Usdt, 1000000);
      expect(v.marginByPercent, isTrue);
      expect(const StrategyConfig().verifiedMaxOpenPositions, 10);
    });

    test('判定はその条件で σ の利確・損切りを付け、どの手法かの印を付ける', () {
      final config = const StrategyConfig().copyWith(
        verified: const SideConfig.verified().copyWith(enabled: true),
      );
      final closes = spikeSeries(spike: 0.5);
      SignalEvaluation evaluate({SideConfig? side, StrategyKind? kind}) =>
          StrategyEvaluator(config).evaluate(
            symbol: symbol,
            timeframe: Timeframe.m15,
            direction: TradeDirection.long,
            series: seriesFrom(closes),
            contract: contract(),
            ticker: ticker(10000000),
            funding: funding(rate: -0.0001, cycle: 8),
            sideConfig: side,
            strategy: kind ?? StrategyKind.classic,
          );
      final verified = evaluate(
        side: config.verified,
        kind: StrategyKind.verified,
      );
      expect(verified.rejectReason, isNull, reason: '却下: ${verified.rejectReason}');
      expect(verified.strategy, StrategyKind.verified);
      final sd = Indicators.bollinger(closes, 20, 4)!.deviation;
      expect(verified.takeProfitPrice, closeTo(verified.price + 3 * sd, 1e-9));
      expect(verified.stopLossPrice, closeTo(verified.price - 3 * sd, 1e-9));
      expect(
        SignalEvaluation.fromJson(verified.toJson()).strategy,
        StrategyKind.verified,
      );
      // 同じ足でも、今までの手法のロングは EMA の戻りで利確し、損切りは付かない。
      final classic = evaluate();
      expect(classic.isTriggered, isTrue);
      expect(classic.strategy, StrategyKind.classic);
      expect(classic.stopLossPrice, isNull);
    });

    test('設定は JSON と往復でき、手法を分ける前の σ のロングは検証済みの手法へ移す', () {
      final config = const StrategyConfig().copyWith(
        verified: const SideConfig.verified().copyWith(
          enabled: true,
          marginPercent: 8,
        ),
        verifiedMaxOpenPositions: 4,
        long: const SideConfig.long().copyWith(
          marginByPercent: true,
          marginPercent: 25,
        ),
      );
      final restored = StrategyConfig.fromJson(config.toJson());
      expect(restored.verified.enabled, isTrue);
      expect(restored.verified.marginPercent, 8);
      expect(restored.verified.exitMode, ExitMode.sigma);
      expect(restored.verifiedMaxOpenPositions, 4);
      expect(restored.long.marginByPercent, isTrue);
      expect(restored.long.marginPercent, 25);

      // 「検証済みの設定」を入れていた頃の保存データ (検証済みの手法の欄が
      // 無く、今までの手法のロングを σ の決済にしていた)。
      final old = const StrategyConfig()
          .copyWith(
            short: const SideConfig.short().copyWith(enabled: false),
            long: const SideConfig.long().copyWith(
              exitMode: ExitMode.sigma,
              timeframes: [Timeframe.m15],
              rsiThreshold: 5,
              maxHoldHours: 12,
              marginPerTradeUsdt: 30,
            ),
          )
          .toJson()
        ..remove('verified')
        ..remove('verifiedMaxOpenPositions');
      final migrated = StrategyConfig.fromJson(old);
      expect(migrated.verified.enabled, isTrue);
      expect(migrated.verified.exitMode, ExitMode.sigma);
      expect(migrated.verified.rsiThreshold, 5);
      expect(migrated.verified.maxHoldHours, 12);
      expect(migrated.verified.marginByPercent, isFalse);
      expect(migrated.verified.marginPerTradeUsdt, 30);
      expect(migrated.long.enabled, isFalse);
      expect(migrated.long.exitMode, ExitMode.emaRatio);
      expect(migrated.validate(), isEmpty);

      // 割合の項目が無い保存データは固定額で、検証済みの手法の欄が無ければ
      // 切ったまま既定値で読む。
      final legacy = const StrategyConfig().toJson();
      (legacy['long'] as Map).remove('marginByPercent');
      legacy.remove('verified');
      final read = StrategyConfig.fromJson(legacy);
      expect(read.long.marginByPercent, isFalse);
      expect(read.verified.enabled, isFalse);
      expect(read.verified.rsiThreshold, 5);
    });

    test('建玉の記録は手法を持って往復し、古い記録は今までの手法として読む', () {
      final p = ManagedPosition(
        id: 'v',
        symbol: symbol,
        timeframe: Timeframe.m15,
        direction: TradeDirection.long,
        openedAt: DateTime(2026, 1, 1),
        entryPrice: 100,
        vol: 1,
        contractSize: 1,
        leverage: 1,
        emaAtSignal: 0,
        deviationAtSignal: 0,
        takeProfitPrice: 106,
        stopLossPrice: 94,
        status: ManagedPositionStatus.open,
        strategy: StrategyKind.verified,
      );
      expect(ManagedPosition.fromJson(p.toJson()).strategy, StrategyKind.verified);
      expect(p.copyWith(takeProfitPrice: 110).strategy, StrategyKind.verified);
      expect(
        ManagedPosition.fromJson(p.toJson()..remove('strategy')).strategy,
        StrategyKind.classic,
      );
    });
  });

  group('1 回の証拠金 (固定額か資産の割合か)', () {
    // 1 枚 = 0.2 USDT × 10 = 2 USDT (1 倍)。持てる上限は 400 枚 = 800 USDT。
    ContractInfo limited() => ContractInfo(
      symbol: 'TAKE_USDT',
      baseCoin: 'TAKE',
      quoteCoin: 'USDT',
      settleCoin: 'USDT',
      contractSize: 10,
      minVol: 1,
      maxVol: 1000,
      volUnit: 1,
      volScale: 0,
      priceUnit: 0.00001,
      priceScale: 5,
      minLeverage: 1,
      maxLeverage: 50,
      positionOpenType: 3,
      apiAllowed: true,
      state: 0,
      takerFeeRate: 0.0002,
      makerFeeRate: 0,
      futureType: 1,
      riskBaseVol: 300,
      riskIncrVol: 50,
      riskLevelLimit: 3,
    );
    final byPercent = const SideConfig.long().copyWith(
      marginByPercent: true,
      marginPercent: 10,
    );

    test('固定額ならその額', () {
      final m = EntryMargin.compute(
        side: const SideConfig.long().copyWith(marginPerTradeUsdt: 50),
        contract: limited(),
        price: 0.2,
        equityUsdt: 1000,
        availableUsdt: 1000,
      )!;
      expect(m.usdt, 50);
      expect(m.basis, isNull);
    });

    test('割合なら資産 (建玉の分も含む合計) に対する割合', () {
      final m = EntryMargin.compute(
        side: byPercent,
        contract: limited(),
        price: 0.2,
        equityUsdt: 600,
        availableUsdt: 400,
      )!;
      expect(m.usdt, closeTo(60, 1e-9));
      expect(m.basis, contains('資産 600.00 USDT の 10%'));
    });

    test('銘柄で持てる上限が資産より小さければ、上限に対する割合にする', () {
      final m = EntryMargin.compute(
        side: byPercent.copyWith(marginPercent: 25),
        contract: limited(),
        price: 0.2,
        equityUsdt: 3200,
        availableUsdt: 3200,
      )!;
      // 上限 800 USDT の 25% = 200 USDT (資産 3200 USDT の 25% の 800 ではない)。
      expect(m.usdt, closeTo(200, 1e-9));
      expect(m.basis, contains('上限'));
    });

    test('資産が分からなければ使える残高で代え、どちらも無ければ決められない', () {
      expect(
        EntryMargin.compute(
          side: byPercent,
          contract: limited(),
          price: 0.2,
          availableUsdt: 500,
        )!.usdt,
        closeTo(50, 1e-9),
      );
      expect(
        EntryMargin.compute(side: byPercent, contract: limited(), price: 0.2),
        isNull,
      );
    });

    test('割合のおかしな値は弾き、割合のときは固定額を問わない', () {
      expect(
        byPercent.copyWith(marginPercent: 0).validate(),
        contains(contains('割合')),
      );
      expect(
        byPercent.copyWith(marginPercent: 150).validate(),
        contains(contains('割合')),
      );
      expect(byPercent.copyWith(marginPerTradeUsdt: 0).validate(), isEmpty);
    });
  });
}
