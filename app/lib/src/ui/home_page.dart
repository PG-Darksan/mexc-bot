import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../settings/app_settings.dart';
import 'dashboard_page.dart';
import 'log_page.dart';
import 'positions_page.dart';
import 'settings_page.dart';
import 'signals_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.dashboard_outlined, selected: Icons.dashboard, label: '状況'),
    (icon: Icons.radar_outlined, selected: Icons.radar, label: 'シグナル'),
    (
      icon: Icons.account_balance_wallet_outlined,
      selected: Icons.account_balance_wallet,
      label: 'ポジション',
    ),
    (icon: Icons.article_outlined, selected: Icons.article, label: 'ログ'),
    (icon: Icons.settings_outlined, selected: Icons.settings, label: '設定'),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (!state.initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final pages = const [
      DashboardPage(),
      SignalsPage(),
      PositionsPage(),
      LogPage(),
      SettingsPage(),
    ];

    final wide = MediaQuery.sizeOf(context).width >= 900;

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
                      Expanded(child: pages[_index]),
                    ],
                  )
                : pages[_index],
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

    return AppBar(
      title: Row(
        children: [
          const Text('MEXC 自動売買'),
          const SizedBox(width: 16),
          _Chip(
            label: state.isLocalMode ? 'ローカル実行' : 'サーバー接続',
            icon: state.isLocalMode ? Icons.computer : Icons.cloud_outlined,
            color: theme.colorScheme.primary,
          ),
          if (!state.isLocalMode) ...[
            const SizedBox(width: 8),
            _Chip(
              label: switch (state.connection) {
                ControllerConnection.connected => '接続中',
                ControllerConnection.connecting => '接続処理中',
                ControllerConnection.error => '接続エラー',
                ControllerConnection.disconnected => '未接続',
              },
              icon: state.connection == ControllerConnection.connected
                  ? Icons.link
                  : Icons.link_off,
              color: state.connection == ControllerConnection.connected
                  ? Colors.green
                  : theme.colorScheme.error,
            ),
          ],
          for (final side in snapshot.config.enabledSides) ...[
            const SizedBox(width: 8),
            _Chip(
              label: side.direction.label,
              icon: side.direction.isShort
                  ? Icons.trending_down
                  : Icons.trending_up,
              color: side.direction.isShort ? Colors.redAccent : Colors.green,
            ),
          ],
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(
            onPressed: () =>
                snapshot.running ? state.stop() : state.start(),
            icon: Icon(snapshot.running ? Icons.stop : Icons.play_arrow),
            label: Text(snapshot.running ? '停止' : '開始'),
            style: FilledButton.styleFrom(
              backgroundColor: snapshot.running
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
          ),
        ),
      ],
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
      if (state.snapshot.lastError != null) '直近のエラー: ${state.snapshot.lastError}',
      if (state.isLocalMode && state.credentials.isEmpty)
        'APIキーが未設定です。注文を出すには設定タブで登録してください。',
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

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.icon, required this.color});

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
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
