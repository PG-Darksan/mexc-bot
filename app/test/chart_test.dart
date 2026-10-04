import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mexc_bot_app/src/app.dart';
import 'package:mexc_bot_app/src/settings/app_settings.dart';
import 'package:mexc_bot_app/src/settings/settings_store.dart';
import 'package:mexc_bot_app/src/state/app_state.dart';
import 'package:mexc_bot_app/src/ui/chart_overlays.dart';
import 'package:mexc_bot_app/src/ui/price_chart.dart';
import 'package:mexc_core/mexc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 波打つ値動き。本数は EMA150 の助走ぶんより多く取る。
List<Candle> _candles(int n) => [
  for (var i = 0; i < n; i++)
    Candle(
      openTime: 1700000000 + i * 3600,
      open: 100 + 10 * math.sin(i / 10),
      high: 102 + 10 * math.sin(i / 10),
      low: 98 + 10 * math.sin(i / 10),
      close: 100 + 10 * math.sin((i + 1) / 10),
      volume: 1,
      amount: 1,
    ),
];

void main() {
  testWidgets('足したバンドと EMA を描き、何の線かを下に出す', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PriceChart(
            candles: _candles(800),
            bbPeriod: 20,
            bbSigma: 4,
            emaPeriod: 5,
            sigmas: const [2, 3, 4],
            extraEmas: const [50, 100, 150],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('BB(20) 4σ (判定)'), findsOneWidget);
    expect(find.text('2σ'), findsOneWidget);
    expect(find.text('3σ'), findsOneWidget);
    // 判定と同じ 4σ は二重に描かない。
    expect(find.text('4σ'), findsNothing);
    expect(find.text('EMA150'), findsOneWidget);
  });

  testWidgets('「線の表示」で選んだ線を覚える', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(SettingsStore());
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: ChartOverlayButton())),
        ),
      ),
    );
    await tester.tap(find.byType(ChartOverlayButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('EMA200'));
    await tester.pumpAndSettle();
    expect(state.settings.chartEmas, containsAll([50, 100, 150, 200]));

    await tester.tap(find.text('EMA50'));
    await tester.pumpAndSettle();
    expect(state.settings.chartEmas, isNot(contains(50)));

    // ±1σ と ±5σ は選べない。
    expect(find.text('±1σ'), findsNothing);
    expect(find.text('±5σ'), findsNothing);
    await tester.tap(find.text('±3σ'));
    await tester.pumpAndSettle();
    expect(state.settings.chartSigmas, isNot(contains(3.0)));
    await tester.tap(find.text('±3σ'));
    await tester.pumpAndSettle();
    expect(state.settings.chartSigmas, contains(3.0));

    // 判定に使うバンドも外せる。
    await tester.tap(find.text('±4σ (判定)'));
    await tester.pumpAndSettle();
    expect(state.settings.chartSigmas, isNot(contains(4.0)));
    await tester.tap(find.text('±2σ'));
    await tester.pumpAndSettle();
    expect(state.settings.chartSigmas, isNot(contains(2.0)));

    // 閉じて開き直しても残る。
    final restored = AppSettings.fromJson(state.settings.toJson());
    expect(restored.chartSigmas, state.settings.chartSigmas);
    expect(restored.chartEmas, state.settings.chartEmas);
  });

  testWidgets('判定のバンドを選ばなければ描かない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PriceChart(
            candles: _candles(300),
            bbPeriod: 20,
            bbSigma: 4,
            emaPeriod: 5,
            sigmas: const [3],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('BB(20) 4σ (判定)'), findsNothing);
    expect(find.text('3σ'), findsOneWidget);
  });

  test('以前の版の線の選択は、判定の 4σ を足して引き継ぐ', () {
    final restored = AppSettings.fromJson({
      'chartSigmas': [2, 3],
    });
    expect(restored.chartSigmas, [2.0, 3.0, 4.0]);
  });

  test('以前に選んだ ±1σ・±5σ は描かない (判定の σ なら描く)', () {
    expect(visibleChartSigmas([1, 2, 3, 5], 4), [2.0, 3.0]);
    expect(visibleChartSigmas([2, 5], 5), [2.0, 5.0]);
  });
}
