import 'package:mexc_core/mexc_core.dart';
import 'package:test/test.dart';

/// サーバーからアプリへ送る状態。JSON で往復しても中身が変わらないこと。
void main() {
  final manual = PositionInfo.fromJson({
    'positionId': 7,
    'symbol': 'BTC_USDT',
    'positionType': 1,
    'state': 1,
    'holdVol': 3,
    'holdAvgPrice': 84000.5,
    'createTime': 1759500000000,
  });

  test('取引所の建玉・決済の記録・1 枚あたりの数量も送る', () {
    final snapshot = BotSnapshot(
      running: false,
      config: const StrategyConfig(),
      wsConnected: false,
      watchedSymbolCount: 0,
      subscriptionCount: 0,
      evaluations: const [],
      positions: const [],
      closedPositions: const [],
      markPrices: const {'BTC_USDT': 84100},
      exchangePositions: [manual],
      exchangeClosed: [manual],
      contractSizes: const {'BTC_USDT': 0.0001},
    );

    final restored = BotSnapshot.fromJson(snapshot.toJson());
    expect(restored.exchangePositions!.single.holdAvgPrice, 84000.5);
    expect(restored.exchangeClosed, hasLength(1));
    expect(restored.contractSizes['BTC_USDT'], 0.0001);
    expect(restored.markPrices['BTC_USDT'], 84100);
  });

  test('古いサーバーの状態には取引所の建玉が無い (null のまま読む)', () {
    final restored = BotSnapshot.fromJson({'running': true});
    expect(restored.exchangePositions, isNull);
    expect(restored.exchangeClosed, isNull);
    expect(restored.contractSizes, isEmpty);
  });
}
