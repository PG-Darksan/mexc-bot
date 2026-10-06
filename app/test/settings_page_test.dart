import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mexc_bot_app/src/app.dart';
import 'package:mexc_bot_app/src/settings/app_settings.dart';
import 'package:mexc_bot_app/src/settings/settings_store.dart';
import 'package:mexc_bot_app/src/state/app_state.dart';
import 'package:mexc_bot_app/src/ui/settings_page.dart';
import 'package:mexc_core/mexc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 設定タブだけを出す。AppState は initialize しないので、通信はしない。
Future<AppState> _pumpSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState(SettingsStore());
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: const MaterialApp(home: Scaffold(body: SettingsPage())),
    ),
  );
  return state;
}

/// 「保存して反映」を押して、「保存しました」の知らせが消えるまで待つ。
Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('保存して反映'));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  // 設定タブは起動時に作られ、そのとき読んだ画面設定の写しを持ち続ける。
  // その写しで上書きして、ほかの所で変えた値を元に戻してしまっていた。
  group('設定タブで保存しても、ほかの所で変えた値は戻らない', () {
    testWidgets('上のボタンで変えた明るさ', (tester) async {
      final state = await _pumpSettings(tester);
      await state.updateAppSettings(
        state.settings.copyWith(themeMode: AppThemeMode.dark),
      );
      await tester.pump();

      await _save(tester);

      expect(state.settings.themeMode, AppThemeMode.dark);
    });
  });

  testWidgets('飛び出しで入る条件は、σ のバンドから何 % 外かで書く', (tester) async {
    await _pumpSettings(tester);

    expect(
      find.textContaining(
        '今の値: ショートは +4σ のバンドより 20% 以上高く、'
        'ロングは -4σ のバンドより 20% 以上安くなったら入ります',
      ),
      findsOneWidget,
    );
  });

  // 向きで分けるのは建てるか・出来高の下限・RSI の閾値だけ。他は揃え、
  // 指標の期間は固定値にし、使わない 1 分足と 8 時間足は外す。
  testWidgets('保存すると、向きで分けない項目は両方に同じ値が入る', (tester) async {
    final saved = StrategyConfig(
      short: const SideConfig.short().copyWith(
        leverage: 3,
        bbPeriod: 30,
        timeframes: const [Timeframe.m1, Timeframe.h1, Timeframe.h8],
        minAmount24Usdt: 1000000,
      ),
      long: const SideConfig.long().copyWith(
        leverage: 1,
        rsiPeriod: 14,
        minAmount24Usdt: 10000000,
      ),
    );
    SharedPreferences.setMockInitialValues({
      'flutter.strategy_config_v1': jsonEncode(saved.toJson()),
    });
    final state = AppState(SettingsStore());
    await state.updateStrategyConfig(await SettingsStore().loadStrategyConfig());
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await _save(tester);

    final c = state.config;
    expect(c.long.leverage, 3);
    expect(c.short.bbPeriod, 20);
    expect(c.long.rsiPeriod, 7);
    expect(c.long.timeframes, [Timeframe.h1]);
    // 向きで分ける項目はそのまま。
    expect(c.short.minAmount24Usdt, 1000000);
    expect(c.long.minAmount24Usdt, 10000000);
  });

  testWidgets('検証済みの設定を入れて保存すると、σ の決済でロングだけになる', (tester) async {
    final state = await _pumpSettings(tester);
    // 入れる前は今までの決め方なので、σ の欄は出ていない。
    expect(find.text('利確 (入値から)'), findsNothing);

    await tester.tap(find.text('この設定を入れる'));
    await tester.pumpAndSettle();
    expect(find.text('利確 (入値から)'), findsOneWidget);
    // 保存するまではボットの設定は変わらない。
    expect(state.config.long.exitMode, ExitMode.emaRatio);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await _save(tester);

    final c = state.config;
    expect(c.short.enabled, isFalse);
    expect(c.long.enabled, isTrue);
    expect(c.long.timeframes, [Timeframe.m15]);
    expect(c.maxOpenPositions, 10);
    expect(c.long.bbSigma, 4);
    expect(c.long.rsiThreshold, 5);
    expect(c.long.exitMode, ExitMode.sigma);
    expect(c.long.takeProfitSigma, 3);
    expect(c.long.stopLossSigma, 3);
    expect(c.long.maxHoldHours, 12);
  });
}
