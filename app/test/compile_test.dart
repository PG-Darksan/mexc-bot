// 画面のコードが型として通ることを確かめるためだけのテスト。
//
// この Dart SDK では app パッケージの `dart analyze` / `flutter analyze` が
// 解析サーバーごと落ちるため (README 参照)、画面を import するテストを
// 1 本置いて `flutter test` でまとめてコンパイルさせている。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mexc_bot_app/src/app.dart';
import 'package:mexc_bot_app/src/ui/chart_page.dart';
import 'package:mexc_bot_app/src/ui/dashboard_page.dart';
import 'package:mexc_bot_app/src/ui/home_page.dart';
import 'package:mexc_bot_app/src/ui/log_page.dart';
import 'package:mexc_bot_app/src/ui/market_page.dart';
import 'package:mexc_bot_app/src/ui/orders_page.dart';
import 'package:mexc_bot_app/src/ui/price_chart.dart';
import 'package:mexc_bot_app/src/ui/settings_page.dart';

void main() {
  test('画面のウィジェットを組み立てられる', () {
    // 組み立てるだけ (pump はしない。通信や保存領域に触るため)。
    const widgets = <Widget>[
      HomePage(),
      MarketPage(),
      ChartPage(),
      OrdersPage(),
      SettingsPage(),
      LogPage(),
      AccountSection(),
      StatusSections(),
      PriceChart(candles: [], bbPeriod: 20, bbSigma: 4, emaPeriod: 5),
    ];
    expect(widgets, hasLength(9));
  });

  test('MexcBotApp の型が揃っている', () {
    expect(AppScope.of, isA<Function>());
    expect(MexcBotApp, isNotNull);
  });
}
