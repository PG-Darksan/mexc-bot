import 'package:flutter_test/flutter_test.dart';
import 'package:mexc_bot_app/src/settings/app_settings.dart';
import 'package:mexc_bot_app/src/ui/format.dart';

void main() {
  group('表示の整形', () {
    test('売買代金は読みやすい単位にする', () {
      expect(formatUsdtCompact(5000000), '5.0M');
      expect(formatUsdtCompact(1234), '1.2K');
      expect(formatUsdtCompact(5159300000), '5.16B');
    });

    test('価格は桁に応じて有効数字を変える', () {
      expect(formatPrice(85888.0), '85888.00');
      expect(formatPrice(1.5), '1.5000');
      expect(formatPrice(0.042057), '0.042057');
      expect(formatPrice(null), '-');
    });

    test('符号つきの割合', () {
      expect(formatSignedPercent(3.14), '+3.14%');
      expect(formatSignedPercent(-2.5), '-2.50%');
    });

    test('損益は単位つきで出す', () {
      expect(formatPnl(1.5), '+1.5000 USDT');
      expect(formatPnl(-0.25), '-0.2500 USDT');
      expect(formatPnl(null), '-');
    });
  });

  group('アプリ設定', () {
    test('JSON と往復できる', () {
      const settings = AppSettings(
        serverUrl: 'wss://example.com/ws',
        serverToken: 'secret',
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.serverUrl, 'wss://example.com/ws');
      expect(restored.serverToken, 'secret');
    });

    test('以前の版の動かし方 (ローカル実行) の設定は読み飛ばす', () {
      final restored = AppSettings.fromJson({
        'mode': 'local',
        'wasRunning': true,
        'serverUrl': 'ws://100.64.0.1:8080/ws',
      });
      expect(restored.serverUrl, 'ws://100.64.0.1:8080/ws');
    });
  });
}
