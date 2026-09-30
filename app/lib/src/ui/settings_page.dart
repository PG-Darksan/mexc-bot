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
/// 出来高の下限・時間軸・指標の期間も方向ごとなので、いちばん上にある。
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

  /// 「接続を試す」の結果。押すまでは null。
  ServerCheckResult? _checkResult;
  bool _checking = false;

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
      _checkResult = null;
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

  /// URL とトークンを保存して、つなぎ直す。
  ///
  /// 1 文字ごとに保存すると、そのたびに接続をやり直して中途半端な
  /// トークンで弾かれ続ける。まとめて確定させるための口。
  Future<void> _applyConnection() async {
    final state = AppScope.of(context);
    setState(() => _checkResult = null);
    await _persistAppSettings(appDraft);
    await state.reconnect();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('接続設定を保存してつなぎ直しました')));
  }

  /// URL とトークンのどちらが悪いのかを切り分ける。
  Future<void> _testConnection() async {
    setState(() {
      _checking = true;
      _checkResult = null;
    });
    final result = await checkBotServer(
      url: _serverUrlController.text,
      token: _serverTokenController.text,
      allowSelfSignedCertificate: appDraft.allowSelfSignedCertificate,
    );
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checkResult = result;
    });
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
                    '出来高・時間軸・指標の期間も向きごとに決められます。'
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
                    title: '監視する銘柄: 24h出来高の下限',
                    shortSuffix: 'M USDT',
                    longSuffix: 'M USDT',
                    shortValue: draft.short.minAmount24Usdt / 1000000,
                    longValue: draft.long.minAmount24Usdt / 1000000,
                    onShortChanged: (v) => _updateShort(
                      (x) => x.copyWith(minAmount24Usdt: v * 1000000),
                    ),
                    onLongChanged: (v) => _updateLong(
                      (x) => x.copyWith(minAmount24Usdt: v * 1000000),
                    ),
                  ),
                  const _Hint(
                    '1 M = 100万 USDT。既定 5 M。\n'
                    '見る銘柄はこの下限だけで決まります。銘柄数に上限は無く、'
                    '手で選んだり外したりもしません。'
                    'ショートとロングで違う値にすると、それぞれの下限で絞られます。',
                  ),
                  _PairTimeframes(
                    shortValue: draft.short.timeframes,
                    longValue: draft.long.timeframes,
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(timeframes: v)),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(timeframes: v)),
                  ),
                  const _Hint('選んだ時間軸それぞれで独立に判定します。'),
                  _PairField(
                    title: 'BB期間',
                    integer: true,
                    shortValue: draft.short.bbPeriod.toDouble(),
                    longValue: draft.long.bbPeriod.toDouble(),
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(bbPeriod: v.toInt())),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(bbPeriod: v.toInt())),
                  ),
                  _PairField(
                    title: 'RSI期間',
                    integer: true,
                    shortValue: draft.short.rsiPeriod.toDouble(),
                    longValue: draft.long.rsiPeriod.toDouble(),
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(rsiPeriod: v.toInt())),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(rsiPeriod: v.toInt())),
                  ),
                  _PairField(
                    title: 'EMA期間 (利確の基準)',
                    integer: true,
                    shortValue: draft.short.emaPeriod.toDouble(),
                    longValue: draft.long.emaPeriod.toDouble(),
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(emaPeriod: v.toInt())),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(emaPeriod: v.toInt())),
                  ),
                  _PairField(
                    title: '保持する足',
                    integer: true,
                    shortSuffix: '本',
                    longSuffix: '本',
                    shortValue: draft.short.historyBars.toDouble(),
                    longValue: draft.long.historyBars.toDouble(),
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(historyBars: v.toInt())),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(historyBars: v.toInt())),
                  ),
                  const _Hint('RSI は Wilder 平滑 (TradingView と同じ計算) です。'),
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
                    shortValue: draft.short.minFundingIntervalHours.toDouble(),
                    longValue: draft.long.minFundingIntervalHours.toDouble(),
                    onShortChanged: (v) => _updateShort(
                      (x) => x.copyWith(minFundingIntervalHours: v.toInt()),
                    ),
                    onLongChanged: (v) => _updateLong(
                      (x) => x.copyWith(minFundingIntervalHours: v.toInt()),
                    ),
                  ),
                  const _Hint(
                    'この 2 つは、その向きが資金調達を「支払う側」のときだけ効きます。'
                    '受け取る側なら率が大きくても見送りません。',
                  ),
                  _PairSwitch(
                    title: '含み損が出たら買い足し / 売り足しする',
                    shortValue: draft.short.addOnEnabled,
                    longValue: draft.long.addOnEnabled,
                    onShortChanged: (v) =>
                        _updateShort((x) => x.copyWith(addOnEnabled: v)),
                    onLongChanged: (v) =>
                        _updateLong((x) => x.copyWith(addOnEnabled: v)),
                  ),
                  if (draft.short.addOnEnabled || draft.long.addOnEnabled) ...[
                    _PairField(
                      title: '指値を置く含み損 [%] (証拠金に対して)',
                      shortValue: draft.short.addOnLossPercent,
                      longValue: draft.long.addOnLossPercent,
                      onShortChanged: (v) =>
                          _updateShort((x) => x.copyWith(addOnLossPercent: v)),
                      onLongChanged: (v) =>
                          _updateLong((x) => x.copyWith(addOnLossPercent: v)),
                    ),
                    _PairField(
                      title: '残り資金のうち使う割合 [%]',
                      shortValue: draft.short.addOnBudgetPercent,
                      longValue: draft.long.addOnBudgetPercent,
                      onShortChanged: (v) => _updateShort(
                        (x) => x.copyWith(addOnBudgetPercent: v),
                      ),
                      onLongChanged: (v) =>
                          _updateLong((x) => x.copyWith(addOnBudgetPercent: v)),
                    ),
                    const _Hint(
                      '成行で建てた直後、口座に残っている USDT のこの割合を証拠金にして、'
                      '含み損がこの % になる価格に同じ向きの指値を置きます '
                      '(ロングは建値の下に買い、ショートは建値の上に売り。'
                      'レバレッジ 1 倍なら建値からの値動き % と同じ)。\n'
                      '約定すると平均建値が有利な側に寄ります。利確の目標は動かしません。'
                      '指値を置いた分の資金は凍結されるので、100% にすると次の銘柄に'
                      '回す資金が無くなります。決済したあとは指値を取り消しますが、'
                      '次の判定までの間 (最大で判定間隔ぶん) は残ることがあります。',
                    ),
                  ],
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
                    '決済してからは「再エントリー待ち」の間だけ間を置きます。\n'
                    '新規建ては成行・分離マージン、利確は発注と同時に取引所へ預け、'
                    '資金調達率のフィルタは常に効きます (切り替えはありません)。\n'
                    'MEXC 側も「一方向モード」にしてください。'
                    '食い違うと決済注文が通らず、起動時に警告が出ます。',
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
                initiallyExpanded: appDraft.mode == RunMode.remote,
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
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'サーバーのURL',
                        hintText: 'wss://example.duckdns.org/ws',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _serverTokenController,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: '接続トークン',
                        isDense: true,
                      ),
                      onSubmitted: (_) => unawaited(_applyConnection()),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: () => unawaited(_applyConnection()),
                            icon: const Icon(Icons.link, size: 16),
                            label: const Text(
                              '保存してつなぎ直す',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _checking
                                ? null
                                : () => unawaited(_testConnection()),
                            icon: _checking
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.network_check, size: 16),
                            label: const Text(
                              '接続を試す',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                    _ConnectionStatus(
                      connection: state.connection,
                      error: state.connectionError,
                      check: _checkResult,
                    ),
                    const _Hint(
                      'URL は ws:// か wss:// で始め、最後に /ws を付けます '
                      '(例: ws://192.168.0.10:8080/ws)。'
                      'http:// と書いた場合や /ws を省いた場合はこちらで直します。\n'
                      '接続トークンは、サーバーを立てたときに deploy/setup.sh が作る '
                      'BOT_TOKEN と同じ値です (サーバーの /etc/mexc-bot/env に'
                      '入っています)。前後の空白や改行は取り除いて送ります。\n'
                      'URL とトークンは入れ終わってから「保存してつなぎ直す」を'
                      '押してください。サーバーをまだ立てていないなら、'
                      'ローカル実行のままにしてください。',
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
                    '先物の発注権限とKYCが必要です。\n'
                    'サーバー接続のときも、ここに入れた鍵で残高だけは端末が'
                    '直接取ります (サーバーを経由するより速い)。'
                    '注文はサーバー側の鍵で出します。',
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

/// いまの接続の様子と、「接続を試す」の結果を出す。
class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({
    required this.connection,
    required this.error,
    required this.check,
  });

  final ControllerConnection connection;
  final String? error;
  final ServerCheckResult? check;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (connection) {
      ControllerConnection.connected => ('つながっています', Colors.green),
      ControllerConnection.connecting => ('つなぎ中', Colors.orange),
      ControllerConnection.error => ('つながっていません', theme.colorScheme.error),
      ControllerConnection.disconnected => ('未接続', theme.colorScheme.outline),
    };
    final result = check;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          if (connection == ControllerConnection.error && error != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                error!,
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
              ),
            ),
          if (result != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    result.ok ? Icons.check_circle : Icons.error_outline,
                    size: 14,
                    color: result.ok ? Colors.green : theme.colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      result.message,
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
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

/// 判定する時間軸を、ショートとロングの 2 列で選ばせる。
///
/// 1 行 1 時間軸の表にして、その場で見比べながら入れられるようにする。
class _PairTimeframes extends StatelessWidget {
  const _PairTimeframes({
    required this.shortValue,
    required this.longValue,
    required this.onShortChanged,
    required this.onLongChanged,
  });

  final List<Timeframe> shortValue;
  final List<Timeframe> longValue;
  final ValueChanged<List<Timeframe>> onShortChanged;
  final ValueChanged<List<Timeframe>> onLongChanged;

  static const double _columnWidth = 64;

  /// [tf] を入れた / 外した新しい並びを返す。短い足から順に並べる。
  static List<Timeframe> _toggled(
    List<Timeframe> current,
    Timeframe tf,
    bool selected,
  ) {
    final list = [...current];
    if (selected) {
      if (!list.contains(tf)) list.add(tf);
      list.sort((a, b) => a.seconds.compareTo(b.seconds));
    } else {
      list.remove(tf);
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headStyle = theme.textTheme.bodySmall?.copyWith(fontSize: 11);

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '判定に使う時間軸',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
          Row(
            children: [
              const Expanded(child: SizedBox()),
              SizedBox(
                width: _columnWidth,
                child: Text('ショート', style: headStyle, textAlign: TextAlign.center),
              ),
              SizedBox(
                width: _columnWidth,
                child: Text('ロング', style: headStyle, textAlign: TextAlign.center),
              ),
            ],
          ),
          for (final tf in Timeframe.values)
            Row(
              children: [
                Expanded(
                  child: Text(tf.label, style: const TextStyle(fontSize: 12)),
                ),
                _Cell(
                  value: shortValue.contains(tf),
                  onChanged: (v) =>
                      onShortChanged(_toggled(shortValue, tf, v)),
                ),
                _Cell(
                  value: longValue.contains(tf),
                  onChanged: (v) => onLongChanged(_toggled(longValue, tf, v)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 時間軸の表の中の、入れる / 外すを 1 つ選ぶところ。
class _Cell extends StatelessWidget {
  const _Cell({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _PairTimeframes._columnWidth,
      height: 30,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Center(
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
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
