import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mexc_core/mexc_core.dart';
import 'package:test/test.dart';

http.Response _ok(Object? data) =>
    http.Response(jsonEncode({'success': true, 'code': 0, 'data': data}), 200);

/// 取引所の代わり。受け取った要求を残し、決めた返事を返す。通信はしない。
class _FakeExchange {
  final List<http.Request> requests = [];
  double lastPrice = 2.0;
  double available = 1000;
  List<Map<String, dynamic>> openPositions = [];
  List<Map<String, dynamic>> planOrders = [];
  List<Map<String, dynamic>> openOrders = [];

  static const Map<String, dynamic> contract = {
    'symbol': 'TEST_USDT',
    'baseCoin': 'TEST',
    'quoteCoin': 'USDT',
    'settleCoin': 'USDT',
    'futureType': 1,
    'apiAllowed': true,
    'state': 0,
    'contractSize': 1,
    'minVol': 1,
    'maxVol': 1000000,
    'volUnit': 1,
    'volScale': 0,
    'priceUnit': 0.001,
    'priceScale': 3,
    'minLeverage': 1,
    'maxLeverage': 50,
    'takerFeeRate': 0.0008,
  };

  late final MockClient client = MockClient((req) async {
    requests.add(req);
    final path = req.url.path;
    return switch (path) {
      '/api/v1/contract/detail' => _ok([contract]),
      '/api/v1/contract/ticker' => _ok([
        {'symbol': 'TEST_USDT', 'lastPrice': lastPrice, 'amount24': 1e9},
      ]),
      '/api/v1/private/account/assets' => _ok([
        {'currency': 'USDT', 'availableBalance': available, 'equity': available},
      ]),
      '/api/v1/private/position/change_leverage' => _ok(null),
      '/api/v1/private/order/create' => _ok({'orderId': '111', 'ts': 1}),
      '/api/v1/private/planorder/place' => _ok('222'),
      '/api/v1/private/planorder/list/orders' => _ok(planOrders),
      '/api/v1/private/position/open_positions' => _ok(openPositions),
      '/api/v1/private/position/list/history_positions' => _ok(const []),
      '/api/v1/private/stoporder/place' => _ok(null),
      '/api/v1/private/planorder/cancel' => _ok(null),
      '/api/v1/private/order/cancel' => _ok(null),
      _ when path.startsWith('/api/v1/private/order/list/open_orders') =>
        _ok(openOrders),
      _ => http.Response('not found', 404),
    };
  });

  /// [path] へ最後に送った POST の中身。
  dynamic bodyOf(String path) =>
      jsonDecode(requests.lastWhere((r) => r.url.path == path).body);

  int countOf(String path) => requests.where((r) => r.url.path == path).length;
}

BotEngine _engine(_FakeExchange exchange) => BotEngine(
  config: const StrategyConfig(),
  rest: MexcRestClient(
    apiKey: 'key',
    apiSecret: 'secret',
    httpClient: exchange.client,
  ),
);

void main() {
  group('手で出す注文の中身', () {
    test('値段の前後がおかしいものは出さない', () {
      const long = ManualOrderRequest(
        symbol: 'TEST_USDT',
        direction: TradeDirection.long,
        kind: ManualOrderKind.limit,
        marginUsdt: 10,
        leverage: 2,
        price: 2,
        takeProfitPrice: 1.9,
        stopLossPrice: 2.1,
      );
      final errors = long.validate(lastPrice: 2.05);
      expect(errors, contains(contains('利確は入値')));
      expect(errors, contains(contains('損切りは入値')));

      const shortTrigger = ManualOrderRequest(
        symbol: 'TEST_USDT',
        direction: TradeDirection.short,
        kind: ManualOrderKind.trigger,
        marginUsdt: 10,
        leverage: 2,
        triggerPrice: 2.5,
        takeProfitPrice: 2.2,
        stopLossPrice: 2.7,
      );
      expect(shortTrigger.validate(lastPrice: 2), isEmpty);

      const noPrice = ManualOrderRequest(
        symbol: 'TEST_USDT',
        direction: TradeDirection.long,
        kind: ManualOrderKind.trigger,
        triggerExecution: TriggerExecution.limit,
        marginUsdt: 0,
        leverage: 2,
        triggerPrice: 2.5,
      );
      final e2 = noPrice.validate(lastPrice: 2);
      expect(e2, contains(contains('証拠金')));
      expect(e2, contains(contains('指値の値段')));
    });

    test('発動の向きは、いまの値段より上か下かで決まる', () {
      expect(ManualOrderRequest.triggerTypeFor(2.5, 2.0), 1);
      expect(ManualOrderRequest.triggerTypeFor(1.5, 2.0), 2);
    });

    test('送ったものと同じ中身に戻せる', () {
      const r = ManualOrderRequest(
        symbol: 'TEST_USDT',
        direction: TradeDirection.short,
        kind: ManualOrderKind.trigger,
        triggerExecution: TriggerExecution.limit,
        marginUsdt: 12.5,
        leverage: 3,
        price: 2.4,
        triggerPrice: 2.5,
        takeProfitPrice: 2.1,
      );
      final back = ManualOrderRequest.fromJson(r.toJson());
      expect(back.toJson(), r.toJson());
    });
  });

  group('サーバーが取引所へ出す注文', () {
    test('成行のロングは、利確と損切りを付けて 1 回で出す', () async {
      final ex = _FakeExchange();
      final engine = _engine(ex);
      final text = await engine.placeManualOrder(
        const ManualOrderRequest(
          symbol: 'TEST_USDT',
          direction: TradeDirection.long,
          kind: ManualOrderKind.market,
          marginUsdt: 100,
          leverage: 5,
          takeProfitPrice: 2.2,
          stopLossPrice: 1.9,
        ),
      );
      final body = ex.bodyOf('/api/v1/private/order/create') as Map;
      expect(body['side'], 1);
      expect(body['type'], 5);
      expect(body['vol'], 250); // 100 USDT × 5 倍 ÷ 2.0
      expect(body['leverage'], 5);
      expect(body['takeProfitPrice'], 2.2);
      expect(body['stopLossPrice'], 1.9);
      expect(body['positionMode'], 2);
      expect(body['externalOid'], startsWith('man'));
      expect(ex.countOf('/api/v1/private/order/create'), 1);
      expect(text, contains('250 枚'));
      await engine.dispose();
    });

    test('指値のショートは、売りに有利な側へ刻みを丸める', () async {
      final ex = _FakeExchange();
      final engine = _engine(ex);
      await engine.placeManualOrder(
        const ManualOrderRequest(
          symbol: 'TEST_USDT',
          direction: TradeDirection.short,
          kind: ManualOrderKind.limit,
          marginUsdt: 50,
          leverage: 2,
          price: 2.1234,
        ),
      );
      final body = ex.bodyOf('/api/v1/private/order/create') as Map;
      expect(body['side'], 3);
      expect(body['type'], 1);
      expect(body['price'], 2.124);
      expect(body['vol'], 47); // 100 ÷ 2.124 = 47.08…
      expect(body.containsKey('takeProfitPrice'), isFalse);
      await engine.dispose();
    });

    test('証拠金は使える残高を超えない分にする', () async {
      final ex = _FakeExchange()..available = 50;
      final engine = _engine(ex);
      await engine.placeManualOrder(
        const ManualOrderRequest(
          symbol: 'TEST_USDT',
          direction: TradeDirection.long,
          kind: ManualOrderKind.market,
          marginUsdt: 100,
          leverage: 2,
        ),
      );
      final body = ex.bodyOf('/api/v1/private/order/create') as Map;
      // 50 × 0.99 × 2 ÷ 2.0 = 49.5 → 49 枚
      expect(body['vol'], 49);
      await engine.dispose();
    });

    test('条件付きは取引所のトリガー注文で出し、利確 / 損切りは建ったあとに置く', () async {
      final ex = _FakeExchange();
      final engine = _engine(ex);
      await engine.placeManualOrder(
        const ManualOrderRequest(
          symbol: 'TEST_USDT',
          direction: TradeDirection.long,
          kind: ManualOrderKind.trigger,
          marginUsdt: 100,
          leverage: 2,
          triggerPrice: 2.5,
          takeProfitPrice: 2.8,
          stopLossPrice: 2.3,
        ),
      );
      final body = ex.bodyOf('/api/v1/private/planorder/place') as Map;
      expect(body['triggerPrice'], 2.5);
      expect(body['triggerType'], 1); // いま 2.0 より上なので「以上で発動」
      expect(body['orderType'], 5);
      expect(body.containsKey('price'), isFalse);
      expect(body['side'], 1);
      expect(body['vol'], 80); // 200 ÷ 2.5
      expect(body['executeCycle'], 2);
      expect(engine.snapshot.pendingExits, hasLength(1));

      // まだ発動していない間は置かない。
      ex.planOrders = [
        {
          'id': '222',
          'symbol': 'TEST_USDT',
          'side': 1,
          'vol': 80,
          'triggerPrice': 2.5,
          'triggerType': 1,
          'orderType': 5,
          'state': 1,
        },
      ];
      await engine.refreshAccount();
      expect(ex.countOf('/api/v1/private/stoporder/place'), 0);
      expect(engine.snapshot.openOrders, hasLength(1));
      expect(engine.snapshot.openOrders!.single.kind, ExchangeOrderKind.trigger);

      // 発動して建玉ができたら、建玉全体に利確 / 損切りを置く。
      ex.planOrders = [];
      ex.openPositions = [
        {
          'positionId': 9,
          'symbol': 'TEST_USDT',
          'positionType': 1,
          'openType': 1,
          'state': 1,
          'holdVol': 80,
          'holdAvgPrice': 2.5,
        },
      ];
      await engine.refreshAccount();
      final stop = ex.bodyOf('/api/v1/private/stoporder/place') as Map;
      expect(stop['positionId'], 9);
      expect(stop['vol'], 80);
      expect(stop['takeProfitPrice'], 2.8);
      expect(stop['stopLossPrice'], 2.3);
      expect(engine.snapshot.pendingExits, isEmpty);
      await engine.dispose();
    });

    test('前からある建玉には、取り消された条件付き注文の利確 / 損切りを付けない', () async {
      final ex = _FakeExchange()
        ..openPositions = [
          {
            'positionId': 7,
            'symbol': 'TEST_USDT',
            'positionType': 1,
            'openType': 1,
            'state': 1,
            'holdVol': 30,
            'holdAvgPrice': 1.8,
          },
        ];
      final engine = _engine(ex);
      // 前からある建玉を覚えさせる。
      await engine.refreshAccount();
      await engine.placeManualOrder(
        const ManualOrderRequest(
          symbol: 'TEST_USDT',
          direction: TradeDirection.long,
          kind: ManualOrderKind.trigger,
          marginUsdt: 100,
          leverage: 2,
          triggerPrice: 1.5,
          takeProfitPrice: 2.4,
        ),
      );
      expect(
        (ex.bodyOf('/api/v1/private/planorder/place') as Map)['triggerType'],
        2, // いま 2.0 より下なので「以下で発動」
      );
      // 一覧から消えたが、建玉は増えていない (取り消された)。
      ex.planOrders = [];
      await engine.refreshAccount();
      expect(ex.countOf('/api/v1/private/stoporder/place'), 0);
      expect(engine.snapshot.pendingExits, hasLength(1));
      await engine.dispose();
    });

    test('条件付き注文を取り消すと、利確 / 損切りの予約も消える', () async {
      final ex = _FakeExchange();
      final engine = _engine(ex);
      await engine.placeManualOrder(
        const ManualOrderRequest(
          symbol: 'TEST_USDT',
          direction: TradeDirection.short,
          kind: ManualOrderKind.trigger,
          marginUsdt: 100,
          leverage: 2,
          triggerPrice: 2.5,
          stopLossPrice: 2.7,
        ),
      );
      expect(engine.snapshot.pendingExits, hasLength(1));
      await engine.cancelExchangeOrder(
        symbol: 'TEST_USDT',
        orderId: '222',
        trigger: true,
      );
      final body = ex.bodyOf('/api/v1/private/planorder/cancel') as List;
      expect(body.single, {'symbol': 'TEST_USDT', 'orderId': 222});
      expect(engine.snapshot.pendingExits, isEmpty);
      await engine.dispose();
    });

    test('最小数量に届かない証拠金は断る', () async {
      final ex = _FakeExchange();
      final engine = _engine(ex);
      await expectLater(
        engine.placeManualOrder(
          const ManualOrderRequest(
            symbol: 'TEST_USDT',
            direction: TradeDirection.long,
            kind: ManualOrderKind.market,
            marginUsdt: 0.5,
            leverage: 1,
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(ex.countOf('/api/v1/private/order/create'), 0);
      await engine.dispose();
    });

    test('手で建てた建玉に利確 / 損切りを置く・成行で閉じる', () async {
      final ex = _FakeExchange()
        ..openPositions = [
          {
            'positionId': 5,
            'symbol': 'TEST_USDT',
            'positionType': 2,
            'openType': 1,
            'state': 1,
            'holdVol': 40,
            'holdAvgPrice': 2.0,
          },
        ];
      final engine = _engine(ex);
      await engine.refreshAccount();
      await expectLater(
        engine.updateExchangePositionExit(positionId: 5, takeProfitPrice: 2.2),
        throwsA(isA<StateError>()), // ショートの利確が建値より上
      );
      await engine.updateExchangePositionExit(
        positionId: 5,
        takeProfitPrice: 1.8,
        stopLossPrice: 2.3,
      );
      final stop = ex.bodyOf('/api/v1/private/stoporder/place') as Map;
      expect(stop['positionId'], 5);
      expect(stop['vol'], 40);

      await engine.closeExchangePosition(5);
      final close = ex.bodyOf('/api/v1/private/order/create') as Map;
      expect(close['side'], 2); // ショートを閉じる買い
      expect(close['type'], 5);
      expect(close['vol'], 40);
      expect(close['reduceOnly'], true);
      await engine.dispose();
    });
  });

  group('手で建てる時の「何 %」の基準', () {
    // 1 枚 = 1 TEST・値段 2 USDT。上限 100 枚 = 1 倍で証拠金 200 USDT。
    ContractInfo contract({double maxVol = 1000000, double? riskBaseVol}) =>
        ContractInfo.fromJson({
          ..._FakeExchange.contract,
          'maxVol': maxVol,
          if (riskBaseVol != null) 'riskBaseVol': riskBaseVol,
          if (riskBaseVol != null) 'riskIncrVol': 0,
          if (riskBaseVol != null) 'riskLevelLimit': 1,
        });

    test('銘柄の上限が残高より小さければ、上限に対する %', () {
      final s = OrderSizeBasis.of(
        available: 800,
        contract: contract(riskBaseVol: 100),
        price: 2,
        leverage: 1,
      );
      expect(s.symbolLimit, closeTo(200, 1e-9));
      expect(s.basedOnSymbolLimit, isTrue);
      expect(s.base, closeTo(200, 1e-9));
      // 残高 800 の 25% (= 200 で上限いっぱい) ではなく、上限 200 の 25%。
      expect(s.marginFor(25), closeTo(50, 1e-9));
      expect(s.marginFor(100), closeTo(200, 1e-9));
      expect(s.percentOf(50), closeTo(25, 1e-9));
    });

    test('レバレッジを上げると、上限を証拠金に直した額は小さくなる', () {
      final s = OrderSizeBasis.of(
        available: 800,
        contract: contract(riskBaseVol: 100),
        price: 2,
        leverage: 2,
      );
      expect(s.symbolLimit, closeTo(100, 1e-9));
      expect(s.marginFor(50), closeTo(50, 1e-9));
    });

    test('上限が残高より大きければ、今まで通り残高に対する %', () {
      final s = OrderSizeBasis.of(
        available: 800,
        contract: contract(riskBaseVol: 1000),
        price: 2,
        leverage: 1,
      );
      expect(s.basedOnSymbolLimit, isFalse);
      expect(s.base, 800);
      expect(s.marginFor(25), closeTo(200, 1e-9));
    });

    test('持っている分を引いた残りと、1 回の注文の上限を超えない', () {
      // 上限 200 USDT のうち 60 枚 (120 USDT) を持っている → 残り 80 USDT。
      final held = OrderSizeBasis.of(
        available: 800,
        contract: contract(riskBaseVol: 100),
        price: 2,
        leverage: 1,
        heldVol: 60,
      );
      expect(held.base, closeTo(200, 1e-9));
      expect(held.symbolRoom, closeTo(80, 1e-9));
      expect(held.marginFor(25), closeTo(50, 1e-9));
      expect(held.marginFor(75), closeTo(80, 1e-9));

      // 1 回の注文は 30 枚 (60 USDT) まで。
      final perOrder = OrderSizeBasis.of(
        available: 800,
        contract: contract(maxVol: 30, riskBaseVol: 100),
        price: 2,
        leverage: 1,
      );
      expect(perOrder.marginFor(50), closeTo(60, 1e-9));
    });

    test('上限が分からない・残高が分からない時', () {
      final noLimit = OrderSizeBasis.of(
        available: 800,
        contract: contract(),
        price: 2,
        leverage: 1,
      );
      // maxVol 1,000,000 枚 = 200 万 USDT。残高の方が小さいので残高が基準。
      expect(noLimit.basedOnSymbolLimit, isFalse);
      expect(noLimit.marginFor(25), closeTo(200, 1e-9));

      final unknown = OrderSizeBasis.of(
        available: 800,
        contract: ContractInfo.fromJson({
          ..._FakeExchange.contract,
          'maxVol': null,
        }),
        price: 2,
        leverage: 1,
      );
      expect(unknown.symbolLimit, isNull);
      expect(unknown.marginFor(25), 200);

      final noPrice = OrderSizeBasis.of(
        available: 800,
        contract: contract(riskBaseVol: 100),
        price: null,
        leverage: 1,
      );
      expect(noPrice.base, 800);

      final noBalance = OrderSizeBasis.of(
        available: null,
        contract: contract(riskBaseVol: 100),
        price: 2,
        leverage: 1,
      );
      expect(noBalance.base, isNull);
      expect(noBalance.marginFor(25), isNull);
      expect(noBalance.percentOf(50), 0);
    });
  });

  test('刻みちょうどの値段は、割り算の誤差で 1 刻みずらさない', () {
    final c = ContractInfo.fromJson(_FakeExchange.contract);
    expect(c.roundPrice(2.8, roundUp: false), 2.8);
    expect(c.roundPrice(2.8, roundUp: true), 2.8);
    expect(c.roundPrice(2.8004, roundUp: false), 2.8);
    expect(c.roundPrice(2.8004, roundUp: true), 2.801);
    expect(c.roundVolume(47.999999999999), 48);
  });

  group('取引所に出ている注文の読み方', () {
    test('指値と条件付き注文を読む', () {
      final limit = ExchangeOrder.fromOpenOrderJson({
        'orderId': 1234567890123456789,
        'symbol': 'TEST_USDT',
        'side': 3,
        'vol': 10,
        'dealVol': 4,
        'price': 2.5,
        'externalOid': 'bot123',
        'takeProfitPrice': 0,
      });
      expect(limit.id, '1234567890123456789');
      expect(limit.vol, 6);
      expect(limit.fromBot, isTrue);
      expect(limit.direction, TradeDirection.short);
      expect(limit.opens, isTrue);
      expect(limit.takeProfitPrice, isNull);
      expect(limit.linePrice, 2.5);

      final plan = ExchangeOrder.fromPlanOrderJson({
        'id': 55,
        'symbol': 'TEST_USDT',
        'side': 1,
        'vol': 3,
        'triggerPrice': 1.5,
        'triggerType': 2,
        'orderType': 5,
      });
      expect(plan.kind, ExchangeOrderKind.trigger);
      expect(plan.linePrice, 1.5);
      expect(plan.label, contains('以下で買い'));
      expect(ExchangeOrder.fromJson(plan.toJson()).toJson(), plan.toJson());
    });

    test('全銘柄の指値は、銘柄を付けない道で取る', () async {
      final ex = _FakeExchange()
        ..openOrders = [
          {'orderId': 1, 'symbol': 'TEST_USDT', 'side': 1, 'vol': 2, 'price': 1.9},
        ];
      final rest = MexcRestClient(
        apiKey: 'key',
        apiSecret: 'secret',
        httpClient: ex.client,
      );
      final orders = await rest.fetchOpenOrders();
      expect(orders, hasLength(1));
      final req = ex.requests.last;
      expect(req.url.path, '/api/v1/private/order/list/open_orders/');
      expect(req.url.queryParameters['page_size'], '100');
      rest.close();
    });
  });
}
