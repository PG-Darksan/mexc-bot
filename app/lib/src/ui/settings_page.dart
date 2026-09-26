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

  void _updateShort(SideConfig Function(SideConfig) change) =>
      _update((c) => c.withSide(change(c.short)));

  void _updateLong(SideConfig Function(SideConfig) change) =>
      _update((c) => c.withSide(change(c.long)));

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
                title: 'ショートとロングの条件',
                description:
                    '同じ項目を左右に並べてあります。'
                    'RSI のしきい値だけ向きが逆 (既定 97 / 3) です。',
                initiallyExpanded: true,
                children: [
                  _PairSwitch(
                    title: 'この向きで建てる',
                    shortValue: draft.short.enabled,
                    longValue: draft.long.enabled,
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(enabled: v)),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(enabled: v)),
                  ),
                  _PairField(
                    title: 'RSIのしきい値',
                    shortSuffix: '以上',
                    longSuffix: '以下',
                    shortValue: draft.short.rsiThreshold,
                    longValue: draft.long.rsiThreshold,
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(rsiThreshold: v)),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(rsiThreshold: v)),
                  ),
                  _PairField(
                    title: 'σ倍率 (ボリンジャーバンドの幅)',
                    shortValue: draft.short.bbSigma,
                    longValue: draft.long.bbSigma,
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(bbSigma: v)),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(bbSigma: v)),
                  ),
                  _PairField(
                    title: 'レバレッジ [倍]',
                    integer: true,
                    shortValue: draft.short.leverage.toDouble(),
                    longValue: draft.long.leverage.toDouble(),
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(leverage: v.toInt())),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(leverage: v.toInt())),
                  ),
                  _PairField(
                    title: '1回あたりの証拠金 [USDT]',
                    shortValue: draft.short.marginPerTradeUsdt,
                    longValue: draft.long.marginPerTradeUsdt,
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(marginPerTradeUsdt: v)),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(marginPerTradeUsdt: v)),
                  ),
                  if (limitOrder)
                    _PairField(
                      title: '指値を現在値から離す幅 [%]',
                      shortValue: draft.short.limitOffsetPercent,
                      longValue: draft.long.limitOffsetPercent,
                      onShortChanged: (v) => _updateShort(
                        (x) => x.copyWith(limitOffsetPercent: v),
                      ),
                      onLongChanged: (v) =>
                          _updateLong((x) => x.copyWith(limitOffsetPercent: v)),
                    ),
                  _PairField(
                    title: '利確の係数',
                    shortValue: draft.short.takeProfitFactor,
                    longValue: draft.long.takeProfitFactor,
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(takeProfitFactor: v)),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(takeProfitFactor: v)),
                  ),
                  const _Hint(
                    '0.5 なら、行きすぎた分の半分まで戻ったところで利確します。'
                    '0 より大きく 1 未満で入れてください。',
                  ),
                  _PairField(
                    title: '利確幅の下限 [%]',
                    shortValue: draft.short.minTakeProfitPercent,
                    longValue: draft.long.minTakeProfitPercent,
                    onShortChanged: (v) => _updateShort(
                      (x) => x.copyWith(minTakeProfitPercent: v),
                    ),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(minTakeProfitPercent: v)),
                  ),
                  _PairSwitch(
                    title: '行きすぎたら RSI を見ない',
                    shortValue: draft.short.bandBreakoutEntryEnabled,
                    longValue: draft.long.bandBreakoutEntryEnabled,
                    onShortChanged: (v) => _updateShort(
                      (x) => x.copyWith(bandBreakoutEntryEnabled: v),
                    ),
                    onLongChanged: (v) => _updateLong(
                      (x) => x.copyWith(bandBreakoutEntryEnabled: v),
                    ),
                  ),
                  if (draft.short.bandBreakoutEntryEnabled ||
                      draft.long.bandBreakoutEntryEnabled)
                    _PairField(
                      title: 'σから離れた幅 [%]',
                      shortValue: draft.short.bandBreakoutPercent,
                      longValue: draft.long.bandBreakoutPercent,
                      onShortChanged: (v) => _updateShort(
                        (x) => x.copyWith(bandBreakoutPercent: v),
                      ),
                      onLongChanged: (v) => _updateLong(
                        (x) => x.copyWith(bandBreakoutPercent: v),
                      ),
                    ),
                  if (draft.fundingFilterEnabled) ...[
                    _PairField(
                      title: '資金調達 負担率の上限 [%]',
                      shortValue: draft.short.maxFundingBurdenPercent,
                      longValue: draft.long.maxFundingBurdenPercent,
                      onShortChanged: (v) => _updateShort(
                        (x) => x.copyWith(maxFundingBurdenPercent: v),
                      ),
                      onLongChanged: (v) => _updateLong(
                        (x) => x.copyWith(maxFundingBurdenPercent: v),
                      ),
                    ),
                    _PairField(
                      title: '資金調達 間隔の下限 [時間]',
                      integer: true,
                      shortValue: draft.short.minFundingIntervalHours
                          .toDouble(),
                      longValue: draft.long.minFundingIntervalHours.toDouble(),
                      onShortChanged: (v) => _updateShort(
                        (x) => x.copyWith(minFundingIntervalHours: v.toInt()),
                      ),
                      onLongChanged: (v) => _updateLong(
                        (x) => x.copyWith(minFundingIntervalHours: v.toInt()),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _update(
                            (c) => c.copyWith(long: c.short.mirrored()),
                          ),
                          child: const Text(
                            'ショート → ロング',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _update(
                            (c) => c.copyWith(short: c.long.mirrored()),
                          ),
                          child: const Text(
                            'ロング → ショート',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const _Hint('そろえると、RSI のしきい値だけ 100 から引いた値になります。'),
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
                          label: Text(
                            tf.label,
                            style: const TextStyle(fontSize: 12),
                          ),
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
                    subtitle: '切るとクロスマージン。損切りを置かないので分離を推奨。',
                    value: draft.useIsolatedMargin,
                    onChanged: (v) =>
                        _update((c) => c.copyWith(useIsolatedMargin: v)),
                  ),
                ],
              ),

              _Section(
                title: '利確の出し方',
                description: '係数と下限は方向ごとの設定にあります。損切りは置きません。',
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
                    subtitle:
                        'その方向が支払う側のときだけ効きます。'
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
                            (c) =>
                                c.copyWith(reentryCooldownMinutes: v.toInt()),
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
                description:
                    '${appDraft.mode == RunMode.local ? "ローカル実行" : "サーバー接続"} '
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
                      title: Text(
                        mode.label,
                        style: const TextStyle(fontSize: 13),
                      ),
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
                      onChanged: (_) =>
                          unawaited(_persistAppSettings(appDraft)),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _serverTokenController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '接続トークン',
                        isDense: true,
                      ),
                      onChanged: (_) =>
                          unawaited(_persistAppSettings(appDraft)),
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
                      onChanged: (v) => _changeAppSettings(
                        (s) => s.copyWith(keepRunningInTray: v),
                      ),
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

/// 1 つの項目を、ショートとロングで横に並べて出す。
class _PairField extends StatelessWidget {
  const _PairField({
    required this.title,
    required this.shortValue,
    required this.longValue,
    required this.onShortChanged,
    required this.onLongChanged,
    this.shortSuffix,
    this.longSuffix,
    this.integer = false,
  });

  final String title;
  final double shortValue;
  final double longValue;
  final ValueChanged<double> onShortChanged;
  final ValueChanged<double> onLongChanged;
  final String? shortSuffix;
  final String? longSuffix;
  final bool integer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _NumberField(
                  label: 'ショート',
                  suffix: shortSuffix,
                  value: shortValue,
                  integer: integer,
                  dense: true,
                  onChanged: onShortChanged,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _NumberField(
                  label: 'ロング',
                  suffix: longSuffix,
                  value: longValue,
                  integer: integer,
                  dense: true,
                  onChanged: onLongChanged,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 入り切りを、ショートとロングで横に並べて出す。
class _PairSwitch extends StatelessWidget {
  const _PairSwitch({
    required this.title,
    required this.shortValue,
    required this.longValue,
    required this.onShortChanged,
    required this.onLongChanged,
  });

  final String title;
  final bool shortValue;
  final bool longValue;
  final ValueChanged<bool> onShortChanged;
  final ValueChanged<bool> onLongChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
          Row(
            children: [
              Expanded(
                child: _MiniSwitch(
                  label: 'ショート',
                  value: shortValue,
                  onChanged: onShortChanged,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniSwitch(
                  label: 'ロング',
                  value: longValue,
                  onChanged: onLongChanged,
                ),
              ),
            ],
          ),
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
            Expanded(child: Text(label, style: const TextStyle(fontSize: 11))),
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
        keyboardType: TextInputType.numberWithOptions(decimal: !widget.integer),
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
