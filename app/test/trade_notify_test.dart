import 'package:flutter_test/flutter_test.dart';
import 'package:mexc_bot_app/src/notify/trade_notifier.dart';
import 'package:mexc_bot_app/src/state/app_state.dart';
import 'package:mexc_core/mexc_core.dart';

ManagedPosition _position(
  String id, {
  ManagedPositionStatus status = ManagedPositionStatus.open,
}) => ManagedPosition(
  id: id,
  symbol: 'TAKE_USDT',
  timeframe: Timeframe.d1,
  direction: TradeDirection.short,
  openedAt: DateTime(2026, 9, 23, 19, 42, 51),
  entryPrice: 0.19486,
  vol: 5,
  contractSize: 1,
  leverage: 1,
  emaAtSignal: 0.15,
  deviationAtSignal: 0.3,
  takeProfitPrice: 0.14945,
  status: status,
);

BotSnapshot _snapshot({
  List<ManagedPosition> open = const [],
  List<ManagedPosition> closed = const [],
}) => BotSnapshot(
  running: true,
  config: const StrategyConfig(),
  wsConnected: true,
  watchedSymbolCount: 0,
  subscriptionCount: 0,
  evaluations: const [],
  positions: open,
  closedPositions: closed,
);

void main() {
  group('建てた / 決済したことを拾う', () {
    test('繋いだ直後にある建玉は知らせない', () {
      final tracker = PositionChangeTracker();
      final first = tracker.update(
        _snapshot(open: [_position('a')], closed: [_position('b')]),
      );
      expect(first.opened, isEmpty);
      expect(first.closed, isEmpty);
    });

    test('新しく建った建玉と、決済に移った建玉を返す', () {
      final tracker = PositionChangeTracker()
        ..update(_snapshot(open: [_position('a')]));

      final opened = tracker.update(
        _snapshot(open: [_position('a'), _position('c')]),
      );
      expect(opened.opened.map((p) => p.id), ['c']);
      expect(opened.closed, isEmpty);

      final closed = tracker.update(
        _snapshot(
          open: [_position('c')],
          closed: [_position('a', status: ManagedPositionStatus.closed)],
        ),
      );
      expect(closed.opened, isEmpty);
      expect(closed.closed.map((p) => p.id), ['a']);

      // 同じ状態がもう一度届いても、二度は知らせない。
      final again = tracker.update(
        _snapshot(
          open: [_position('c')],
          closed: [_position('a', status: ManagedPositionStatus.closed)],
        ),
      );
      expect(again.opened, isEmpty);
      expect(again.closed, isEmpty);
    });

    test('繋ぎ先を変えたら、覚え直す', () {
      final tracker = PositionChangeTracker()
        ..update(_snapshot())
        ..reset();
      final first = tracker.update(_snapshot(open: [_position('x')]));
      expect(first.opened, isEmpty);
    });
  });

  test('通知の文面', () {
    final opened = openedMessage(_position('a'));
    expect(opened.title, '建てました: TAKEUSDT 売り (ショート)');
    expect(opened.body, contains('利確 0.14945'));

    final closed = closedMessage(
      _position('a', status: ManagedPositionStatus.closed).copyWith(
        closePrice: 0.14945,
        realizedPnl: 2.2636,
        note: '利確',
      ),
    );
    expect(closed.title, '決済しました: TAKEUSDT +2.2636 USDT');
    expect(closed.body, endsWith('(利確)'));
  });

  test('取引所の建玉のうち、ボットが管理していないものだけを拾う', () {
    PositionInfo exchange(String symbol, int type) => PositionInfo.fromJson({
      'positionId': symbol.hashCode,
      'symbol': symbol,
      'positionType': type,
      'state': 1,
      'holdVol': 1,
    });
    final foreign = exchangeOnlyPositions(
      [_position('a')], // TAKE_USDT のショート
      [
        exchange('TAKE_USDT', 2), // ボットのもの
        exchange('TAKE_USDT', 1), // 同じ銘柄でも向きが違えば別
        exchange('BTC_USDT', 1), // 手で建てたもの
      ],
    );
    expect(foreign.map((p) => '${p.symbol}/${p.positionType}'), [
      'TAKE_USDT/1',
      'BTC_USDT/1',
    ]);
  });
}
