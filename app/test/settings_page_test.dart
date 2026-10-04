import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mexc_bot_app/src/app.dart';
import 'package:mexc_bot_app/src/settings/app_settings.dart';
import 'package:mexc_bot_app/src/settings/settings_store.dart';
import 'package:mexc_bot_app/src/state/app_state.dart';
import 'package:mexc_bot_app/src/ui/settings_page.dart';
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
        'いまの値: ショートは +4σ のバンドより 20% 以上高く、'
        'ロングは -4σ のバンドより 20% 以上安くなったら入ります',
      ),
      findsOneWidget,
    );
  });
}
