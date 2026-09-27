import 'package:mexc_core/mexc_core.dart';
import 'package:test/test.dart';

/// サーバーのURLの直し方。通信はしない。
void main() {
  group('normalizeServerUrl', () {
    test('そのまま使える書き方は変えない', () {
      expect(
        normalizeServerUrl('ws://192.168.0.10:8080/ws').toString(),
        'ws://192.168.0.10:8080/ws',
      );
      expect(
        normalizeServerUrl('wss://example.duckdns.org/ws').toString(),
        'wss://example.duckdns.org/ws',
      );
    });

    test('前後の空白や改行は落とす', () {
      expect(
        normalizeServerUrl('  ws://127.0.0.1:8080/ws \n').toString(),
        'ws://127.0.0.1:8080/ws',
      );
    });

    test('スキームが無ければ ws:// を付ける', () {
      expect(
        normalizeServerUrl('192.168.0.10:8080/ws').toString(),
        'ws://192.168.0.10:8080/ws',
      );
    });

    test('http / https は ws / wss に直す', () {
      expect(
        normalizeServerUrl('http://127.0.0.1:8080/ws').toString(),
        'ws://127.0.0.1:8080/ws',
      );
      expect(
        normalizeServerUrl('https://example.duckdns.org/ws').toString(),
        'wss://example.duckdns.org/ws',
      );
    });

    test('パスを書き忘れたら /ws を足す', () {
      expect(
        normalizeServerUrl('wss://example.duckdns.org').toString(),
        'wss://example.duckdns.org/ws',
      );
      expect(
        normalizeServerUrl('ws://127.0.0.1:8080/').toString(),
        'ws://127.0.0.1:8080/ws',
      );
    });

    test('直せない書き方は null', () {
      expect(normalizeServerUrl(''), isNull);
      expect(normalizeServerUrl('   '), isNull);
      expect(normalizeServerUrl('ftp://example.com/ws'), isNull);
    });
  });
}
