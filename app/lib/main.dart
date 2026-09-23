import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/settings/settings_store.dart';
import 'src/state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final isDesktop =
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1280, 820),
        minimumSize: Size(900, 640),
        title: 'MEXC 自動売買',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  final store = SettingsStore();
  final state = AppState(store);
  runApp(MexcBotApp(state: state));
  await state.initialize();
}
