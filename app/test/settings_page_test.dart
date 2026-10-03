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

/// 設定タブを開いたあとで、上のボタンから暗くしたときと同じ状態にする。
Future<void> _switchToDark(WidgetTester tester, AppState state) async {
  await state.updateAppSettings(
    state.settings.copyWith(themeMode: AppThemeMode.dark),
  );
  await tester.pump();
}

void main() {
  // 設定タブは起動時に作られ、そのとき読んだ画面設定の写しを持ち続ける。
  // その写しの明るさで上書きして、暗くしたのに明るく戻ってしまっていた。
  group('設定タブで保存しても明るさは戻らない', () {
    testWidgets('動かし方のスイッチを切り替えたとき', (tester) async {
      final state = await _pumpSettings(tester);
      await _switchToDark(tester, state);

      final autoStart = find.text('アプリ起動と同時にボットを動かす');
      await tester.ensureVisible(autoStart);
      await tester.pumpAndSettle();
      await tester.tap(autoStart);
      await tester.pumpAndSettle();

      expect(state.settings.autoStartBot, isTrue);
      expect(state.settings.themeMode, AppThemeMode.dark);
    });

    testWidgets('「保存して反映」を押したとき', (tester) async {
      final state = await _pumpSettings(tester);
      await _switchToDark(tester, state);

      await tester.tap(find.text('保存して反映'));
      await tester.pumpAndSettle();
      // 「保存しました」の知らせが消えるまで待つ (時計が残らないように)。
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(state.settings.themeMode, AppThemeMode.dark);
    });
  });

  testWidgets('行きすぎの基準は、σ のバンドから何 % 離れたらかで書く', (tester) async {
    await _pumpSettings(tester);

    expect(
      find.text(
        'ショートは +4σ のバンドより 20% 以上高く、'
        'ロングは -4σ のバンドより 20% 以上安くなったら、RSI を見ずに入ります。'
        '% はバンドの価格に対する割合です。',
      ),
      findsOneWidget,
    );
  });
}
