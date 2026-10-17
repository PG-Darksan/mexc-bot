import 'package:mexc_core/mexc_core.dart';
import 'package:test/test.dart';

SignalEvaluation _signal({
  String symbol = 'TEST_USDT',
  Timeframe timeframe = Timeframe.m15,
  TradeDirection direction = TradeDirection.short,
  StrategyKind strategy = StrategyKind.classic,
  int barOpenTime = 900 * 1000,
}) => SignalEvaluation(
  symbol: symbol,
  timeframe: timeframe,
  direction: direction,
  price: 1,
  amount24: 1e7,
  rsi: 99,
  bbUpper: 0.9,
  bbLower: 0.5,
  bbMiddle: 0.7,
  ema: 0.8,
  deviation: 0.25,
  bandDeviation: 0.1,
  takeProfitPrice: 0.85,
  expectedProfitPercent: 15,
  fundingRate: 0,
  fundingIntervalHours: 8,
  barOpenTime: barOpenTime,
  strategy: strategy,
);

void main() {
  group('検知は 1 本の足につき 1 回', () {
    test('同じ足ではもう検知しない', () {
      final latch = SignalLatch();
      final first = _signal();
      expect(latch.isLatched(first), isFalse);
      latch.latch(first);
      expect(latch.isLatched(_signal()), isTrue);
    });

    test('次の足になればまた検知する', () {
      final latch = SignalLatch()..latch(_signal());
      expect(latch.isLatched(_signal(barOpenTime: 900 * 1001)), isFalse);
    });

    test('銘柄・時間軸・向き・手法が違えば別に数える', () {
      final latch = SignalLatch()..latch(_signal());
      expect(latch.isLatched(_signal(symbol: 'OTHER_USDT')), isFalse);
      expect(latch.isLatched(_signal(timeframe: Timeframe.h1)), isFalse);
      expect(
        latch.isLatched(_signal(direction: TradeDirection.long)),
        isFalse,
      );
      expect(
        latch.isLatched(_signal(strategy: StrategyKind.verified)),
        isFalse,
      );
    });

    test('確定してしばらくたった足の覚えは捨てる', () {
      const open = 900 * 1000;
      final latch = SignalLatch()..latch(_signal(barOpenTime: open));
      // 確定した直後はまだ持つ (足の切り替わりが遅れても二重に検知しない)。
      latch.prune(open + 900);
      expect(latch.length, 1);
      latch.prune(open + 900 + 3600);
      expect(latch.length, 0);
    });
  });

  group('建玉に付けた利確 / 損切り', () {
    const position = PositionInfo(
      positionId: 42,
      symbol: 'TEST_USDT',
      positionType: 1,
      openType: 1,
      state: 1,
      holdVol: 10,
      frozenVol: 0,
      closeVol: 0,
      holdAvgPrice: 2,
      openAvgPrice: 2,
      closeAvgPrice: 0,
      liquidatePrice: 0,
      im: 20,
      leverage: 1,
      realised: 0,
      profitRatio: 0,
      createTime: 0,
      updateTime: 0,
    );

    test('発動済み・取消済みのものは読まない', () {
      final active = PositionStopOrder.fromExchangeJson({
        'id': 1,
        'symbol': 'TEST_USDT',
        'positionId': 42,
        'positionType': 1,
        'takeProfitPrice': 2.5,
        'stopLossPrice': 0,
        'state': 1,
        'vol': 10,
        'updateTime': 5,
      });
      expect(active?.takeProfitPrice, 2.5);
      // 0 は「置いていない」。
      expect(active?.stopLossPrice, isNull);
      expect(
        PositionStopOrder.fromExchangeJson({'id': 2, 'state': 3}),
        isNull,
      );
    });

    test('建玉 ID が合うものを使い、何本もあれば新しい方を使う', () {
      final exit = exitOfPosition(position, const [
        PositionStopOrder(
          id: '1',
          symbol: 'TEST_USDT',
          positionId: 42,
          positionType: 1,
          takeProfitPrice: 2.4,
          stopLossPrice: 1.8,
          updateTime: 1,
        ),
        PositionStopOrder(
          id: '2',
          symbol: 'TEST_USDT',
          positionId: 42,
          positionType: 1,
          takeProfitPrice: 2.6,
          updateTime: 2,
        ),
        PositionStopOrder(
          id: '3',
          symbol: 'TEST_USDT',
          positionId: 0,
          positionType: 1,
          takeProfitPrice: 9,
          updateTime: 3,
        ),
      ]);
      expect(exit.takeProfit, 2.6);
      expect(exit.stopLoss, 1.8);
    });

    test('建玉 ID が無ければ、同じ銘柄・同じ向きのものを使う', () {
      final exit = exitOfPosition(position, const [
        PositionStopOrder(
          id: '1',
          symbol: 'TEST_USDT',
          positionId: 0,
          positionType: 1,
          takeProfitPrice: 2.4,
        ),
        PositionStopOrder(
          id: '2',
          symbol: 'TEST_USDT',
          positionId: 0,
          positionType: 2,
          takeProfitPrice: 1.5,
        ),
      ]);
      expect(exit.takeProfit, 2.4);
      expect(exit.stopLoss, isNull);
    });

    test('画面へ送る形に直しても同じ中身に戻る', () {
      final snapshot = BotSnapshot(
        running: true,
        config: const StrategyConfig(),
        wsConnected: true,
        watchedSymbolCount: 0,
        subscriptionCount: 0,
        evaluations: const [],
        positions: const [],
        closedPositions: const [],
        stopOrders: const [
          PositionStopOrder(
            id: '7',
            symbol: 'TEST_USDT',
            positionId: 42,
            positionType: 1,
            takeProfitPrice: 2.5,
            vol: 10,
            updateTime: 9,
          ),
        ],
      );
      final back = BotSnapshot.fromJson(snapshot.toJson());
      expect(back.stopOrders, hasLength(1));
      expect(back.stopOrders!.single.takeProfitPrice, 2.5);
      expect(back.stopOrders!.single.stopLossPrice, isNull);
      expect(back.stopOrders!.single.positionId, 42);
      // 古いサーバーは送ってこない。
      expect(
        BotSnapshot.fromJson(
          snapshot.toJson()..remove('stopOrders'),
        ).stopOrders,
        isNull,
      );
    });
  });
}
