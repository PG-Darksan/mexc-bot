import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mexc_core/mexc_core.dart';
import 'package:test/test.dart';

/// 送り直しの決まり。通信はしない (MockClient で返事を作る)。
MexcRestClient _client(MockClient http, {Duration? timeout}) =>
    MexcRestClient(
      apiKey: 'key',
      apiSecret: 'secret',
      httpClient: http,
      timeout: timeout ?? const Duration(seconds: 15),
    );

/// 成行のショート 1 枚。
Future<OrderResult> _order(MexcRestClient client) => client.createOrder(
  symbol: 'BTC_USDT',
  price: 60000,
  vol: 1,
  side: 3,
  type: 5,
  openType: 1,
);

http.Response _ok(Object data) => http.Response(
  jsonEncode({'success': true, 'code': 0, 'data': data}),
  200,
);

http.Response _error(int code) => http.Response(
  jsonEncode({'success': false, 'code': code, 'message': 'error'}),
  200,
);

void main() {
  // 送り直しは署名の有効時間 (20 秒) の内なら受け付けられるので、
  // 1 回目が通っていると同じ注文が二重に入る。
  group('新規注文は、通ったか分からないとき送り直さない', () {
    test('送ったあとで通信が切れたとき', () async {
      var calls = 0;
      final client = _client(
        MockClient((_) async {
          calls++;
          throw http.ClientException('Connection closed');
        }),
      );
      await expectLater(
        _order(client),
        throwsA(isA<MexcOrderUnknownException>()),
      );
      expect(calls, 1);
    });

    test('応答を待ちきれなかったとき', () async {
      var calls = 0;
      final client = _client(
        MockClient((_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return _ok({'orderId': 1});
        }),
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        _order(client),
        throwsA(isA<MexcOrderUnknownException>()),
      );
      expect(calls, 1);
    });

    test('MEXC が内部エラー (500) を返したとき', () async {
      var calls = 0;
      final client = _client(
        MockClient((_) async {
          calls++;
          return _error(500);
        }),
      );
      await expectLater(
        _order(client),
        throwsA(isA<MexcOrderUnknownException>()),
      );
      expect(calls, 1);
    });

    test('レート制限は受け付けられていないので送り直す', () async {
      var calls = 0;
      final client = _client(
        MockClient((_) async {
          calls++;
          return calls == 1 ? http.Response('', 429) : _ok({'orderId': 7});
        }),
      );
      final result = await _order(client);
      expect(result.orderId, '7');
      expect(calls, 2);
    });

    test('はっきり断られたときは、その理由をそのまま返す', () async {
      final client = _client(MockClient((_) async => _error(2005)));
      await expectLater(
        _order(client),
        throwsA(isA<MexcApiException>().having((e) => e.code, 'code', 2005)),
      );
    });
  });

  test('注文以外の問い合わせは、通信が切れたら送り直す', () async {
    var calls = 0;
    final client = _client(
      MockClient((_) async {
        calls++;
        if (calls < 3) throw http.ClientException('Connection reset');
        return _ok(<Object>[]);
      }),
    );
    expect(await client.fetchOpenPositions(), isEmpty);
    expect(calls, 3);
  });
}
