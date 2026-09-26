import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../settings/app_settings.dart';
import '../settings/app_settings.dart';
import 'chart_page.dart';
import 'dashboard_page.dart';
import 'orders_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  static const _destinations = [
    (
      icon: Icons.candlestick_chart_outlined,
      selected: Icons.candlestick_chart,
      label: 'チャート',
    ),
    (
      icon: Icons.account_balance_wallet_outlined,
      selected: Icons.account_balance_wallet,
      label: '残高',
    ),
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

    final pages = const [
      ChartPage(),
      DashboardPage(),
      OrdersPage(),
      SettingsPage(),
    ];

    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    // 横に並べると「開始」ボタンに重なる幅では、状態チップを2段目へ落とす。
    final compactHeader = width < 620;

    // IndexedStack にして、タブを移ってもそれぞれの画面の状態を保つ。
    // 設定タブで触りかけの内容が、行き来で消えないようにするため。
    final body = IndexedStack(index: _index, children: pages);

    return Scaffold(
      appBar: _TopBar(compact: compactHeader),
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
  const _TopBar({required this.compact});

  /// 画面が狭く、状態チップをタイトルの下の段に置くか。
  final bool compact;

  static const double _barHeight = 56;
  static const double _chipRowHeight = 40;

  @override
  Size get preferredSize =>
      Size.fromHeight(compact ? _barHeight + _chipRowHeight : _barHeight);

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final snapshot = state.snapshot;
    final theme = Theme.of(context);

    final chips = <Widget>[
      _Chip(
        label: state.isLocalMode ? 'ローカル実行' : 'サーバー接続',
        icon: state.isLocalMode ? Icons.computer : Icons.cloud_outlined,
        color: theme.colorScheme.primary,
      ),
      if (!state.isLocalMode)
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
      for (final side in snapshot.config.enabledSides)
        _Chip(
          label: side.direction.label,
          icon: side.direction.isShort
              ? Icons.trending_down
              : Icons.trending_up,
          color: side.direction.isShort ? Colors.redAccent : Colors.green,
        ),
    ];

    // 方向を両方入れるとチップが増える。入りきらないぶんは横に流して、
    // 「開始」ボタンの下へ潜り込まないようにする。
    Widget chipRow(EdgeInsets padding) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            chips[i],
          ],
        ],
      ),
    );

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

    if (compact) {
      return AppBar(
        title: const Text('MEXC 自動売買', overflow: TextOverflow.ellipsis),
        actions: [brightnessButton, startButton],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(_chipRowHeight),
          child: SizedBox(
            height: _chipRowHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: chipRow(const EdgeInsets.fromLTRB(16, 0, 16, 8)),
            ),
          ),
        ),
      );
    }

    return AppBar(
      title: Row(
        children: [
          const Flexible(
            child: Text('MEXC 自動売買', overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 16),
          Expanded(child: chipRow(EdgeInsets.zero)),
        ],
      ),
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
