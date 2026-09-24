import 'dart:async';

import '../api/mexc_exception.dart';
import '../api/mexc_rest_client.dart';
import '../api/mexc_ws_client.dart';
import '../models/bot_event.dart';
import '../models/position.dart';
import '../models/signal.dart';
import '../models/strategy_config.dart';
import 'market_data_feed.dart';
import 'strategy_evaluator.dart';
import 'trade_executor.dart';

/// 売買ボットの本体。
///
/// サーバー常駐でもアプリ内のローカル実行でも、このクラスがそのまま動く。
/// 判定は [StrategyConfig.evaluationIntervalSeconds] ごと (既定 60 秒) に、
/// **進行中の足を含めて** 毎回すべて計算し直す。4 時間足でも 1 分ごとに評価する。
///
/// 注文は常に実際の取引所へ出す。試し打ちの仕組みは持たない。
class BotEngine {
  BotEngine({
    required StrategyConfig config,
    String? apiKey,
    String? apiSecret,
    MexcRestClient? rest,
    MexcWsClient? ws,
  }) : _config = config,
       _rest =
           rest ?? MexcRestClient(apiKey: apiKey, apiSecret: apiSecret),
       _ws = ws ?? MexcWsClient() {
    _feed = MarketDataFeed(
      rest: _rest,
      ws: _ws,
      onLog: (m) => _log(BotEvent.info(m)),
    );
    _executor = TradeExecutor(
      rest: _rest,
      onLog: (m) => _log(BotEvent.trade(m)),
    );
    _wsStatusSub = _ws.status.listen((s) => _log(BotEvent.info('WS: $s')));
  }

  static const Duration watchlistRefreshInterval = Duration(minutes: 5);
  /// 資金調達の間隔を取り直す頻度。銘柄ごとにほぼ固定なので1日1回で足りる。
  static const Duration fundingCycleRefreshInterval = Duration(hours: 24);
  static const Duration contractRefreshInterval = Duration(minutes: 30);
  static const Duration timeSyncInterval = Duration(minutes: 30);
  static const int maxEvaluationsInSnapshot = 60;
  static const int maxClosedPositionsKept = 500;

  /// 発注してから取引所の建玉一覧に載るまでの猶予。
  static const Duration exchangeSyncGrace = Duration(seconds: 20);

  StrategyConfig _config;
  final MexcRestClient _rest;
  final MexcWsClient _ws;
  late final MarketDataFeed _feed;
  late final TradeExecutor _executor;
  StreamSubscription<String>? _wsStatusSub;

  final _eventController = StreamController<BotEvent>.broadcast();
  final _snapshotController = StreamController<BotSnapshot>.broadcast();

  final Map<String, ManagedPosition> _positions = {};
  final List<ManagedPosition> _closedPositions = [];
  final Map<String, DateTime> _cooldownUntil = {};

  /// 「銘柄|時間軸|方向」ごとに、最後に発火した足の開始時刻。同じ足での連発を防ぐ。
  final Map<String, int> _firedBars = {};

  /// 取引所側に建玉がある銘柄。ボットが建てたものも、手で建てたものも入る。
  ///
  /// ここに入っている銘柄へは新規注文を出さない (利確・決済だけ行う)。
  Set<String> _heldSymbols = {};

  /// 管理外の建玉について、すでに知らせた銘柄。同じ警告を毎分出さないため。
  final Set<String> _warnedForeignSymbols = {};

  List<String> _watchlist = const [];
  List<SignalEvaluation> _lastEvaluations = const [];
  AccountAsset? _asset;
  String? _lastError;

  Timer? _timer;
  bool _running = false;
  bool _cycleInFlight = false;
  DateTime? _lastCycleAt;
  int? _lastCycleDurationMs;
  DateTime _lastWatchlistRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastFundingRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastContractRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTimeSync = DateTime.fromMillisecondsSinceEpoch(0);

  Stream<BotEvent> get events => _eventController.stream;
  Stream<BotSnapshot> get snapshots => _snapshotController.stream;

  StrategyConfig get config => _config;
  bool get isRunning => _running;
  List<ManagedPosition> get openPositions =>
      _positions.values.toList(growable: false);

  BotSnapshot get snapshot => BotSnapshot(
    running: _running,
    config: _config,
    wsConnected: _feed.wsConnected,
    watchedSymbolCount: _watchlist.length,
    subscriptionCount: _feed.subscriptionCount,
    evaluations: _lastEvaluations,
    positions: openPositions,
    closedPositions: _closedPositions.reversed.take(100).toList(),
    pendingHistoryCount: _feed.missingSeriesCount,
    markPrices: {
      for (final p in _positions.values)
        if (_feed.tickerOf(p.symbol) != null)
          p.symbol: _feed.tickerOf(p.symbol)!.lastPrice,
    },
    lastCycleAt: _lastCycleAt,
    lastCycleDurationMs: _lastCycleDurationMs,
    asset: _asset,
    lastError: _lastError,
    credentialsConfigured: _rest.hasCredentials,
  );

  // ── 起動 / 停止 ─────────────────────────────────────────────

  Future<void> start() async {
    if (_running) return;
    final errors = _config.validate();
    if (errors.isNotEmpty) {
      _lastError = errors.join(' / ');
      _log(BotEvent.error('設定に問題があります: $_lastError'));
      _emitSnapshot();
      return;
    }

    _running = true;
    _lastError = null;
    final sides = _config.enabledSides.map((s) => s.direction.label).join(' / ');
    _log(BotEvent.info('ボットを起動しました (実発注: $sides)'));
    if (!_rest.hasCredentials) {
      _log(BotEvent.warning(
        'APIキーが未設定です。相場の判定だけ行い、注文は出しません。',
      ));
    }
    _emitSnapshot();

    try {
      await _rest.syncTime();
      _lastTimeSync = DateTime.now();
      _log(BotEvent.info('時刻同期 完了 (ずれ ${_rest.timeOffsetMs} ms)'));

      await _feed.refreshContracts();
      _lastContractRefresh = DateTime.now();

      await _feed.refreshTickers();
      await _refreshWatchlist(force: true);
      await _ws.setTickerSubscription(true);

      if (_rest.hasCredentials) {
        await _checkPositionMode();
        await _syncExchangeState();
      }
    } catch (e) {
      _lastError = '$e';
      _log(BotEvent.error('起動処理でエラー: $e'));
    }

    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(seconds: _config.evaluationIntervalSeconds),
      (_) => unawaited(_runCycle()),
    );
    unawaited(_runCycle());
    _emitSnapshot();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    await _ws.setSubscriptions({});
    await _ws.setTickerSubscription(false);
    _log(BotEvent.info('ボットを停止しました'));
    _emitSnapshot();
  }

  /// 設定を差し替える。稼働中なら監視銘柄と判定間隔をその場で作り直す。
  Future<void> updateConfig(StrategyConfig config) async {
    final intervalChanged =
        config.evaluationIntervalSeconds != _config.evaluationIntervalSeconds;
    _config = config;
    _log(BotEvent.info('設定を更新しました'));

    if (_running) {
      if (intervalChanged) {
        _timer?.cancel();
        _timer = Timer.periodic(
          Duration(seconds: _config.evaluationIntervalSeconds),
          (_) => unawaited(_runCycle()),
        );
      }
      await _refreshWatchlist(force: true);
    }
    _emitSnapshot();
  }

  // ── 判定サイクル ────────────────────────────────────────────

  Future<void> _runCycle() async {
    if (!_running || _cycleInFlight) return;
    _cycleInFlight = true;
    final sw = Stopwatch()..start();
    try {
      final now = DateTime.now();

      if (now.difference(_lastTimeSync) > timeSyncInterval) {
        await _rest.syncTime();
        _lastTimeSync = now;
      }
      if (now.difference(_lastContractRefresh) > contractRefreshInterval) {
        await _feed.refreshContracts();
        _lastContractRefresh = now;
      }

      await _feed.refreshTickers();
      _feed.applyTickerPrices(_config.timeframes);

      // 起動直後やレート制限で取りこぼした履歴を少しずつ埋める。
      _feed.fillMissingHistory();

      if (now.difference(_lastWatchlistRefresh) > watchlistRefreshInterval) {
        await _refreshWatchlist();
      }
      if (_config.fundingFilterEnabled) {
        // 資金調達率は ticker に入っているので、取り直しは要らない。
        _feed.updateFundingsFromTickers();
        // 調達の間隔だけは銘柄ごとに引く必要があるので、少しずつ集める。
        _feed.fillMissingFundingCycles();
        // 間隔はまず変わらないが、念のため1日に1回だけ取り直す。
        if (now.difference(_lastFundingRefresh) > fundingCycleRefreshInterval) {
          _lastFundingRefresh = now;
          _feed.invalidateFundingCycles();
        }
      }

      // 新規を出す前に「いま何を持っているか」を取引所から取り直す。
      // 決済済みの建玉もここで拾う。
      await _syncExchangeState();

      final evaluations = _evaluateAll();
      _lastEvaluations = evaluations
          .where((e) => e.rejectReason != RejectReason.insufficientData)
          .toList()
        ..sort(_evaluationOrder);
      if (_lastEvaluations.length > maxEvaluationsInSnapshot) {
        _lastEvaluations =
            _lastEvaluations.sublist(0, maxEvaluationsInSnapshot);
      }

      for (final evaluation in evaluations.where((e) => e.isTriggered)) {
        await _handleSignal(evaluation);
      }

      _lastError = null;
    } catch (e) {
      _lastError = '$e';
      _log(BotEvent.error('判定サイクルでエラー: $e'));
    } finally {
      sw.stop();
      _lastCycleAt = DateTime.now();
      _lastCycleDurationMs = sw.elapsedMilliseconds;
      _cycleInFlight = false;
      _emitSnapshot();
    }
  }

  /// 画面に出す並び順。成立したものが先、あとは RSI が振り切れている順。
  static int _evaluationOrder(SignalEvaluation a, SignalEvaluation b) {
    if (a.isTriggered != b.isTriggered) return a.isTriggered ? -1 : 1;
    final extremeA = ((a.rsi ?? 50) - 50).abs();
    final extremeB = ((b.rsi ?? 50) - 50).abs();
    return extremeB.compareTo(extremeA);
  }

  List<SignalEvaluation> _evaluateAll() {
    final evaluator = StrategyEvaluator(_config);
    final sides = _config.enabledSides;
    final out = <SignalEvaluation>[];
    if (sides.isEmpty) return out;

    for (final symbol in _watchlist) {
      final contract = _feed.contractOf(symbol);
      if (contract == null) continue;
      final ticker = _feed.tickerOf(symbol);
      final funding = _feed.fundingOf(symbol);
      for (final tf in _config.timeframes) {
        final series = _feed.seriesOf(symbol, tf);
        if (series == null) continue;
        for (final side in sides) {
          final evaluation = evaluator.evaluate(
            symbol: symbol,
            timeframe: tf,
            direction: side.direction,
            series: series,
            contract: contract,
            ticker: ticker,
            funding: funding,
          );
          out.add(_applyPortfolioFilters(evaluation));
        }
      }
    }
    return out;
  }

  /// 指標以外 (保有状況・クールダウン・同じ足での連発) の条件を重ねる。
  SignalEvaluation _applyPortfolioFilters(SignalEvaluation evaluation) {
    if (!evaluation.isTriggered) return evaluation;

    RejectReason? reason;
    final key = _firedBarKey(evaluation);

    if (isHolding(evaluation.symbol)) {
      // すでに建玉がある銘柄には、向きが同じでも違っても新規は出さない。
      // 出すのは利確 (決済) だけ。
      reason = RejectReason.alreadyHolding;
    } else {
      final until = _cooldownUntil[evaluation.symbol];
      if (until != null && DateTime.now().isBefore(until)) {
        reason = RejectReason.cooldown;
      } else if (_config.oneSignalPerBar &&
          _firedBars[key] == evaluation.barOpenTime) {
        reason = RejectReason.cooldown;
      }
    }

    if (reason == null) return evaluation;
    return evaluation.rejected(reason);
  }

  String _firedBarKey(SignalEvaluation e) =>
      '${e.symbol}|${e.timeframe.interval}|${e.direction.name}';

  /// その銘柄の建玉をすでに持っているか。
  ///
  /// ボットが建てたものだけでなく、取引所にある建玉 (手動で建てたものや
  /// 再起動前のもの) も含めて見る。方向が逆でも「保有中」とみなす。
  bool isHolding(String symbol) =>
      _heldSymbols.contains(symbol) ||
      _positions.values.any((p) => p.symbol == symbol);

  Future<void> _handleSignal(SignalEvaluation evaluation) async {
    final contract = _feed.contractOf(evaluation.symbol);
    if (contract == null) return;

    // 同じサイクルで別の時間軸や反対方向が先に建てている場合があるので、
    // 発注の直前にもう一度見る。
    if (isHolding(evaluation.symbol)) return;

    _firedBars[_firedBarKey(evaluation)] = evaluation.barOpenTime;

    final side = _config.sideOf(evaluation.direction);
    final isShort = evaluation.direction.isShort;
    final band = evaluation.bbBoundary;
    final sigmaLabel = '${isShort ? "+" : "-"}${side.bbSigma}σ';
    final detail = evaluation.byBandBreakout
        ? '$sigmaLabel から '
            '${((evaluation.bandDeviation ?? 0) * 100).toStringAsFixed(1)}% '
            '離れたので RSI を見ずに逆張り'
        : 'RSI ${evaluation.rsi?.toStringAsFixed(1) ?? "-"} / '
            '$sigmaLabel ${band?.toStringAsFixed(contract.priceScale) ?? "-"} を'
            '${isShort ? "上抜け" : "下抜け"}';
    _log(
      BotEvent.trade(
        '${evaluation.symbol} ${evaluation.timeframe.label} '
        '${evaluation.direction.label}シグナル検知 '
        '価格 ${evaluation.price} / $detail / '
        '利確 '
        '${evaluation.takeProfitPrice?.toStringAsFixed(contract.priceScale) ?? "-"}',
        symbol: evaluation.symbol,
        data: evaluation.toJson(),
      ),
    );

    if (!_rest.hasCredentials) {
      _log(BotEvent.warning('APIキーが未設定のため発注できません。'));
      return;
    }

    try {
      final position = await _executor.open(
        evaluation: evaluation,
        contract: contract,
        config: _config,
      );
      _positions[position.id] = position;
      // 取引所の一覧に載るまでの間も、同じ銘柄へ重ねて出さないようにする。
      _heldSymbols = {..._heldSymbols, position.symbol};

      // 建玉 ID は発注直後には分からないので、取引所から引き当てる。
      unawaited(_attachExchangePosition(position));
    } on MexcApiException catch (e) {
      _log(BotEvent.error(
        '${evaluation.symbol} の発注に失敗: ${e.description}',
        symbol: evaluation.symbol,
      ));
    } catch (e) {
      _log(BotEvent.error(
        '${evaluation.symbol} の発注に失敗: $e',
        symbol: evaluation.symbol,
      ));
    }
  }

  Future<void> _attachExchangePosition(ManagedPosition position) async {
    try {
      await Future<void>.delayed(const Duration(seconds: 2));
      final list = await _rest.fetchOpenPositions(symbol: position.symbol);
      final match = list
          .where((p) =>
              p.isOpen && p.positionType == position.direction.positionType)
          .firstOrNull;
      if (match == null) return;
      final current = _positions[position.id];
      if (current == null) return;
      _positions[position.id] =
          current.copyWith(exchangePositionId: match.positionId);

      // 発注時に利確を付けていない設定なら、ここでポジションに紐づける。
      if (!_config.attachTakeProfitToOrder) {
        await _rest.placePositionTpSl(
          positionId: match.positionId,
          vol: current.vol,
          takeProfitPrice: current.takeProfitPrice,
        );
        _log(BotEvent.info(
          '${position.symbol}: 建玉に利確 ${current.takeProfitPrice} を設定しました',
          symbol: position.symbol,
        ));
      }
    } catch (e) {
      _log(BotEvent.warning('${position.symbol}: 建玉の紐付けに失敗: $e'));
    }
  }

  /// 口座の建玉モードと設定が食い違っていないか確かめる。
  ///
  /// ヘッジ / 一方向を取り違えると、決済の指定方法が変わって注文が通らない。
  /// モードの変更は「未約定注文・プラン注文・建玉がすべて無い」状態でしか
  /// できないので、ここでは知らせるだけにして勝手に変更はしない。
  Future<void> _checkPositionMode() async {
    try {
      final mode = await _rest.fetchPositionMode();
      if (mode != _config.positionModeValue) {
        _log(BotEvent.warning(
          '口座が「ヘッジモード」になっています。このボットは一方向モードで動くので、'
          'MEXC 側を一方向に切り替えてください '
          '(建玉・未約定注文・プラン注文をすべて無くしてから変更できます)。',
        ));
      }
    } catch (e) {
      _log(BotEvent.warning('建玉モードを確認できません: $e'));
    }
  }

  // ── ポジション管理 ──────────────────────────────────────────

  /// 取引所の建玉を正として、手元の状態を合わせる。
  ///
  /// 利確は発注時に取引所へ預けてあるので、決済されると建玉一覧から消える。
  /// 通信に失敗したときは保有銘柄の記録をそのまま残す (取りこぼして
  /// 同じ銘柄に重ねて注文を出すより、1 サイクル見送るほうが安全)。
  Future<void> _syncExchangeState() async {
    if (!_rest.hasCredentials) return;
    try {
      final assets = await _rest.fetchAssets();
      _asset = assets.where((a) => a.currency == 'USDT').firstOrNull ??
          (assets.isEmpty ? null : assets.first);

      final exchangePositions = await _rest.fetchOpenPositions();
      final open = exchangePositions
          .where((p) => p.isOpen && p.holdVol > 0)
          .toList();
      final openSymbols = open.map((p) => p.symbol).toSet();

      // 発注直後でまだ一覧に載っていない建玉も、保有中として扱い続ける。
      final pending = _positions.values
          .where((p) =>
              DateTime.now().difference(p.openedAt) < exchangeSyncGrace)
          .map((p) => p.symbol);
      _heldSymbols = {...openSymbols, ...pending};

      for (final position in _positions.values.toList()) {
        // 発注直後は反映が遅れることがあるので少し猶予を置く。
        final age = DateTime.now().difference(position.openedAt);
        if (age < exchangeSyncGrace) continue;

        final match = open
            .where((p) =>
                p.symbol == position.symbol &&
                p.positionType == position.direction.positionType)
            .firstOrNull;

        if (match == null) {
          final ticker = _feed.tickerOf(position.symbol);
          final closePrice = ticker?.lastPrice ?? position.takeProfitPrice;
          final contract = _feed.contractOf(position.symbol);
          final fee = contract == null
              ? 0.0
              : (position.entryPrice + closePrice) *
                  position.vol *
                  position.contractSize *
                  contract.takerFeeRate;
          final pnl = position.pnlAt(closePrice) - fee;
          _finishPosition(
            position.copyWith(
              status: ManagedPositionStatus.closed,
              closedAt: DateTime.now(),
              closePrice: closePrice,
              realizedPnl: pnl,
              note: '取引所側で決済',
            ),
          );
          continue;
        }

        // 建玉 ID をまだ持っていなければ結び付ける。
        if (position.exchangePositionId == null) {
          _positions[position.id] =
              position.copyWith(exchangePositionId: match.positionId);
        }
      }

      // ボットが把握していない建玉があれば知らせる (手動売買や再起動前の建玉)。
      // これらの銘柄にも新規注文は出さない。
      final managedSymbols = _positions.values.map((p) => p.symbol).toSet();
      for (final p in open) {
        if (managedSymbols.contains(p.symbol)) continue;
        if (!_warnedForeignSymbols.add(p.symbol)) continue;
        _log(BotEvent.warning(
          '${p.symbol}: ボット管理外の'
          '${TradeDirection.fromPositionType(p.positionType).label}建玉があります '
          '(${p.holdVol} 枚 @ ${p.holdAvgPrice})。この銘柄には新規注文を出しません。',
          symbol: p.symbol,
        ));
      }
      _warnedForeignSymbols.removeWhere((s) => !openSymbols.contains(s));
    } on MexcApiException catch (e) {
      _log(BotEvent.warning('口座情報の同期に失敗: ${e.description}'));
    } catch (e) {
      _log(BotEvent.warning('口座情報の同期に失敗: $e'));
    }
  }

  void _finishPosition(ManagedPosition closed) {
    _positions.remove(closed.id);
    _closedPositions.add(closed);
    if (_closedPositions.length > maxClosedPositionsKept) {
      _closedPositions.removeRange(
        0,
        _closedPositions.length - maxClosedPositionsKept,
      );
    }
    _cooldownUntil[closed.symbol] =
        DateTime.now().add(Duration(minutes: _config.reentryCooldownMinutes));
    _log(BotEvent.trade(
      '${closed.symbol} ${closed.direction.label}決済 (${closed.note ?? ''}) '
      '損益 ${closed.realizedPnl?.toStringAsFixed(4) ?? '-'} USDT',
      symbol: closed.symbol,
      data: closed.toJson(),
    ));
  }

  /// 建玉の利確 / 損切りラインを、建てたあとから動かす。
  ///
  /// 取引所に預けてある注文を置き直してから、手元の記録を合わせる。
  /// 取引所への反映に失敗したときは手元も変えない (食い違わせない)。
  Future<void> updatePositionExit(
    String id, {
    double? takeProfitPrice,
    double? stopLossPrice,
    bool clearStopLoss = false,
  }) async {
    final position = _positions[id];
    if (position == null) return;
    final contract = _feed.contractOf(position.symbol);
    final isShort = position.direction.isShort;

    double round(double price, {required bool forProfit}) {
      if (contract == null) return price;
      // 決済注文が約定しやすい側へ丸める。利確と損切りでは向きが逆になる。
      return contract.roundPrice(price, roundUp: forProfit ? isShort : !isShort);
    }

    final tp = takeProfitPrice == null
        ? position.takeProfitPrice
        : round(takeProfitPrice, forProfit: true);
    final sl = clearStopLoss
        ? null
        : (stopLossPrice == null
            ? position.stopLossPrice
            : round(stopLossPrice, forProfit: false));

    if (_rest.hasCredentials && position.exchangePositionId != null) {
      try {
        await _rest.placePositionTpSl(
          positionId: position.exchangePositionId!,
          vol: position.vol,
          takeProfitPrice: tp,
          stopLossPrice: sl,
        );
      } catch (e) {
        _log(BotEvent.error(
          '${position.symbol}: 利確/損切りの置き直しに失敗: $e',
          symbol: position.symbol,
        ));
        _emitSnapshot();
        return;
      }
    }

    _positions[id] = position.copyWith(
      takeProfitPrice: tp,
      stopLossPrice: sl,
      clearStopLoss: clearStopLoss || sl == null,
    );
    _log(BotEvent.info(
      '${position.symbol}: 利確 $tp / 損切り ${sl ?? "なし"} に置き直しました',
      symbol: position.symbol,
    ));
    _emitSnapshot();
  }

  /// 画面からの手動決済。
  Future<void> closePositionManually(String id) async {
    final position = _positions[id];
    if (position == null) return;
    final contract = _feed.contractOf(position.symbol);
    final ticker = _feed.tickerOf(position.symbol);
    if (contract == null || ticker == null) {
      _log(BotEvent.warning('${position.symbol}: 相場データが無く決済できません'));
      return;
    }
    try {
      final closed = await _executor.close(
        position: position,
        contract: contract,
        config: _config,
        markPrice: ticker.lastPrice,
        note: '手動決済',
      );
      _finishPosition(closed);
      _heldSymbols = {..._heldSymbols}..remove(position.symbol);
    } catch (e) {
      _log(BotEvent.error('${position.symbol} の決済に失敗: $e'));
    }
    _emitSnapshot();
  }

  // ── 監視銘柄 ────────────────────────────────────────────────

  Future<void> _refreshWatchlist({bool force = false}) async {
    final selected = _selectSymbols();
    final changed = force ||
        selected.length != _watchlist.length ||
        !selected.every(_watchlist.contains);
    _lastWatchlistRefresh = DateTime.now();
    if (!changed) return;

    _watchlist = selected;
    await _feed.setWatchlist(
      selected,
      _config.timeframes,
      historyBars: _config.historyBars,
    );
    _log(BotEvent.info(
      '監視銘柄を更新: ${selected.length} 銘柄 × ${_config.timeframes.length} 時間軸 '
      '= ${selected.length * _config.timeframes.length} 系列',
    ));

    if (_config.fundingFilterEnabled) {
      _feed.updateFundingsFromTickers();
      // ここで全銘柄ぶんを積むと、同じ枠を使う ticker の取得が後ろで
      // 待たされ、判定サイクルが丸ごと止まる。少しずつ集める。
      _feed.fillMissingFundingCycles();
    }
  }

  /// 監視する銘柄は出来高だけで決める。手で選んだり外したりはしない。
  List<String> _selectSymbols() {
    final contracts = _feed.contracts;
    final candidates = _feed.tickers.values
        .where((t) => contracts.containsKey(t.symbol))
        .where((t) => t.amount24 >= _config.minAmount24Usdt)
        .toList()
      ..sort((a, b) => b.amount24.compareTo(a.amount24));

    return candidates.map((t) => t.symbol).toList();
  }

  // ── 雑務 ────────────────────────────────────────────────────

  void _log(BotEvent event) {
    if (!_eventController.isClosed) _eventController.add(event);
  }

  void _emitSnapshot() {
    if (!_snapshotController.isClosed) _snapshotController.add(snapshot);
  }

  /// 保存してある建玉を復元する (サーバー再起動時など)。
  void restorePositions(Iterable<ManagedPosition> positions) {
    for (final p in positions) {
      if (p.status == ManagedPositionStatus.open) {
        _positions[p.id] = p;
      } else {
        _closedPositions.add(p);
      }
    }
  }

  List<ManagedPosition> get allPositions => [
    ..._positions.values,
    ..._closedPositions,
  ];

  Future<void> dispose() async {
    _timer?.cancel();
    await _wsStatusSub?.cancel();
    await _feed.dispose();
    await _ws.dispose();
    _rest.close();
    await _eventController.close();
    await _snapshotController.close();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
