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
/// 項目ごとに枠を分けず、1 つの枠の中に見出しで区切って並べる。
/// 手法は「今までの手法」と「検証済みの手法」に分けて並べ、同時に使える。
/// 今までの手法で向きで分けるのは建てるか・出来高の下限・RSI の閾値だけで、
/// 他の項目はショートとロングに同じ値を入れる。指標の期間は BB20・RSI7・EMA5 で固定。
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
      _draft = _normalize(state.config);
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

  /// ショートとロングで同じ値を使う項目を、両方に入れる。
  void _updateBoth(SideConfig Function(SideConfig) change) =>
      _update((c) => c.withSide(change(c.short)).withSide(change(c.long)));

  /// 検証済みの手法の条件を変える。
  void _updateVerified(SideConfig Function(SideConfig) change) =>
      _update((c) => c.copyWith(verified: change(c.verified)));

  /// 画面で扱える形に揃える。
  ///
  /// 今までの手法で向きで分けない項目は代表の向きの値を両方に入れ、利確は
  /// EMA の戻りにする (σ の倍数の利確・損切りは検証済みの手法の物)。指標の
  /// 期間は固定値にし、使わない 1 分足と 8 時間足は外す。
  static StrategyConfig _normalize(StrategyConfig c) {
    const fixed = SideConfig.short();
    final from = c.primarySide;
    List<Timeframe> choices(List<Timeframe> tfs) => [
      for (final t in tfs)
        if (timeframeChoices.contains(t)) t,
    ];
    SideConfig shared(SideConfig x) => x.copyWith(
      timeframes: choices(from.timeframes),
      bbPeriod: fixed.bbPeriod,
      rsiPeriod: fixed.rsiPeriod,
      emaPeriod: fixed.emaPeriod,
      historyBars: from.historyBars,
      bbSigma: from.bbSigma,
      leverage: from.leverage,
      marginPerTradeUsdt: from.marginPerTradeUsdt,
      marginByPercent: from.marginByPercent,
      marginPercent: from.marginPercent,
      takeProfitFactor: from.takeProfitFactor,
      minTakeProfitPercent: from.minTakeProfitPercent,
      bandBreakoutEntryEnabled: from.bandBreakoutEntryEnabled,
      bandBreakoutPercent: from.bandBreakoutPercent,
      maxFundingBurdenPercent: from.maxFundingBurdenPercent,
      fundingWindowHours: from.fundingWindowHours,
      addOnEnabled: from.addOnEnabled,
      addOnLossPercent: from.addOnLossPercent,
      addOnBudgetPercent: from.addOnBudgetPercent,
      exitMode: ExitMode.emaRatio,
      maxHoldHours: from.maxHoldHours,
    );
    final v = c.verified;
    return c.withSide(shared(c.short)).withSide(shared(c.long)).copyWith(
      verified: v.copyWith(
        timeframes: choices(v.timeframes),
        bbPeriod: fixed.bbPeriod,
        rsiPeriod: fixed.rsiPeriod,
        emaPeriod: fixed.emaPeriod,
      ),
    );
  }

  /// 検証済みの手法の条件を、検証した値に戻す (下書きだけ。保存するまでは
  /// 反映しない)。使うか・証拠金・レバレッジは今の値を残す。
  void _applyVerifiedPreset() {
    setState(() => _draft = _normalize(draft.withVerifiedPreset()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('検証済みの手法を、検証した値に戻しました。「保存して反映」を押すとボットに反映されます。'),
      ),
    );
  }

  /// 検証済みの手法が何をするかを、今の値で言葉にする。
  String _verifiedHint() {
    final v = draft.verified;
    final tfs = v.timeframes.map((t) => t.label).join('・');
    final n = draft.verifiedMaxOpenPositions;
    final sl = v.stopLossSigma > 0
        ? '${_trimNumber(v.stopLossSigma)} 倍下がったら損を確定 (損切り) します'
        : '損切りは置きません';
    return '・買い (ロング) だけです。\n'
        '・${tfs.isEmpty ? '選んだ時間足' : tfs}で、値段がボリンジャーバンドの '
        '-${_trimNumber(v.bbSigma)}σ (いつもの値動きから大きく下に外れた所) まで'
        '下がり、RSI(7) が ${_trimNumber(v.rsiThreshold)} 以下 (極端な売られすぎ) '
        'の時に買います。\n'
        '・買った値段より σ の ${_trimNumber(v.takeProfitSigma)} 倍上がったら'
        '利益を確定 (利確) し、$sl。σ はボリンジャーバンドの 1 目盛りの幅で、'
        '買った時の値で決まります。注文は買うと同時に取引所に置きます。\n'
        '${v.maxHoldHours > 0 ? '・${v.maxHoldHours} 時間たってもどちらにも届かなければ、その時の値段で売って終わります。\n' : ''}'
        '・同時に持つのは ${n > 0 ? '$n 銘柄まで' : '上限なし'}です。'
        '買い足しはしません。';
  }

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

  /// 飛び出しで入る条件を、今の値で言葉にする。
  String _breakoutHint() {
    final shared = draft.primarySide;
    final sigma = _trimNumber(shared.bbSigma);
    final percent = _trimNumber(shared.bandBreakoutPercent);
    return '今の値: ショートは +$sigmaσ のバンドより $percent% 以上高く、'
        'ロングは -$sigmaσ のバンドより $percent% 以上安くなったら入ります '
        '(% はバンドの価格に対する割合)。'
        'この時の利確は、バンドまでの距離に「利確の係数」を掛けた分だけ戻った所です。';
  }

  @override
  Widget build(BuildContext context) {
    if (_draft == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final state = AppScope.of(context);
    // 向きで分けない項目の値 (両方に同じ値が入っている)。
    final shared = draft.primarySide;
    final pushTopic = state.snapshot.pushTopic;
    // 証拠金を割合で決めるときに、今いくらになるかの目安に使う。
    final equity = state.snapshot.asset?.equity;

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
                    title: '今までの手法 (EMA の戻りで利確)',
                    description:
                        'BB(20) の ±σ のバンドを抜けて RSI(7) が閾値に届いたら逆張りで'
                        '入り、EMA(5) へ戻る途中で利確します。損切りは置きません。'
                        '向きで分けるのは、建てるか・出来高の下限・RSI の閾値だけで、'
                        '他は両方に同じ値を使います。',
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
                        title: '監視する銘柄: 24 時間出来高の下限',
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
                        '1 M = 100 万 USDT。監視するのは、両方の下限の低い方以上の'
                        '全銘柄です。建てるかは向きごとの下限で決めます。',
                      ),
                      _PairField(
                        title: 'RSI(7) の閾値',
                        shortSuffix: '以上',
                        longSuffix: '以下',
                        shortValue: draft.short.rsiThreshold,
                        longValue: draft.long.rsiThreshold,
                        onShortChanged: (v) =>
                            _updateShort((x) => x.copyWith(rsiThreshold: v)),
                        onLongChanged: (v) =>
                            _updateLong((x) => x.copyWith(rsiThreshold: v)),
                      ),
                      _SharedTimeframes(
                        value: shared.timeframes,
                        onChanged: (v) =>
                            _updateBoth((x) => x.copyWith(timeframes: v)),
                      ),
                      _SharedField(
                        title: 'σ 倍率 (BB(20) の幅)',
                        value: shared.bbSigma,
                        onChanged: (v) =>
                            _updateBoth((x) => x.copyWith(bbSigma: v)),
                      ),
                      _SharedField(
                        title: '保持する足',
                        suffix: '本',
                        integer: true,
                        value: shared.historyBars.toDouble(),
                        onChanged: (v) => _updateBoth(
                          (x) => x.copyWith(historyBars: v.toInt()),
                        ),
                      ),
                      _SharedField(
                        title: 'レバレッジ',
                        suffix: '倍',
                        integer: true,
                        value: shared.leverage.toDouble(),
                        onChanged: (v) =>
                            _updateBoth((x) => x.copyWith(leverage: v.toInt())),
                      ),
                      _MarginSetting(
                        side: shared,
                        equity: equity,
                        onChanged: (n) => _updateBoth(
                          (x) => x.copyWith(
                            marginPerTradeUsdt: n.marginPerTradeUsdt,
                            marginByPercent: n.marginByPercent,
                            marginPercent: n.marginPercent,
                          ),
                        ),
                      ),
                      _SharedField(
                        title: '利確の係数',
                        value: shared.takeProfitFactor,
                        onChanged: (v) => _updateBoth(
                          (x) => x.copyWith(takeProfitFactor: v),
                        ),
                      ),
                      const _Hint(
                        '行き過ぎた分の内、この割合だけ戻った所で利確します'
                        ' (0.5 なら半分)。0 より大きく 1 未満。損切りは置きません。',
                      ),
                      _SharedField(
                        title: '最長保有時間',
                        suffix: '時間',
                        integer: true,
                        value: shared.maxHoldHours.toDouble(),
                        onChanged: (v) => _updateBoth(
                          (x) => x.copyWith(maxHoldHours: v.toInt()),
                        ),
                      ),
                      const _Hint(
                        '建ててからこの時間が過ぎたら成行で決済します。0 なら時間では'
                        '決済しません。ボットを止めている間は閉じません。',
                      ),
                      _SharedField(
                        title: '利確幅の下限',
                        suffix: '%',
                        value: shared.minTakeProfitPercent,
                        onChanged: (v) => _updateBoth(
                          (x) => x.copyWith(minTakeProfitPercent: v),
                        ),
                      ),
                      _CompactSwitch(
                        label: '大きく飛び出したら RSI を待たずに入る',
                        value: shared.bandBreakoutEntryEnabled,
                        onChanged: (v) => _updateBoth(
                          (x) => x.copyWith(bandBreakoutEntryEnabled: v),
                        ),
                      ),
                      const _Hint(
                        '普段は「RSI が閾値に届く」と「±σ のバンドを抜ける」が揃った時に'
                        '入ります。オンにすると、価格がバンドの外へ大きく飛び出した時は'
                        ' RSI を待たずに入ります。',
                      ),
                      if (shared.bandBreakoutEntryEnabled) ...[
                        _SharedField(
                          title: 'バンドの外へ何 % 飛び出したら入るか',
                          suffix: '% 以上',
                          value: shared.bandBreakoutPercent,
                          onChanged: (v) => _updateBoth(
                            (x) => x.copyWith(bandBreakoutPercent: v),
                          ),
                        ),
                        _Hint(_breakoutHint()),
                      ],
                      _SharedField(
                        title: '資金調達: 負担率の上限',
                        suffix: '%',
                        value: shared.maxFundingBurdenPercent,
                        onChanged: (v) => _updateBoth(
                          (x) => x.copyWith(maxFundingBurdenPercent: v),
                        ),
                      ),
                      _SharedField(
                        title: '資金調達: 支払いまでの残り時間',
                        suffix: '時間以内',
                        integer: true,
                        value: shared.fundingWindowHours.toDouble(),
                        onChanged: (v) => _updateBoth(
                          (x) => x.copyWith(fundingWindowHours: v.toInt()),
                        ),
                      ),
                      const _Hint(
                        '資金調達を支払う側で、負担率が上限を超え、かつ次の支払いまで'
                        'この時間以内の時だけ見送ります。',
                      ),
                      _CompactSwitch(
                        label: '含み損が出たら買い足し / 売り足しする',
                        value: shared.addOnEnabled,
                        onChanged: (v) =>
                            _updateBoth((x) => x.copyWith(addOnEnabled: v)),
                      ),
                      if (shared.addOnEnabled) ...[
                        _SharedField(
                          title: '指値を置く含み損 (証拠金に対して)',
                          suffix: '%',
                          value: shared.addOnLossPercent,
                          onChanged: (v) => _updateBoth(
                            (x) => x.copyWith(addOnLossPercent: v),
                          ),
                        ),
                        _SharedField(
                          title: '残り資金の内、使う割合',
                          suffix: '%',
                          value: shared.addOnBudgetPercent,
                          onChanged: (v) => _updateBoth(
                            (x) => x.copyWith(addOnBudgetPercent: v),
                          ),
                        ),
                        const _Hint(
                          '建てた直後、残っている USDT のこの割合を証拠金にして、含み損が'
                          'この % になる価格に同じ向きの指値を置きます。約定すると平均建値が'
                          '有利な側に寄ります (利確の目標は動かしません)。指値の分の資金は'
                          '凍結されるので、100% にすると次の銘柄に回す資金が無くなります'
                          ' (検証済みの手法にも回せなくなります)。',
                        ),
                      ],
                    ],
                  ),

                  _Group(
                    title: '検証済みの手法 (σ で利確と損切り)',
                    description:
                        '過去 1 年の値動きで試して、前の半年・後の半年のどちらも利益が出た'
                        '手法です。今までの手法と同時に使えます (同じ銘柄に両方から重ねて'
                        '建てることはしません)。',
                    children: [
                      _CompactSwitch(
                        label: 'この手法を使う',
                        value: draft.verified.enabled,
                        onChanged: (v) =>
                            _updateVerified((x) => x.copyWith(enabled: v)),
                      ),
                      _Hint(_verifiedHint()),
                      if (draft.verified.enabled) ...[
                        _SharedTimeframes(
                          value: draft.verified.timeframes,
                          onChanged: (v) =>
                              _updateVerified((x) => x.copyWith(timeframes: v)),
                        ),
                        _TwoFields(
                          left: _NumberField(
                            label: 'σ 倍率 (下抜け)',
                            suffix: 'σ',
                            value: draft.verified.bbSigma,
                            dense: true,
                            onChanged: (v) =>
                                _updateVerified((x) => x.copyWith(bbSigma: v)),
                          ),
                          right: _NumberField(
                            label: 'RSI(7) の閾値',
                            suffix: '以下',
                            value: draft.verified.rsiThreshold,
                            dense: true,
                            onChanged: (v) => _updateVerified(
                              (x) => x.copyWith(rsiThreshold: v),
                            ),
                          ),
                        ),
                        _TwoFields(
                          left: _NumberField(
                            label: '利確 (入値から)',
                            suffix: 'σ',
                            value: draft.verified.takeProfitSigma,
                            dense: true,
                            onChanged: (v) => _updateVerified(
                              (x) => x.copyWith(takeProfitSigma: v),
                            ),
                          ),
                          right: _NumberField(
                            label: '損切り (入値から)',
                            suffix: 'σ',
                            value: draft.verified.stopLossSigma,
                            dense: true,
                            onChanged: (v) => _updateVerified(
                              (x) => x.copyWith(stopLossSigma: v),
                            ),
                          ),
                        ),
                        _TwoFields(
                          left: _NumberField(
                            label: '最長保有時間',
                            suffix: '時間',
                            integer: true,
                            value: draft.verified.maxHoldHours.toDouble(),
                            dense: true,
                            onChanged: (v) => _updateVerified(
                              (x) => x.copyWith(maxHoldHours: v.toInt()),
                            ),
                          ),
                          right: _NumberField(
                            label: '同時に持つ数',
                            suffix: '件まで',
                            integer: true,
                            value: draft.verifiedMaxOpenPositions.toDouble(),
                            dense: true,
                            onChanged: (v) => _update(
                              (c) => c.copyWith(
                                verifiedMaxOpenPositions: v.toInt(),
                              ),
                            ),
                          ),
                        ),
                        _TwoFields(
                          left: _NumberField(
                            label: '24 時間出来高の下限',
                            suffix: 'M USDT',
                            value: draft.verified.minAmount24Usdt / 1000000,
                            dense: true,
                            onChanged: (v) => _updateVerified(
                              (x) => x.copyWith(minAmount24Usdt: v * 1000000),
                            ),
                          ),
                          right: _NumberField(
                            label: 'レバレッジ',
                            suffix: '倍',
                            integer: true,
                            value: draft.verified.leverage.toDouble(),
                            dense: true,
                            onChanged: (v) => _updateVerified(
                              (x) => x.copyWith(leverage: v.toInt()),
                            ),
                          ),
                        ),
                        const _Hint(
                          '損切りを 0 にすると置きません。最長保有時間を 0 にすると時間では'
                          '決済しません (ボットを止めている間は閉じません)。同時に持つ数は'
                          'この手法で建てた物だけを数えます (0 なら上限なし)。',
                        ),
                        _MarginSetting(
                          side: draft.verified,
                          equity: equity,
                          onChanged: (n) => _updateVerified((_) => n),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _applyVerifiedPreset,
                            icon: const Icon(Icons.restart_alt, size: 16),
                            label: const Text(
                              '検証した値に戻す',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
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
                      _SharedField(
                        title: '同時に持つ建玉の上限',
                        suffix: '件',
                        integer: true,
                        value: draft.maxOpenPositions.toDouble(),
                        onChanged: (v) => _update(
                          (c) => c.copyWith(maxOpenPositions: v.toInt()),
                        ),
                      ),
                      const _Hint(
                        '0 なら上限なし。どちらの手法で建てた物も、手で建てた物も数えます。'
                        'ポジションを持っている銘柄は、持っている間は 1 回だけ発火します'
                        ' (重ねて建てません)。決済後は「再エントリー待ち」を過ぎれば、'
                        '同じ足でももう一度入ります。\n'
                        '新規建ては成行・分離マージンで、利確 (と損切り) は発注と同時に'
                        '取引所へ預けます。資金調達率の絞り込みは常に効きます。',
                      ),
                    ],
                  ),

                  _Group(
                    title: 'サーバーへの接続',
                    description: 'ボットはサーバーで動き、アプリは繋いで見る・操作するだけです。',
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
                          'URL の例: ws://192.168.0.10:8080/ws (http:// や /ws の'
                          '書き忘れはこちらで直します)。接続トークンは、サーバーの '
                          '/etc/mexc-bot/env にある BOT_TOKEN の値です。'
                          '入れ終わってから「保存して繋ぎ直す」を押して下さい。',
                        ),
                      const _Hint(
                        '「開始」を押すと、「停止」を押すまでサーバーで動き続けます'
                        ' (アプリを閉じても止まりません)。取引所の API キーは'
                        'サーバーの /etc/mexc-bot/env に入れます。',
                      ),
                      _PushInfo(topic: pushTopic),
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
                      _draft = _normalize(const StrategyConfig());
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

/// 選べる時間足。1 分足と 8 時間足は使わない。
const List<Timeframe> timeframeChoices = [
  Timeframe.m5,
  Timeframe.m15,
  Timeframe.m30,
  Timeframe.h1,
  Timeframe.h4,
  Timeframe.d1,
];

/// ショートとロングで同じ値を使う数値の項目。
class _SharedField extends StatelessWidget {
  const _SharedField({
    required this.title,
    required this.value,
    required this.onChanged,
    this.suffix,
    this.integer = false,
  });

  final String title;
  final double value;
  final ValueChanged<double> onChanged;
  final String? suffix;
  final bool integer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: _NumberField(
        label: title,
        suffix: suffix,
        value: value,
        integer: integer,
        dense: true,
        onChanged: onChanged,
      ),
    );
  }
}

/// 2 つの入力欄を横に並べる。
class _TwoFields extends StatelessWidget {
  const _TwoFields({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 8),
        Expanded(child: right),
      ],
    );
  }
}

/// 1 回の証拠金。固定額 (USDT) か、資産の割合 (スライダー) で決める。
class _MarginSetting extends StatelessWidget {
  const _MarginSetting({
    required this.side,
    required this.equity,
    required this.onChanged,
  });

  final SideConfig side;

  /// 今の資産 (USDT)。割合のとき、いくらになるかの目安を出す。分からなければ null。
  final double? equity;

  /// 証拠金の項目だけを変えた条件を返す。
  final ValueChanged<SideConfig> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = side.marginPercent.clamp(1.0, 100.0).toDouble();
    final e = equity;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CompactSwitch(
            label: '1 回の証拠金を資産の割合で決める',
            value: side.marginByPercent,
            onChanged: (v) => onChanged(side.copyWith(marginByPercent: v)),
          ),
          if (side.marginByPercent) ...[
            Row(
              children: [
                Text(
                  '1 回の証拠金: 資産の ${percent.toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (e != null && e > 0)
                  Text(
                    '今なら約 ${(e * percent / 100).toStringAsFixed(2)} USDT',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
              ],
            ),
            Slider(
              value: percent,
              min: 1,
              max: 100,
              divisions: 99,
              label: '${percent.toStringAsFixed(0)}%',
              onChanged: (v) =>
                  onChanged(side.copyWith(marginPercent: v.roundToDouble())),
            ),
            const _Hint(
              '資産は口座の USDT の合計 (建玉の証拠金や含み損益も含む) です。'
              'その銘柄で持てる建玉の上限が資産より小さい時は、上限に対する割合に'
              'します (後で買い足せる余地を残すため)。使える残高を超える分は建てません。',
            ),
          ] else
            _NumberField(
              label: '1 回の証拠金',
              suffix: 'USDT',
              value: side.marginPerTradeUsdt,
              dense: true,
              onChanged: (v) => onChanged(side.copyWith(marginPerTradeUsdt: v)),
            ),
        ],
      ),
    );
  }
}

/// 判定に使う時間足。ショートとロングで同じものを使う。
class _SharedTimeframes extends StatelessWidget {
  const _SharedTimeframes({required this.value, required this.onChanged});

  final List<Timeframe> value;
  final ValueChanged<List<Timeframe>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '判定に使う時間足 (それぞれで判定します)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tf in timeframeChoices)
                FilterChip(
                  label: Text(tf.label, style: const TextStyle(fontSize: 12)),
                  selected: value.contains(tf),
                  visualDensity: VisualDensity.compact,
                  onSelected: (on) => onChanged(
                    [
                      for (final t in timeframeChoices)
                        if (t == tf ? on : value.contains(t)) t,
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// スマホへの通知の受け取り方。サーバーが ntfy で送る。
class _PushInfo extends StatelessWidget {
  const _PushInfo({required this.topic});

  /// ntfy の購読名。サーバーに設定が無ければ null。
  final String? topic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = topic;
    if (t == null) {
      return const _Hint(
        'スマホへの通知: サーバーの /etc/mexc-bot/env に NTFY_TOPIC が無いので、'
        'アプリを開いている間だけ通知します。',
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'スマホへの通知 (ntfy)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  t,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: t));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('購読名を写しました')),
                  );
                },
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('写す', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          Text(
            'ntfy アプリ (Google Play) でこの名前を購読すると、アプリを閉じていても'
            '建てた・決済した・開始・停止の通知が届きます。名前を知っていれば誰でも'
            '読めるので、人に教えないで下さい。',
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
          ),
        ],
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
