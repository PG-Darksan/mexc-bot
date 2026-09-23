import 'package:flutter/material.dart';

import 'desktop/tray_service.dart';
import 'state/app_state.dart';
import 'ui/home_page.dart';

/// 画面ツリーに [AppState] を配る。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope が見つかりません');
    return scope!.notifier!;
  }
}

class MexcBotApp extends StatefulWidget {
  const MexcBotApp({super.key, required this.state});

  final AppState state;

  @override
  State<MexcBotApp> createState() => _MexcBotAppState();
}

class _MexcBotAppState extends State<MexcBotApp> {
  final TrayService _tray = TrayService();
  bool _trayReady = false;
  bool? _lastKeepInTray;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    _onStateChanged();
  }

  void _onStateChanged() {
    final keep = widget.state.settings.keepRunningInTray;
    if (!_trayReady) {
      _trayReady = true;
      _lastKeepInTray = keep;
      _tray.initialize(
        keepInTray: keep,
        onBeforeExit: () async {
          // トレイから終了するときは、建玉を保存してからプロセスを落とす。
          await widget.state.shutdown();
        },
      );
      return;
    }
    if (_lastKeepInTray != keep) {
      _lastKeepInTray = keep;
      _tray.setKeepInTray(keep);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    _tray.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        title: 'MEXC 自動売買',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: const HomePage(),
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00B894),
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}
