import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import '../settings/app_settings.dart';
import '../settings/settings_store.dart';
import '../state/app_state.dart';

/// 売買条件と接続設定をまとめて編集する画面。
///
/// 項目ごとに枠を分けず、1 つの枠の中に見出しで区切って並べる
/// (開け閉めしなくても全部見えるように)。
/// ショートとロングは同じ並びで左右に置き、値を見比べられるようにする。
/// 出来高の下限・時間軸・指標の期間も方向ごとなので、いちばん上にある。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  StrategyConfig? _draft;
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
      _serverUrlController.text = state.settings.serverUrl;
      _serverTokenController.text = state.settings.serverToken;
      _checkResult = null;
    });
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _serverTokenController.dispose();
    super.dispose();
  }

  StrategyConfig get draft => _draft!;

  void _update(StrategyConfig Function(StrategyConfig) change) =>
      setState(() => _draft = change(draft));

  void _updateShort(SideConfig Function(SideConfig) change) =>
      _update((c) => c.withSide(change(c.short)));

  void _updateLong(SideConfig Function(SideConfig) change) =>
      _update((c) => c.withSide(change(c.long)));

  /// 保存する画面設定を組む。
  ///
  /// この画面で変えるのは URL とトークンだけ (入力欄から取る)。ほかの値
  /// (明るさ・チャートの線) はほかの所で変わるので、この画面の写し
  /// (開いたときのまま) ではなく、いまの値を引き継ぐ。写しのまま書き戻すと、
  /// 保存したとたんに明るさなどが元に戻ってしまう。
  AppSettings _settingsToSave(AppState state) => state.settings.copyWith(
    serverUrl: _serverUrlController.text.trim(),
    serverToken: _serverTokenController.text.trim(),
  );

  Future<void> _persistAppSettings() async {
    if (!mounted) return;
    final state = AppScope.of(context);
    await state.updateAppSettings(_settingsToSave(state));
  }

  /// URL とトークンを保存して、つなぎ直す。
  ///
  /// 1 文字ごとに保存すると、そのたびに接続をやり直して中途半端な
  /// トークンで弾かれ続ける。まとめて確定させるための口。
  Future<void> _applyConnection() async {
    final state = AppScope.of(context);
    setState(() => _checkResult = null);
    await _persistAppSettings();
    await state.reconnect();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('接続設定を保存して繋ぎ直しました')));
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
    await state.updateAppSettings(_settingsToSave(state));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('設定を保存しました')));
  }

  /// 飛び出しで入る条件を、いまの値で言葉にする。入れている向きだけ出す。
  String _breakoutHint() {
    final parts = [
      if (draft.short.bandBreakoutEntryEnabled)
        'ショートは +${_trimNumber(draft.short.bbSigma)}σ のバンドより '
            '${_trimNumber(draft.short.bandBreakoutPercent)}% 以上高く',
      if (draft.long.bandBreakoutEntryEnabled)
        'ロングは -${_trimNumber(draft.long.bbSigma)}σ のバンドより '
            '${_trimNumber(draft.long.bandBreakoutPercent)}% 以上安く',
    ];
    return 'いまの値: ${parts.join('、')}なったら入ります '
        '(% はバンドの価格に対する割合)。\n'
        'このときの利確は、バンドまでの距離に「利確の係数」を掛けた分だけ'
        '戻った所です (0.5 なら半分戻った所)。';
  }

  @override
  Widget build(BuildContext context) {
    if (_draft == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final state = AppScope.of(context);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            children: [
              // 項目ごとに枠を分けず、1 つの枠の中に見出しで区切って並べる。
              _Frame(
                groups: [
                  _Group(
                    title: 'ショートとロングの条件',
                    description:
                        '出来高・時間軸・指標の期間も向きごとに決められます。'
                        'RSI のしきい値だけ向きが逆 (既定 97 / 3) です。',
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
                        onShortChanged: (v) => _updateShort(
                          (x) => x.copyWith(bbPeriod: v.toInt()),
                        ),
                        onLongChanged: (v) =>
                            _updateLong((x) => x.copyWith(bbPeriod: v.toInt())),
                      ),
                      _PairField(
                        title: 'RSI期間',
                        integer: true,
                        shortValue: draft.short.rsiPeriod.toDouble(),
                        longValue: draft.long.rsiPeriod.toDouble(),
                        onShortChanged: (v) => _updateShort(
                          (x) => x.copyWith(rsiPeriod: v.toInt()),
                        ),
                        onLongChanged: (v) => _updateLong(
                          (x) => x.copyWith(rsiPeriod: v.toInt()),
                        ),
                      ),
                      _PairField(
                        title: 'EMA期間 (利確の基準)',
                        integer: true,
                        shortValue: draft.short.emaPeriod.toDouble(),
                        longValue: draft.long.emaPeriod.toDouble(),
                        onShortChanged: (v) => _updateShort(
                          (x) => x.copyWith(emaPeriod: v.toInt()),
                        ),
                        onLongChanged: (v) => _updateLong(
                          (x) => x.copyWith(emaPeriod: v.toInt()),
                        ),
                      ),
                      _PairField(
                        title: '保持する足',
                        integer: true,
                        shortSuffix: '本',
                        longSuffix: '本',
                        shortValue: draft.short.historyBars.toDouble(),
                        longValue: draft.long.historyBars.toDouble(),
                        onShortChanged: (v) => _updateShort(
                          (x) => x.copyWith(historyBars: v.toInt()),
                        ),
                        onLongChanged: (v) => _updateLong(
                          (x) => x.copyWith(historyBars: v.toInt()),
                        ),
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
                        onShortChanged: (v) => _updateShort(
                          (x) => x.copyWith(leverage: v.toInt()),
                        ),
                        onLongChanged: (v) =>
                            _updateLong((x) => x.copyWith(leverage: v.toInt())),
                      ),
                      _PairField(
                        title: '1回あたりの証拠金 [USDT]',
                        shortValue: draft.short.marginPerTradeUsdt,
                        longValue: draft.long.marginPerTradeUsdt,
                        onShortChanged: (v) => _updateShort(
                          (x) => x.copyWith(marginPerTradeUsdt: v),
                        ),
                        onLongChanged: (v) => _updateLong(
                          (x) => x.copyWith(marginPerTradeUsdt: v),
                        ),
                      ),
                      _PairField(
                        title: '利確の係数',
                        shortValue: draft.short.takeProfitFactor,
                        longValue: draft.long.takeProfitFactor,
                        onShortChanged: (v) => _updateShort(
                          (x) => x.copyWith(takeProfitFactor: v),
                        ),
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
                        onLongChanged: (v) => _updateLong(
                          (x) => x.copyWith(minTakeProfitPercent: v),
                        ),
                      ),
                      _PairSwitch(
                        title: '大きく飛び出したら RSI を待たずに入る',
                        shortValue: draft.short.bandBreakoutEntryEnabled,
                        longValue: draft.long.bandBreakoutEntryEnabled,
                        onShortChanged: (v) => _updateShort(
                          (x) => x.copyWith(bandBreakoutEntryEnabled: v),
                        ),
                        onLongChanged: (v) => _updateLong(
                          (x) => x.copyWith(bandBreakoutEntryEnabled: v),
                        ),
                      ),
                      const _Hint(
                        'ふつうは「RSI がしきい値に届く」と「±σ のバンドを抜ける」が'
                        'そろったときに入ります。オンにすると、急騰・急落で価格が'
                        'バンドの外へ大きく飛び出したときは、RSI がしきい値に'
                        '届いていなくても入ります。',
                      ),
                      if (draft.short.bandBreakoutEntryEnabled ||
                          draft.long.bandBreakoutEntryEnabled) ...[
                        _PairField(
                          title: 'バンドの外へ何 % 飛び出したら入るか',
                          shortSuffix: '% 以上',
                          longSuffix: '% 以上',
                          shortValue: draft.short.bandBreakoutPercent,
                          longValue: draft.long.bandBreakoutPercent,
                          onShortChanged: (v) => _updateShort(
                            (x) => x.copyWith(bandBreakoutPercent: v),
                          ),
                          onLongChanged: (v) => _updateLong(
                            (x) => x.copyWith(bandBreakoutPercent: v),
                          ),
                        ),
                        _Hint(_breakoutHint()),
                      ],
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
                        longValue: draft.long.minFundingIntervalHours
                            .toDouble(),
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
                      if (draft.short.addOnEnabled ||
                          draft.long.addOnEnabled) ...[
                        _PairField(
                          title: '指値を置く含み損 [%] (証拠金に対して)',
                          shortValue: draft.short.addOnLossPercent,
                          longValue: draft.long.addOnLossPercent,
                          onShortChanged: (v) => _updateShort(
                            (x) => x.copyWith(addOnLossPercent: v),
                          ),
                          onLongChanged: (v) => _updateLong(
                            (x) => x.copyWith(addOnLossPercent: v),
                          ),
                        ),
                        _PairField(
                          title: '残り資金のうち使う割合 [%]',
                          shortValue: draft.short.addOnBudgetPercent,
                          longValue: draft.long.addOnBudgetPercent,
                          onShortChanged: (v) => _updateShort(
                            (x) => x.copyWith(addOnBudgetPercent: v),
                          ),
                          onLongChanged: (v) => _updateLong(
                            (x) => x.copyWith(addOnBudgetPercent: v),
                          ),
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

                  _Group(
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
                                (c) => c.copyWith(
                                  reentryCooldownMinutes: v.toInt(),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const _Hint(
                        '同時に持てる件数に上限はありません。\n'
                        'ポジションを持っている銘柄は、持っている間は 1 回だけ発火します '
                        '(向きが同じでも違っても重ねて建てません)。'
                        '決済してからは「再エントリー待ち」の間だけ間を置き、'
                        'そのあとは同じ足でももう一度入れます。\n'
                        '新規建ては成行・分離マージン、利確は発注と同時に取引所へ預け、'
                        '資金調達率のフィルタは常に効きます (切り替えはありません)。',
                      ),
                    ],
                  ),

                  _Group(
                    title: 'サーバーへの接続',
                    description: 'ボットはサーバーで動きます。アプリは繋いで見る・操作するだけです。',
                    children: [
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
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),
                                icon: const Icon(Icons.link, size: 16),
                                // 狭い画面でも 1 行に収める (入り切らなければ縮める)。
                                label: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    '保存して繋ぎ直す',
                                    maxLines: 1,
                                    style: TextStyle(fontSize: 12),
                                  ),
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
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),
                                label: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    '接続を試す',
                                    maxLines: 1,
                                    style: TextStyle(fontSize: 12),
                                  ),
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
                          'URL とトークンは入れ終わってから「保存して繋ぎ直す」を'
                          '押してください。',
                        ),
                      const _Hint(
                        '「開始」を押すと、「停止」を押すまでサーバーで動き続けます '
                        '(アプリを閉じても落ちても止まりません)。'
                        '取引所の API キーはサーバーの /etc/mexc-bot/env に入れます。'
                        '残高・建玉・決済の記録も、サーバーが取引所から取って返します。',
                      ),
                    ],
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
      ControllerConnection.connected => ('繋がっています', Colors.green),
      ControllerConnection.connecting => ('繋ぎ中', Colors.orange),
      ControllerConnection.error => ('繋がっていません', theme.colorScheme.error),
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

/// 設定をまとめて入れる 1 つの枠。中のまとまりは線で区切る。
class _Frame extends StatelessWidget {
  const _Frame({required this.groups});

  final List<Widget> groups;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < groups.length; i++) ...[
              if (i > 0) const Divider(height: 24),
              groups[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// 枠の中のひとまとまり。見出しの下に項目を並べる。
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children, this.description});

  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (description != null)
                Text(
                  description!,
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                ),
            ],
          ),
        ),
        ...children,
      ],
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

/// 4.0 を「4」のように、小数点以下が 0 なら落として文字にする。
String _trimNumber(double value) {
  var text = value.toString();
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return text;
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
      widget.integer ? value.toInt().toString() : _trimNumber(value);

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
