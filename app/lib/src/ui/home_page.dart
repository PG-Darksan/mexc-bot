import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../settings/app_settings.dart';
import '../settings/app_settings.dart';
import 'chart_page.dart';
import 'orders_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  // 残高とチャートは同じタブにまとめてある。
  static const _destinations = [
    (icon: Icons.home_outlined, selected: Icons.home, label: 'ホーム'),
    (
      icon: Icons.receipt_long_outlined,
      selected: Icons.receipt_long,
      label: '履歴',
    ),
    (icon: Icons.tune_outlined, selected: Icons.tune, label: '設定'),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (!state.initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final pages = const [ChartPage(), OrdersPage(), SettingsPage()];

    final wide = MediaQuery.sizeOf(context).width >= 900;

    // IndexedStack にして、タブを移ってもそれぞれの画面の状態を保つ。
    // 設定タブで触りかけの内容が、行き来で消えないようにするため。
    final body = IndexedStack(index: _index, children: pages);

    return Scaffold(
      appBar: const _TopBar(),
      body: Column(
        children: [
          const _NoticeBar(),
          Expanded(
            child: wide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _index,
                        onDestinationSelected: (i) =>
                            setState(() => _index = i),
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          for (final d in _destinations)
                            NavigationRailDestination(
                              icon: Icon(d.icon),
                              selectedIcon: Icon(d.selected),
                              label: Text(d.label),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: body),
                    ],
                  )
                : body,
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final d in _destinations)
                  NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: d.label,
                  ),
              ],
            ),
    );
  }
}

class _TopBar extends StatelessWidget implements PreferredSizeWidget {
  const _TopBar();

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final snapshot = state.snapshot;
    final theme = Theme.of(context);

    final brightnessButton = IconButton(
      tooltip: '明るさを切り替える',
      icon: Icon(
        theme.brightness == Brightness.dark
            ? Icons.light_mode_outlined
            : Icons.dark_mode_outlined,
        size: 20,
      ),
      onPressed: () {
        final toDark = theme.brightness != Brightness.dark;
        state.updateAppSettings(
          state.settings.copyWith(
            themeMode: toDark ? AppThemeMode.dark : AppThemeMode.light,
          ),
        );
      },
    );

    final startButton = Padding(
      padding: const EdgeInsets.only(right: 12),
      child: FilledButton.icon(
        onPressed: () => snapshot.running ? state.stop() : state.start(),
        icon: Icon(snapshot.running ? Icons.stop : Icons.play_arrow),
        label: Text(snapshot.running ? '停止' : '開始'),
        style: FilledButton.styleFrom(
          backgroundColor: snapshot.running
              ? theme.colorScheme.error
              : theme.colorScheme.primary,
        ),
      ),
    );

    // 動かし方や接続の状態はホームの「稼働状況」に出す。ここには置かない。
    return AppBar(
      title: const Text('MEXC 自動売買', overflow: TextOverflow.ellipsis),
      actions: [brightnessButton, startButton],
    );
  }
}

class _NoticeBar extends StatelessWidget {
  const _NoticeBar();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final messages = <String>[
      if (state.notice != null) state.notice!,
      if (state.snapshot.lastError != null)
        'さっきのエラー: ${state.snapshot.lastError}',
      if (state.isLocalMode && state.credentials.isEmpty)
        'APIキーが未設定です。注文を出すには設定タブで登録してください。',
      if (!state.isLocalMode && state.connection == ControllerConnection.error)
        'サーバーに繋がりません。設定タブのURLと接続トークン、'
            'サーバーが動いているかを確認してください。',
    ];
    if (messages.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              size: 18,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                messages.join('  /  '),
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: state.dismissNotice,
            ),
          ],
        ),
      ),
    );
  }
}

/// アプリ設定の実行モードを画面から切り替えるための小物。
extension RunModeLabel on RunMode {
  String get label => switch (this) {
    RunMode.local => 'ローカル実行 (この端末だけで動かす)',
    RunMode.remote => 'サーバー接続 (常駐サーバーを操作する)',
  };
}
