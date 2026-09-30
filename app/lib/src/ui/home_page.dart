import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../settings/app_settings.dart';
import '../state/app_state.dart';
import 'chart_page.dart';
import 'market_page.dart';
import 'orders_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;
  AppState? _state;

  // 残高とチャートは同じタブにまとめてある。
  static const _destinations = [
    (icon: Icons.home_outlined, selected: Icons.home, label: 'ホーム'),
    (icon: Icons.list_alt_outlined, selected: Icons.list_alt, label: '銘柄'),
    (
      icon: Icons.receipt_long_outlined,
      selected: Icons.receipt_long,
      label: '履歴',
    ),
    (icon: Icons.tune_outlined, selected: Icons.tune, label: '設定'),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (identical(state, _state)) return;
    _state?.chartRequest.removeListener(_onChartRequest);
    _state = state;
    state.chartRequest.addListener(_onChartRequest);
  }

  @override
  void dispose() {
    _state?.chartRequest.removeListener(_onChartRequest);
    super.dispose();
  }

  /// 銘柄一覧などで「チャートを見る」を押したら、ホームへ移る。
  void _onChartRequest() {
    if (!mounted || _state?.chartRequest.value == null) return;
    setState(() => _index = 0);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (!state.initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final pages = const [
      ChartPage(),
      MarketPage(),
      OrdersPage(),
      SettingsPage(),
    ];

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

class _NoticeBar extends StatefulWidget {
  const _NoticeBar();

  @override
  State<_NoticeBar> createState() => _NoticeBarState();
}

class _NoticeBarState extends State<_NoticeBar> {
  /// × で閉じた文面。同じ知らせが出ている間は伏せておく。
  ///
  /// 「サーバーに繋がりません」のように、状態から毎回組み直される知らせも
  /// 閉じられるようにするため、消した文面をここで覚えておく。
  /// その知らせが消えたら忘れるので、もう一度起きればまた出る。
  final Set<String> _dismissed = {};

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
    // 出ていない知らせは覚えておく必要がない。ここで落としても、
    // いま画面に出すものは変わらない (伏せる対象が減るだけ)。
    _dismissed.removeWhere((m) => !messages.contains(m));
    final visible = messages.where((m) => !_dismissed.contains(m)).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

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
                visible.join('  /  '),
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            IconButton(
              tooltip: '閉じる',
              icon: const Icon(Icons.close, size: 16),
              color: theme.colorScheme.onErrorContainer,
              onPressed: () {
                setState(() => _dismissed.addAll(visible));
                state.dismissNotice();
              },
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
