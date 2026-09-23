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
/// 既定値は利用者が指定した条件そのもの。ここで自由に変えられる。
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
  final _manualSymbolsController = TextEditingController();
  final _excludedSymbolsController = TextEditingController();
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
      _manualSymbolsController.text = state.config.manualSymbols.join(', ');
      _excludedSymbolsController.text = state.config.excludedSymbols.join(', ');
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _apiSecretController.dispose();
    _serverUrlController.dispose();
    _serverTokenController.dispose();
    _manualSymbolsController.dispose();
    _excludedSymbolsController.dispose();
    super.dispose();
  }

  StrategyConfig get draft => _draft!;
  AppSettings get appDraft => _appDraft!;

  void _update(StrategyConfig Function(StrategyConfig) change) =>
      setState(() => _draft = change(draft));

  void _updateApp(AppSettings Function(AppSettings) change) =>
      setState(() => _appDraft = change(appDraft));

  Future<void> _save() async {
    final state = AppScope.of(context);
    final config = draft.copyWith(
      manualSymbols: _splitSymbols(_manualSymbolsController.text),
      excludedSymbols: _splitSymbols(_excludedSymbolsController.text),
    );
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

  List<String> _splitSymbols(String raw) => raw
      .split(RegExp(r'[,\s]+'))
      .map((s) => s.trim().toUpperCase())
      .where((s) => s.isNotEmpty)
      .toList();

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
            padding: const EdgeInsets.all(16),
            children: [
              _Section(
                title: '動かし方',
                description:
                    'ローカル実行はこの端末だけで完結します。アプリを閉じると止まるので、'
                    '24時間動かすならサーバー接続を使ってください。',
                children: [
                  for (final mode in RunMode.values)
                    RadioListTile<RunMode>(
                      value: mode,
                      groupValue: appDraft.mode,
                      onChanged: (v) =>
                          _updateApp((s) => s.copyWith(mode: v)),
                      title: Text(mode.label),
                      dense: true,
                    ),
                  if (appDraft.mode == RunMode.remote) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _serverUrlController,
                      decoration: const InputDecoration(
                        labelText: 'サーバーのURL',
                        hintText: 'wss://example.duckdns.org:8443/ws',
                        helperText: 'TLS を使うなら wss://、同じ端末で試すなら ws://127.0.0.1:8080/ws',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _serverTokenController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '接続トークン',
                        helperText: 'サーバーの BOT_TOKEN と同じ値',
                      ),
                    ),
                    SwitchListTile(
                      value: appDraft.allowSelfSignedCertificate,
                      onChanged: (v) => _updateApp(
                        (s) => s.copyWith(allowSelfSignedCertificate: v),
                      ),
                      title: const Text('自己署名証明書を許可する'),
                      subtitle: const Text(
                        '通信の検証を外すので、試験用以外では切っておいてください。',
                      ),
                      dense: true,
                    ),
                  ],
                  if (TrayService.isSupported)
                    SwitchListTile(
                      value: appDraft.keepRunningInTray,
                      onChanged: (v) =>
                          _updateApp((s) => s.copyWith(keepRunningInTray: v)),
                      title: const Text('ウィンドウを閉じてもタスクトレイに残す'),
                      subtitle: const Text(
                        'ローカル実行でボットを止めたくないときに入れておきます。',
                      ),
                      dense: true,
                    ),
                  SwitchListTile(
                    value: appDraft.autoStartBot,
                    onChanged: (v) =>
                        _updateApp((s) => s.copyWith(autoStartBot: v)),
                    title: const Text('アプリ起動と同時にボットを動かす'),
                    dense: true,
                  ),
                ],
              ),

              _Section(
                title: '取引所のAPIキー',
                description: appDraft.mode == RunMode.remote
                    ? 'サーバー接続モードでは、APIキーはサーバー側の環境変数で設定します。'
                          'ここでの入力はローカル実行のときだけ使われます。'
                    : 'IPホワイトリストを設定しないキーは90日で失効します。'
                          '先物の発注権限とKYCが必要です。',
                children: [
                  TextField(
                    controller: _apiKeyController,
                    decoration: const InputDecoration(labelText: 'API Key'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _apiSecretController,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'API Secret'),
                  ),
                  const SizedBox(height: 8),
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

              _Section(
                title: '監視する銘柄',
                children: [
                  _NumberField(
                    label: '24時間売買代金の下限',
                    suffix: 'USDT',
                    value: draft.minAmount24Usdt,
                    helper: '既定 5,000,000。これを下回る銘柄は判定しません。',
                    onChanged: (v) =>
                        _update((c) => c.copyWith(minAmount24Usdt: v)),
                  ),
                  _NumberField(
                    label: '監視する上限銘柄数',
                    value: draft.maxWatchSymbols.toDouble(),
                    integer: true,
                    helper: '売買代金の多い順に選びます。',
                    onChanged: (v) =>
                        _update((c) => c.copyWith(maxWatchSymbols: v.toInt())),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<SymbolSelectionMode>(
                    segments: const [
                      ButtonSegment(
                        value: SymbolSelectionMode.auto,
                        label: Text('出来高で自動選定'),
                      ),
                      ButtonSegment(
                        value: SymbolSelectionMode.manual,
                        label: Text('自分で指定'),
                      ),
                    ],
                    selected: {draft.symbolMode},
                    onSelectionChanged: (s) =>
                        _update((c) => c.copyWith(symbolMode: s.first)),
                  ),
                  if (draft.symbolMode == SymbolSelectionMode.manual) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _manualSymbolsController,
                      decoration: const InputDecoration(
                        labelText: '監視する銘柄',
                        hintText: 'BTC_USDT, ETH_USDT',
                      ),
                      maxLines: 2,
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _excludedSymbolsController,
                    decoration: const InputDecoration(
                      labelText: '常に除外する銘柄',
                      hintText: 'AKE_USDT, ONE_USDT',
                    ),
                    maxLines: 2,
                  ),
                ],
              ),

              _Section(
                title: '判定に使う時間軸',
                description: '選んだ時間軸それぞれで独立に判定します。'
                    '進行中の足も含めて、下の判定間隔ごとに毎回計算し直します。',
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tf in Timeframe.values)
                        FilterChip(
                          label: Text(tf.label),
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
                title: '指標',
                description: '期間はショートとロングで共通です。'
                    'しきい値とσ倍率は方向ごとに下で決めます。',
                children: [
                  _NumberField(
                    label: 'ボリンジャーバンドの期間',
                    value: draft.bbPeriod.toDouble(),
                    integer: true,
                    onChanged: (v) =>
                        _update((c) => c.copyWith(bbPeriod: v.toInt())),
                  ),
                  _NumberField(
                    label: 'RSIの期間',
                    value: draft.rsiPeriod.toDouble(),
                    integer: true,
                    helper: 'Wilder平滑 (TradingView と同じ計算) です。',
                    onChanged: (v) =>
                        _update((c) => c.copyWith(rsiPeriod: v.toInt())),
                  ),
                  _NumberField(
                    label: 'EMAの期間',
                    value: draft.emaPeriod.toDouble(),
                    integer: true,
                    helper: '利確目標の基準にする移動平均です。',
                    onChanged: (v) =>
                        _update((c) => c.copyWith(emaPeriod: v.toInt())),
                  ),
                  _NumberField(
                    label: '保持する足の本数',
                    value: draft.historyBars.toDouble(),
                    integer: true,
                    helper: '多いほど指標が安定します (既定 300)。',
                    onChanged: (v) =>
                        _update((c) => c.copyWith(historyBars: v.toInt())),
                  ),
                ],
              ),

              _Section(
                title: 'ショートとロング',
                description: '同じ項目を左右に並べてあります。既定値はそろえてあり、'
                    'RSI のしきい値だけ向きが逆 (ショート 97 以上 / ロング 3 以下) です。',
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final limit = draft.orderType == EntryOrderType.limit;
                      final short = _SideCard(
                        side: draft.short,
                        showLimitOffset: limit,
                        showFunding: draft.fundingFilterEnabled,
                        onChanged: (side) => _update((c) => c.withSide(side)),
                      );
                      final long = _SideCard(
                        side: draft.long,
                        showLimitOffset: limit,
                        showFunding: draft.fundingFilterEnabled,
                        onChanged: (side) => _update((c) => c.withSide(side)),
                      );
                      // 画面が狭いときだけ縦に積む。広ければ左右に並べる。
                      if (constraints.maxWidth < 720) {
                        return Column(
                          children: [short, const SizedBox(height: 16), long],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: short),
                          const SizedBox(width: 16),
                          Expanded(child: long),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _update(
                          (c) => c.copyWith(long: c.short.mirrored()),
                        ),
                        icon: const Icon(Icons.east, size: 16),
                        label: const Text('ショートの値をロングへ'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _update(
                          (c) => c.copyWith(short: c.long.mirrored()),
                        ),
                        icon: const Icon(Icons.west, size: 16),
                        label: const Text('ロングの値をショートへ'),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'そろえると、RSI のしきい値だけ 100 から引いた値に入れ替わります。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),

              _Section(
                title: 'エントリー',
                description: 'レバレッジ・証拠金・指値の幅は方向ごとの設定にあります。',
                children: [
                  const SizedBox(height: 8),
                  SegmentedButton<EntryOrderType>(
                    segments: const [
                      ButtonSegment(
                        value: EntryOrderType.market,
                        label: Text('成行'),
                      ),
                      ButtonSegment(
                        value: EntryOrderType.limit,
                        label: Text('指値'),
                      ),
                    ],
                    selected: {draft.orderType},
                    onSelectionChanged: (s) =>
                        _update((c) => c.copyWith(orderType: s.first)),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<PositionMode>(
                    segments: const [
                      ButtonSegment(
                        value: PositionMode.hedge,
                        label: Text('ヘッジモード'),
                      ),
                      ButtonSegment(
                        value: PositionMode.oneWay,
                        label: Text('一方向モード'),
                      ),
                    ],
                    selected: {draft.positionMode},
                    onSelectionChanged: (s) =>
                        _update((c) => c.copyWith(positionMode: s.first)),
                  ),
                  SwitchListTile(
                    value: draft.useIsolatedMargin,
                    onChanged: (v) =>
                        _update((c) => c.copyWith(useIsolatedMargin: v)),
                    title: const Text('分離マージンを使う'),
                    subtitle: const Text(
                      '切るとクロスマージンになります。損切りを置かない運用では分離を推奨します。',
                    ),
                    dense: true,
                  ),
                ],
              ),

              _Section(
                title: '利確の出し方',
                description:
                    '利確は「検知した瞬間の EMA」を固定し、そこからの乖離率に係数を掛けた位置に置きます。'
                    '係数・利確幅の下限・損切りは、方向ごとの設定にあります。',
                children: [
                  SwitchListTile(
                    value: draft.attachTakeProfitToOrder,
                    onChanged: (v) =>
                        _update((c) => c.copyWith(attachTakeProfitToOrder: v)),
                    title: const Text('発注と同時に利確を取引所へ預ける'),
                    subtitle: const Text(
                      '入れておくと、アプリやサーバーが落ちていても取引所側で利確されます。',
                    ),
                    dense: true,
                  ),
                ],
              ),

              _Section(
                title: '資金調達率のフィルタ',
                description:
                    'その方向が「支払う側」になるときだけ効きます。'
                    '受け取る側なら率が大きくても見送りません '
                    '(率がマイナスならショートが支払い、プラスならロングが支払います)。'
                    '負担率と間隔の基準は方向ごとの設定にあります。',
                children: [
                  SwitchListTile(
                    value: draft.fundingFilterEnabled,
                    onChanged: (v) =>
                        _update((c) => c.copyWith(fundingFilterEnabled: v)),
                    title: const Text('フィルタを使う'),
                    dense: true,
                  ),
                ],
              ),

              _Section(
                title: '運用',
                children: [
                  _NumberField(
                    label: '判定の間隔',
                    suffix: '秒',
                    value: draft.evaluationIntervalSeconds.toDouble(),
                    integer: true,
                    helper: '既定 60 秒。どの時間軸もこの間隔で評価します。',
                    onChanged: (v) => _update(
                      (c) => c.copyWith(evaluationIntervalSeconds: v.toInt()),
                    ),
                  ),
                  _NumberField(
                    label: '同時に持つポジションの上限',
                    suffix: '件',
                    value: draft.maxConcurrentPositions.toDouble(),
                    integer: true,
                    onChanged: (v) => _update(
                      (c) => c.copyWith(maxConcurrentPositions: v.toInt()),
                    ),
                  ),
                  _NumberField(
                    label: '同じ銘柄の再エントリー待ち',
                    suffix: '分',
                    value: draft.reentryCooldownMinutes.toDouble(),
                    integer: true,
                    onChanged: (v) => _update(
                      (c) => c.copyWith(reentryCooldownMinutes: v.toInt()),
                    ),
                  ),
                  SwitchListTile(
                    value: draft.oneSignalPerBar,
                    onChanged: (v) =>
                        _update((c) => c.copyWith(oneSignalPerBar: v)),
                    title: const Text('同じ足では1回だけ発火させる'),
                    dense: true,
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
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _draft = const StrategyConfig();
                      _manualSymbolsController.clear();
                      _excludedSymbolsController.clear();
                    });
                  },
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('既定値に戻す'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text('変更を取り消す'),
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

/// 片方向ぶんの設定をまとめたカード。
///
/// ショートとロングで項目の並びを同じにして、左右で見比べられるようにする。
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
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
                size: 18,
                color: color,
              ),
              const SizedBox(width: 6),
              Text(
                side.direction.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              const Spacer(),
              Switch(
                value: side.enabled,
                onChanged: (v) => onChanged(side.copyWith(enabled: v)),
              ),
            ],
          ),
          Text(
            isShort ? 'RSI が高く +σ を上抜けたら売る' : 'RSI が低く -σ を下抜けたら買う',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _NumberField(
            label: 'RSIのしきい値',
            value: side.rsiThreshold,
            helper: isShort ? 'この値以上で候補になります。' : 'この値以下で候補になります。',
            onChanged: (v) => onChanged(side.copyWith(rsiThreshold: v)),
          ),
          _NumberField(
            label: 'σ倍率',
            value: side.bbSigma,
            helper: isShort
                ? '終値が +σ を超えたら候補になります。'
                : '終値が -σ を割ったら候補になります。',
            onChanged: (v) => onChanged(side.copyWith(bbSigma: v)),
          ),
          _NumberField(
            label: 'レバレッジ',
            suffix: '倍',
            value: side.leverage.toDouble(),
            integer: true,
            onChanged: (v) => onChanged(side.copyWith(leverage: v.toInt())),
          ),
          _NumberField(
            label: '1回あたりの証拠金',
            suffix: 'USDT',
            value: side.marginPerTradeUsdt,
            onChanged: (v) => onChanged(side.copyWith(marginPerTradeUsdt: v)),
          ),
          if (showLimitOffset)
            _NumberField(
              label: '指値を現在値から離す幅',
              suffix: '%',
              value: side.limitOffsetPercent,
              helper: isShort ? '現在値より高い側に置きます。' : '現在値より安い側に置きます。',
              onChanged: (v) => onChanged(side.copyWith(limitOffsetPercent: v)),
            ),
          _NumberField(
            label: '利確の係数',
            value: side.takeProfitFactor,
            helper: '0.5 = 乖離の半分。0 より大きく 1 未満。',
            onChanged: (v) => onChanged(side.copyWith(takeProfitFactor: v)),
          ),
          _NumberField(
            label: '利確幅の下限',
            suffix: '%',
            value: side.minTakeProfitPercent,
            helper: 'API経由の往復手数料は 0.16% 前後です。',
            onChanged: (v) => onChanged(side.copyWith(minTakeProfitPercent: v)),
          ),
          SwitchListTile(
            value: side.stopLossEnabled,
            onChanged: (v) => onChanged(side.copyWith(stopLossEnabled: v)),
            title: const Text('損切りを使う'),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
          if (side.stopLossEnabled)
            _NumberField(
              label: '損切り幅',
              suffix: '%',
              value: side.stopLossPercent,
              helper: isShort
                  ? '建値からこの%だけ上がったら決済します。'
                  : '建値からこの%だけ下がったら決済します。',
              onChanged: (v) => onChanged(side.copyWith(stopLossPercent: v)),
            ),
          if (showFunding) ...[
            _NumberField(
              label: '資金調達 負担率の上限',
              suffix: '%',
              value: side.maxFundingBurdenPercent,
              helper: '既定 0.1%。これを超える負担なら見送ります。',
              onChanged: (v) =>
                  onChanged(side.copyWith(maxFundingBurdenPercent: v)),
            ),
            _NumberField(
              label: '資金調達 間隔の下限',
              suffix: '時間',
              value: side.minFundingIntervalHours.toDouble(),
              integer: true,
              helper: '既定 2 時間。銘柄ごとに 8 / 4 / 1 時間が混在します。',
              onChanged: (v) =>
                  onChanged(side.copyWith(minFundingIntervalHours: v.toInt())),
            ),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.description,
  });

  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (description != null) ...[
                const SizedBox(height: 4),
                Text(
                  description!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              ...children,
            ],
          ),
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
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final String? suffix;
  final String? helper;
  final bool integer;

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
    // 外から値が変わったとき (既定値に戻す等) だけ追従する。
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
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _controller,
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
          suffixText: widget.suffix,
          helperText: widget.helper,
          helperMaxLines: 3,
          isDense: true,
        ),
        onChanged: (text) {
          final value = double.tryParse(text);
          if (value != null) widget.onChanged(value);
        },
      ),
    );
  }
}
