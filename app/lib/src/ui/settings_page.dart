import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../settings/app_settings.dart';
import '../desktop/tray_service.dart';
import '../settings/settings_store.dart';
import 'home_page.dart' show RunModeLabel;

/// 売買条件と接続設定をまとめて編集する画面。
///
/// 項目が多いので、よく触るものだけ開いた状態で畳んである。
/// ショートとロングは同じ並びで左右に置き、値を見比べられるようにする。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  StrategyConfig? _draft;
  AppSettings? _appDraft;
  final _apiKeyController = TextEditingController();
  final _apiSecretController = TextEditingController();
  final _serverUrlController = TextEditingController();
  final _serverTokenController = TextEditingController();
  bool _loadedOnce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedOnce) return;
    _loadedOnce = true;
    _reload();
  }

  void _reload() {
    final state = AppScope.of(context);
    setState(() {
      _draft = state.config;
      _appDraft = state.settings;
      _apiKeyController.text = state.credentials.apiKey;
      _apiSecretController.text = state.credentials.apiSecret;
      _serverUrlController.text = state.settings.serverUrl;
      _serverTokenController.text = state.settings.serverToken;
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _apiSecretController.dispose();
    _serverUrlController.dispose();
    _serverTokenController.dispose();
    super.dispose();
  }

  StrategyConfig get draft => _draft!;
  AppSettings get appDraft => _appDraft!;

  void _update(StrategyConfig Function(StrategyConfig) change) =>
      setState(() => _draft = change(draft));

  void _updateApp(AppSettings Function(AppSettings) change) =>
      setState(() => _appDraft = change(appDraft));

  /// 動かし方まわりは、切り替えたその場で覚える。
  ///
  /// タブを移ると画面が作り直されるので、保存しないと元に戻ってしまう。
  Future<void> _persistAppSettings(AppSettings next) async {
    if (!mounted) return;
    await AppScope.of(context).updateAppSettings(
      next.copyWith(
        serverUrl: _serverUrlController.text.trim(),
        serverToken: _serverTokenController.text.trim(),
      ),
    );
  }

  void _changeAppSettings(AppSettings Function(AppSettings) change) {
    final next = change(appDraft);
    setState(() => _appDraft = next);
    unawaited(_persistAppSettings(next));
  }

  Future<void> _save() async {
    final state = AppScope.of(context);
    final config = draft;
    final errors = config.validate();
    if (errors.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errors.join('\n')),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    await state.updateStrategyConfig(config);
    await state.updateAppSettings(
      appDraft.copyWith(
        serverUrl: _serverUrlController.text.trim(),
        serverToken: _serverTokenController.text.trim(),
      ),
    );
    if (_apiKeyController.text.trim() != state.credentials.apiKey ||
        _apiSecretController.text.trim() != state.credentials.apiSecret) {
      await state.updateCredentials(
        Credentials(
          apiKey: _apiKeyController.text.trim(),
          apiSecret: _apiSecretController.text.trim(),
        ),
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('設定を保存しました')));
  }

  @override
  Widget build(BuildContext context) {
    if (_draft == null || _appDraft == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final state = AppScope.of(context);
    final limitOrder = draft.orderType == EntryOrderType.limit;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            children: [
              // ── いちばん触るところ。開いたままにする ──
              _Section(
                title: 'ショートとロング',
                description: '同じ項目を左右に並べてあります。'
                    'RSI のしきい値だけ向きが逆 (既定 97 / 3) です。',
                initiallyExpanded: true,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _SideCard(
                          side: draft.short,
                          showLimitOffset: limitOrder,
                          showFunding: draft.fundingFilterEnabled,
                          onChanged: (side) => _update((c) => c.withSide(side)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _SideCard(
                          side: draft.long,
                          showLimitOffset: limitOrder,
                          showFunding: draft.fundingFilterEnabled,
                          onChanged: (side) => _update((c) => c.withSide(side)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _update(
                            (c) => c.copyWith(long: c.short.mirrored()),
                          ),
                          child: const Text('← の値を右へ', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _update(
                            (c) => c.copyWith(short: c.long.mirrored()),
                          ),
                          child: const Text('右の値を ← へ', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                  ),
                  const _Hint('そろえると、RSI のしきい値だけ 100 から引いた値に入れ替わります。'),
                ],
              ),

              _Section(
                title: '監視する銘柄',
                children: [
                  _NumberField(
                    label: '24h出来高の下限',
                    suffix: 'M USDT',
                    value: draft.minAmount24Usdt / 1000000,
                    onChanged: (v) => _update(
                      (c) => c.copyWith(minAmount24Usdt: v * 1000000),
                    ),
                  ),
                  const _Hint(
                    '1 M = 100万 USDT。既定 5 M。\n'
                    '監視する銘柄はこの下限だけで決まります。'
                    '銘柄数に上限は無く、手で選んだり外したりもしません。',
                  ),
                ],
              ),

              _Section(
                title: '判定に使う時間軸',
                description: '選んだ時間軸それぞれで独立に判定します。',
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tf in Timeframe.values)
                        FilterChip(
                          label: Text(tf.label, style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          selected: draft.timeframes.contains(tf),
                          onSelected: (selected) => _update((c) {
                            final list = [...c.timeframes];
                            if (selected) {
                              list.add(tf);
                              list.sort(
                                (a, b) => a.seconds.compareTo(b.seconds),
                              );
                            } else {
                              list.remove(tf);
                            }
                            return c.copyWith(timeframes: list);
                          }),
                        ),
                    ],
                  ),
                ],
              ),

              _Section(
                title: '指標の期間',
                description: 'ショートとロングで共通です。',
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _NumberField(
                          label: 'BB期間',
                          value: draft.bbPeriod.toDouble(),
                          integer: true,
                          dense: true,
                          onChanged: (v) =>
                              _update((c) => c.copyWith(bbPeriod: v.toInt())),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _NumberField(
                          label: 'RSI期間',
                          value: draft.rsiPeriod.toDouble(),
                          integer: true,
                          dense: true,
                          onChanged: (v) =>
                              _update((c) => c.copyWith(rsiPeriod: v.toInt())),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _NumberField(
                          label: 'EMA期間',
                          value: draft.emaPeriod.toDouble(),
                          integer: true,
                          dense: true,
                          onChanged: (v) =>
                              _update((c) => c.copyWith(emaPeriod: v.toInt())),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _NumberField(
                          label: '保持する足',
                          suffix: '本',
                          value: draft.historyBars.toDouble(),
                          integer: true,
                          dense: true,
                          onChanged: (v) => _update(
                            (c) => c.copyWith(historyBars: v.toInt()),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const _Hint('RSI は Wilder 平滑 (TradingView と同じ計算) です。'),
                ],
              ),

              _Section(
                title: 'エントリーの出し方',
                description: 'レバレッジ・証拠金・指値の幅は方向ごとの設定にあります。',
                children: [
                  SegmentedButton<EntryOrderType>(
                    segments: const [
                      ButtonSegment(
                        value: EntryOrderType.market,
                        label: Text('成行', style: TextStyle(fontSize: 12)),
                      ),
                      ButtonSegment(
                        value: EntryOrderType.limit,
                        label: Text('指値', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                    selected: {draft.orderType},
                    onSelectionChanged: (s) =>
                        _update((c) => c.copyWith(orderType: s.first)),
                  ),
                  const _Hint(
                    'このボットは一方向モードで動きます。'
                    '同じ銘柄に建玉があれば向きに関わらず新規を出さないので、'
                    'ヘッジは使いません。\n'
                    'MEXC 側も「一方向モード」にしてください。'
                    '食い違うと決済注文が通らず、起動時に警告が出ます。',
                  ),
                  _CompactSwitch(
                    label: '分離マージンを使う',
                    subtitle: '切るとクロスマージン。損切りを置かない運用では分離を推奨。',
                    value: draft.useIsolatedMargin,
                    onChanged: (v) =>
                        _update((c) => c.copyWith(useIsolatedMargin: v)),
                  ),
                ],
              ),

              _Section(
                title: '利確の出し方',
                description: '係数と下限、損切りは方向ごとの設定にあります。',
                children: [
                  _CompactSwitch(
                    label: '発注と同時に利確を取引所へ預ける',
                    subtitle: 'アプリやサーバーが落ちていても取引所側で利確されます。',
                    value: draft.attachTakeProfitToOrder,
                    onChanged: (v) =>
                        _update((c) => c.copyWith(attachTakeProfitToOrder: v)),
                  ),
                ],
              ),

              _Section(
                title: '資金調達率のフィルタ',
                children: [
                  _CompactSwitch(
                    label: 'フィルタを使う',
                    subtitle: 'その方向が支払う側のときだけ効きます。'
                        '負担率と間隔の基準は方向ごとの設定に。',
                    value: draft.fundingFilterEnabled,
                    onChanged: (v) =>
                        _update((c) => c.copyWith(fundingFilterEnabled: v)),
                  ),
                ],
              ),

              _Section(
                title: '運用',
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _NumberField(
                          label: '判定の間隔',
                          suffix: '秒',
                          value: draft.evaluationIntervalSeconds.toDouble(),
                          integer: true,
                          dense: true,
                          onChanged: (v) => _update(
                            (c) => c.copyWith(
                              evaluationIntervalSeconds: v.toInt(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _NumberField(
                          label: '再エントリー待ち',
                          suffix: '分',
                          value: draft.reentryCooldownMinutes.toDouble(),
                          integer: true,
                          dense: true,
                          onChanged: (v) => _update(
                            (c) => c.copyWith(reentryCooldownMinutes: v.toInt()),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const _Hint(
                    '同時に持てる件数に上限はありません。'
                    'ただし建玉のある銘柄には、向きが同じでも違っても新規注文を出しません。'
                    '決済してからは「再エントリー待ち」の間だけ間を置きます。',
                  ),
                  _CompactSwitch(
                    label: '同じ足では1回だけ発火させる',
                    value: draft.oneSignalPerBar,
                    onChanged: (v) =>
                        _update((c) => c.copyWith(oneSignalPerBar: v)),
                  ),
                ],
              ),

              _Section(
                title: '動かし方',
                description: '${appDraft.mode == RunMode.local ? "ローカル実行" : "サーバー接続"} '
                    '(切り替えるとすぐ保存されます)',
                children: [
                  for (final mode in RunMode.values)
                    RadioListTile<RunMode>(
                      value: mode,
                      groupValue: appDraft.mode,
                      onChanged: (v) {
                        if (v == null) return;
                        _changeAppSettings((s) => s.copyWith(mode: v));
                      },
                      title: Text(mode.label, style: const TextStyle(fontSize: 13)),
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      dense: true,
                    ),
                  if (appDraft.mode == RunMode.remote) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _serverUrlController,
                      decoration: const InputDecoration(
                        labelText: 'サーバーのURL',
                        hintText: 'wss://example.duckdns.org/ws',
                        isDense: true,
                      ),
                      onChanged: (_) => unawaited(_persistAppSettings(appDraft)),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _serverTokenController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '接続トークン',
                        isDense: true,
                      ),
                      onChanged: (_) => unawaited(_persistAppSettings(appDraft)),
                    ),
                    const _Hint(
                      '接続トークンは、サーバーを立てたときに deploy/setup.sh が作る '
                      'BOT_TOKEN と同じ値です (サーバーの /etc/mexc-bot/env に入っています)。\n'
                      'サーバーをまだ立てていないなら、ローカル実行のままにしてください。',
                    ),
                    _CompactSwitch(
                      label: '自己署名証明書を許可する',
                      subtitle: '通信の検証を外すので、試験用以外では切っておいてください。',
                      value: appDraft.allowSelfSignedCertificate,
                      onChanged: (v) => _changeAppSettings(
                        (s) => s.copyWith(allowSelfSignedCertificate: v),
                      ),
                    ),
                  ],
                  if (TrayService.isSupported)
                    _CompactSwitch(
                      label: 'ウィンドウを閉じてもタスクトレイに残す',
                      value: appDraft.keepRunningInTray,
                      onChanged: (v) =>
                          _changeAppSettings((s) => s.copyWith(keepRunningInTray: v)),
                    ),
                  _CompactSwitch(
                    label: 'アプリ起動と同時にボットを動かす',
                    subtitle: '入れておくと、開いた瞬間から本番の注文が出ます。',
                    value: appDraft.autoStartBot,
                    onChanged: (v) =>
                        _changeAppSettings((s) => s.copyWith(autoStartBot: v)),
                  ),
                ],
              ),

              _Section(
                title: '取引所のAPIキー',
                description: state.credentials.isEmpty ? '未設定' : '設定済み',
                children: [
                  TextField(
                    controller: _apiKeyController,
                    decoration: const InputDecoration(
                      labelText: 'API Key',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _apiSecretController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Secret',
                      isDense: true,
                    ),
                  ),
                  const _Hint(
                    'IPホワイトリストを設定しないキーは90日で失効します。'
                    '先物の発注権限とKYCが必要です。',
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () async {
                        await state.clearCredentials();
                        _apiKeyController.clear();
                        _apiSecretController.clear();
                      },
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('保存したキーを消す'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 80),
            ],
          ),
        ),
        Material(
          elevation: 8,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              children: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _draft = const StrategyConfig();
                    });
                  },
                  child: const Text('既定値', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: _reload,
                  child: const Text('取り消す', style: TextStyle(fontSize: 12)),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('保存して反映'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 片方向ぶんの設定。ショートとロングで並びを揃え、左右で見比べられるようにする。
class _SideCard extends StatelessWidget {
  const _SideCard({
    required this.side,
    required this.showLimitOffset,
    required this.showFunding,
    required this.onChanged,
  });

  final SideConfig side;
  final bool showLimitOffset;
  final bool showFunding;
  final ValueChanged<SideConfig> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isShort = side.direction.isShort;
    final color = isShort ? Colors.redAccent : Colors.green;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isShort ? Icons.trending_down : Icons.trending_up,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  side.direction.label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
              SizedBox(
                height: 24,
                child: Switch(
                  value: side.enabled,
                  onChanged: (v) => onChanged(side.copyWith(enabled: v)),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          Text(
            isShort ? '+σ を上抜けたら売る' : '-σ を下抜けたら買う',
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
          ),
          const SizedBox(height: 8),
          _NumberField(
            label: 'RSI',
            suffix: isShort ? '以上' : '以下',
            value: side.rsiThreshold,
            dense: true,
            onChanged: (v) => onChanged(side.copyWith(rsiThreshold: v)),
          ),
          _NumberField(
            label: 'σ倍率',
            value: side.bbSigma,
            dense: true,
            onChanged: (v) => onChanged(side.copyWith(bbSigma: v)),
          ),
          _NumberField(
            label: 'レバ',
            suffix: '倍',
            value: side.leverage.toDouble(),
            integer: true,
            dense: true,
            onChanged: (v) => onChanged(side.copyWith(leverage: v.toInt())),
          ),
          _NumberField(
            label: '証拠金',
            suffix: 'USDT',
            value: side.marginPerTradeUsdt,
            dense: true,
            onChanged: (v) => onChanged(side.copyWith(marginPerTradeUsdt: v)),
          ),
          if (showLimitOffset)
            _NumberField(
              label: '指値幅',
              suffix: '%',
              value: side.limitOffsetPercent,
              dense: true,
              onChanged: (v) => onChanged(side.copyWith(limitOffsetPercent: v)),
            ),
          _NumberField(
            label: '利確係数',
            value: side.takeProfitFactor,
            dense: true,
            onChanged: (v) => onChanged(side.copyWith(takeProfitFactor: v)),
          ),
          _NumberField(
            label: '利確下限',
            suffix: '%',
            value: side.minTakeProfitPercent,
            dense: true,
            onChanged: (v) => onChanged(side.copyWith(minTakeProfitPercent: v)),
          ),
          _MiniSwitch(
            label: '行きすぎ逆張り',
            value: side.bandBreakoutEntryEnabled,
            onChanged: (v) =>
                onChanged(side.copyWith(bandBreakoutEntryEnabled: v)),
          ),
          if (side.bandBreakoutEntryEnabled)
            _NumberField(
              label: '逆張り幅',
              suffix: '%',
              value: side.bandBreakoutPercent,
              dense: true,
              onChanged: (v) =>
                  onChanged(side.copyWith(bandBreakoutPercent: v)),
            ),
          _MiniSwitch(
            label: '損切り',
            value: side.stopLossEnabled,
            onChanged: (v) => onChanged(side.copyWith(stopLossEnabled: v)),
          ),
          if (side.stopLossEnabled)
            _NumberField(
              label: '損切り幅',
              suffix: '%',
              value: side.stopLossPercent,
              dense: true,
              onChanged: (v) => onChanged(side.copyWith(stopLossPercent: v)),
            ),
          if (showFunding) ...[
            _NumberField(
              label: '調達負担',
              suffix: '%',
              value: side.maxFundingBurdenPercent,
              dense: true,
              onChanged: (v) =>
                  onChanged(side.copyWith(maxFundingBurdenPercent: v)),
            ),
            _NumberField(
              label: '調達間隔',
              suffix: 'h',
              value: side.minFundingIntervalHours.toDouble(),
              integer: true,
              dense: true,
              onChanged: (v) =>
                  onChanged(side.copyWith(minFundingIntervalHours: v.toInt())),
            ),
          ],
        ],
      ),
    );
  }
}

/// 畳めるひとまとまり。開いているものだけ場所を取る。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.description,
    this.initiallyExpanded = false,
  });

  final String title;
  final String? description;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Theme(
        // 開閉したときに出る境界線を消して、見た目を落ち着かせる。
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: description == null
              ? null
              : Text(
                  description!,
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                ),
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

/// 補足の文。小さく出して場所を取らせない。
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
      ),
    );
  }
}

/// 説明つきの入り切り。SwitchListTile より縦に詰めてある。
class _CompactSwitch extends StatelessWidget {
  const _CompactSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: const TextStyle(fontSize: 13)),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: 28,
              child: Switch(
                value: value,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2列の中に入れる、いちばん小さい入り切り。
class _MiniSwitch extends StatelessWidget {
  const _MiniSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 11)),
            ),
            SizedBox(
              height: 24,
              child: Switch(
                value: value,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 数値を 1 つ編集するための入力欄。
class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.suffix,
    this.helper,
    this.integer = false,
    this.dense = false,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final String? suffix;
  final String? helper;
  final bool integer;

  /// 2列に並べるときの詰めた見た目。説明は出さない。
  final bool dense;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _controller = TextEditingController(
    text: _format(widget.value),
  );

  String _format(double value) =>
      widget.integer ? value.toInt().toString() : _trim(value);

  static String _trim(double value) {
    var text = value.toString();
    if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
    return text;
  }

  @override
  void didUpdateWidget(_NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外から値が変わったとき (既定値に戻す・そろえる等) だけ追従する。
    if (widget.value != oldWidget.value &&
        double.tryParse(_controller.text) != widget.value) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: widget.dense ? 6 : 12),
      child: TextField(
        controller: _controller,
        style: TextStyle(fontSize: widget.dense ? 13 : 14),
        keyboardType: TextInputType.numberWithOptions(
          decimal: !widget.integer,
        ),
        inputFormatters: [
          FilteringTextInputFormatter.allow(
            widget.integer ? RegExp(r'[0-9]') : RegExp(r'[0-9.]'),
          ),
        ],
        decoration: InputDecoration(
          labelText: widget.label,
          labelStyle: TextStyle(fontSize: widget.dense ? 12 : 14),
          suffixText: widget.suffix,
          suffixStyle: TextStyle(fontSize: widget.dense ? 10 : 12),
          helperText: widget.dense ? null : widget.helper,
          helperMaxLines: 3,
          isDense: true,
          contentPadding: widget.dense
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 10)
              : null,
        ),
        onChanged: (text) {
          final value = double.tryParse(text);
          if (value != null) widget.onChanged(value);
        },
      ),
    );
  }
}
