import 'dart:async';

import '../api/mexc_exception.dart';
import '../api/mexc_rest_client.dart';
import '../api/mexc_ws_client.dart';
import '../models/bot_event.dart';
import '../models/contract_info.dart';
import '../models/manual_order.dart';
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


  /// 取引所側に建玉がある銘柄。ボットが建てたものも、手で建てたものも入る。
  ///
  /// ここに入っている銘柄へは新規注文を出さない (利確・決済だけ行う)。
  Set<String> _heldSymbols = {};

  /// 通ったかどうか分からない新規注文を出した銘柄と、分からなくなった時刻。
  ///
  /// 通っていれば取引所の一覧に載るので、載るまでの猶予
  /// ([exchangeSyncGrace]) の間は保有中とみなし、重ねて出さない。
  final Map<String, DateTime> _unsureOrders = {};

  /// 取引所にある建玉 (手で建てたものも) と、決済の記録。画面に出すために持つ。
  List<PositionInfo>? _exchangeOpen;
  List<PositionInfo>? _exchangeClosed;
  DateTime _lastHistoryFetch = DateTime.fromMillisecondsSinceEpoch(0);

  /// 決済の記録を取り直す間隔。建玉が減ったとき (決済されたとき) はすぐ取る。
  static const Duration historyRefreshInterval = Duration(minutes: 5);

  /// 画面に返す決済の記録の件数。
  static const int maxExchangeClosedInSnapshot = 50;

  /// 取引所に出ている指値と条件付き注文 (手で出したものも)。まだ取って
  /// いなければ null。
  List<ExchangeOrder>? _openOrders;
  bool _warnedOrderFetch = false;

  /// 条件付き注文に付けた利確 / 損切りの予約。発動して建玉ができたら置く。
  final List<PendingExit> _pendingExits = [];

  /// 予約の条件付き注文が一覧から消えた時刻。発動して建つまで少し待つ。
  final Map<String, DateTime> _planGoneAt = {};

  /// 予約を置こうとして失敗した回数。何度も失敗するものは諦めて知らせる。
  final Map<String, int> _pendingExitFailures = {};

  /// 止めている間も、予約がある間は取引所を見に行く。
  Timer? _manualTimer;

  /// 予約が変わったときに呼ぶ (サーバーがファイルに残す)。
  void Function(List<PendingExit> exits)? onPendingExitsChanged;

  /// 予約の条件付き注文が消えてから、建玉が出てこなければ諦めるまでの時間。
  static const Duration pendingExitGoneGrace = Duration(minutes: 3);

  /// 止めている間に、予約のために取引所を見に行く間隔。
  static const Duration manualSyncInterval = Duration(seconds: 30);

  int _manualOrderSerial = 0;

  /// 管理外の建玉について、すでに知らせた銘柄。同じ警告を毎分出さないため。
  final Set<String> _warnedForeignSymbols = {};

  /// 時間切れの決済に失敗した建玉と、次に試してよい時刻。毎分同じ失敗を出さないため。
  final Map<String, DateTime> _expiryRetryAt = {};

  /// 時間切れの決済に失敗したとき、次に試すまでの間隔。
  static const Duration expiryRetryInterval = Duration(minutes: 5);

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
      for (final symbol in {
        for (final p in _positions.values) p.symbol,
        for (final p in _exchangeOpen ?? const <PositionInfo>[]) p.symbol,
      })
        if (_feed.tickerOf(symbol) != null)
          symbol: _feed.tickerOf(symbol)!.lastPrice,
    },
    lastCycleAt: _lastCycleAt,
    lastCycleDurationMs: _lastCycleDurationMs,
    asset: _asset,
    lastError: _lastError,
    credentialsConfigured: _rest.hasCredentials,
    exchangePositions: _exchangeOpen,
    exchangeClosed: _exchangeClosed
        ?.take(maxExchangeClosedInSnapshot)
        .toList(growable: false),
    contractSizes: {
      for (final p in _exchangeOpen ?? const <PositionInfo>[])
        if (_feed.contractOf(p.symbol) != null)
          p.symbol: _feed.contractOf(p.symbol)!.contractSize,
    },
    openOrders: _openOrders,
    pendingExits: List.unmodifiable(_pendingExits),
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
    final sides = _config.activeLabels.join(' / ');
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

    if (!_running) {
      // 止まっている間は購読はせず、選び直した数だけ見せる (下限を変えたら
      // すぐ数に表れるように)。開始したときに改めて選んで購読する。
      if (_feed.tickers.isNotEmpty) _watchlist = _selectSymbols();
    } else {
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
      // 資金調達率は ticker に入っているので、取り直しは要らない。
      _feed.updateFundingsFromTickers();
      // 調達の間隔だけは銘柄ごとに引く必要があるので、少しずつ集める。
      _feed.fillMissingFundingCycles();
      // 間隔はまず変わらないが、念のため1日に1回だけ取り直す。
      if (now.difference(_lastFundingRefresh) > fundingCycleRefreshInterval) {
        _lastFundingRefresh = now;
        _feed.invalidateFundingCycles();
      }

      // 新規を出す前に「いま何を持っているか」を取引所から取り直す。
      // 決済済みの建玉もここで拾う。
      await _syncExchangeState();

      // 最長保有時間を過ぎた建玉を成行で閉じる。
      await _closeExpiredPositions();

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
    // 今までの手法の向きと、検証済みの手法。同じ足を両方の条件で見る。
    final sides = _config.activeSides;
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
        for (final (kind, side) in sides) {
          // 時間軸は手法・方向ごとに選べる。見ない足は評価しない。
          if (!side.timeframes.contains(tf)) continue;
          final evaluation = evaluator.evaluate(
            symbol: symbol,
            timeframe: tf,
            direction: side.direction,
            series: series,
            contract: contract,
            ticker: ticker,
            funding: funding,
            sideConfig: side,
            strategy: kind,
          );
          out.add(_applyPortfolioFilters(evaluation));
        }
      }
    }
    return out;
  }

  /// 指標以外 (保有状況・再エントリー待ち) の条件を重ねる。
  ///
  /// 建玉のある銘柄は、持っている間は 1 回しか発火しない (重ねて建てない)。
  SignalEvaluation _applyPortfolioFilters(SignalEvaluation evaluation) {
    if (!evaluation.isTriggered) return evaluation;

    RejectReason? reason;
    if (isHolding(evaluation.symbol)) {
      // すでに建玉がある銘柄には、向きが同じでも違っても新規は出さない。
      // 出すのは利確 (決済) だけ。
      reason = RejectReason.alreadyHolding;
    } else if (atPositionLimit ||
        (evaluation.strategy == StrategyKind.verified && verifiedAtLimit)) {
      reason = RejectReason.maxPositions;
    } else {
      final until = _cooldownUntil[evaluation.symbol];
      if (until != null && DateTime.now().isBefore(until)) {
        reason = RejectReason.cooldown;
      }
    }

    if (reason == null) return evaluation;
    return evaluation.rejected(reason);
  }


  /// その銘柄の建玉をすでに持っているか。
  ///
  /// ボットが建てたものだけでなく、取引所にある建玉 (手動で建てたものや
  /// 再起動前のもの) も含めて見る。方向が逆でも「保有中」とみなす。
  bool isHolding(String symbol) =>
      _heldSymbols.contains(symbol) ||
      _positions.values.any((p) => p.symbol == symbol);

  /// 同時に持つ建玉の上限 ([StrategyConfig.maxOpenPositions]) に達しているか。
  ///
  /// 取引所にある建玉 (手で建てたもの・発注直後でまだ載っていないものも) を
  /// 銘柄の数で数える。
  bool get atPositionLimit {
    final limit = _config.maxOpenPositions;
    if (limit <= 0) return false;
    final held = {..._heldSymbols, ..._positions.values.map((p) => p.symbol)};
    return held.length >= limit;
  }

  /// 検証済みの手法の上限 ([StrategyConfig.verifiedMaxOpenPositions]) に
  /// 達しているか。この手法で建てた建玉 (発注直後の物も) だけを数える。
  bool get verifiedAtLimit {
    final limit = _config.verifiedMaxOpenPositions;
    if (limit <= 0) return false;
    final count = _positions.values
        .where((p) => p.strategy == StrategyKind.verified)
        .length;
    return count >= limit;
  }

  Future<void> _handleSignal(SignalEvaluation evaluation) async {
    final contract = _feed.contractOf(evaluation.symbol);
    if (contract == null) return;

    // 同じサイクルで別の時間軸や反対方向・別の手法が先に建てている場合が
    // あるので、発注の直前にもう一度見る。上限も同じサイクルの発注で埋まる
    // ことがある。
    if (isHolding(evaluation.symbol)) return;
    if (atPositionLimit) return;
    final byVerified = evaluation.strategy == StrategyKind.verified;
    if (byVerified && verifiedAtLimit) return;

    final side = _config.sideFor(evaluation.strategy, evaluation.direction);
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
        '${byVerified ? "[検証済み] " : ""}'
        '${evaluation.symbol} ${evaluation.timeframe.label} '
        '${evaluation.direction.label}シグナル検知 '
        '価格 ${evaluation.price} / $detail / '
        '利確 '
        '${evaluation.takeProfitPrice?.toStringAsFixed(contract.priceScale) ?? "-"}'
        '${evaluation.stopLossPrice == null ? "" : " / 損切り ${evaluation.stopLossPrice!.toStringAsFixed(contract.priceScale)}"}',
        symbol: evaluation.symbol,
        data: evaluation.toJson(),
      ),
    );

    if (!_rest.hasCredentials) {
      _log(BotEvent.warning('APIキーが未設定のため発注出来ません。'));
      return;
    }

    try {
      final position = await _executor.open(
        evaluation: evaluation,
        contract: contract,
        config: _config,
        availableUsdt: _asset?.availableBalance,
        equityUsdt: _asset?.equity,
      );
      _positions[position.id] = position;
      // 取引所の一覧に載るまでの間も、同じ銘柄へ重ねて出さないようにする。
      _heldSymbols = {..._heldSymbols, position.symbol};

      // 建玉 ID は発注直後には分からないので、取引所から引き当てる。
      unawaited(_attachExchangePosition(position));
      // 残った資金で、逆行した所に買い足し / 売り足しの指値を置く。
      if (side.addOnEnabled) unawaited(_placeAddOnOrder(position.id));
    } on MexcOrderUnknownException catch (e) {
      // 送り直すと二重に建つおそれがあるので、取引所の建玉で確かめられる
      // までこの銘柄には新規を出さない。通っていれば、同じ注文で預けた
      // 利確で決済される。
      _unsureOrders[evaluation.symbol] = DateTime.now();
      _heldSymbols = {..._heldSymbols, evaluation.symbol};
      _log(BotEvent.error(
        '${evaluation.symbol} の発注が通ったかどうか分かりません (${e.message})。'
        '二重に建てないよう、取引所の建玉を確かめるまでこの銘柄には新規を出しません。',
        symbol: evaluation.symbol,
      ));
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

  /// 成行の約定で減ったあとの残高を見てから、買い足しの指値を置く。
  ///
  /// 失敗しても建玉そのものには影響しないので、知らせるだけにする。
  Future<void> _placeAddOnOrder(String positionId) async {
    try {
      // 成行の証拠金が引かれるのを少し待ってから残高を見る。
      await Future<void>.delayed(const Duration(seconds: 2));
      final position = _positions[positionId];
      if (position == null || position.addOnOrderId != null) return;
      final contract = _feed.contractOf(position.symbol);
      if (contract == null) return;

      final assets = await _rest.fetchAssets();
      final usdt = assets.where((a) => a.currency == 'USDT').firstOrNull;
      final available = usdt?.availableBalance ?? 0;
      if (available <= 0) {
        _log(BotEvent.warning(
          '${position.symbol}: 残り資金が無いので買い足しの指値は置きません',
          symbol: position.symbol,
        ));
        return;
      }

      final updated = await _executor.placeAddOn(
        position: position,
        contract: contract,
        config: _config,
        // 手数料ぶんだけ余らせる。ぴったり使うと残高不足で弾かれる。
        availableUsdt: available * 0.99,
      );
      // 待っている間に決済されていたら、置いた指値をすぐ取り消す。
      final latest = _positions[positionId];
      if (latest == null) {
        await _executor.cancelAddOn(updated);
        return;
      }
      // 待っている間に建玉 ID が付いているかもしれないので、最新の記録に
      // 買い足しの分だけ足す (古い記録で上書きしない)。
      _positions[positionId] = latest.copyWith(
        addOnOrderId: updated.addOnOrderId,
        addOnPrice: updated.addOnPrice,
        addOnVol: updated.addOnVol,
        addOnFilled: false,
      );
      _emitSnapshot();
    } on MexcOrderUnknownException catch (e) {
      // 送り直すと指値が 2 本になるので、送り直さずに知らせる。
      _log(BotEvent.warning(
        '買い足しの指値が通ったかどうか分かりません (${e.message})。'
        'MEXC の未約定注文を確かめて下さい。',
      ));
    } on MexcApiException catch (e) {
      _log(BotEvent.warning('買い足しの指値を置けませんでした: ${e.description}'));
    } catch (e) {
      _log(BotEvent.warning('買い足しの指値を置けませんでした: $e'));
    }
  }

  /// 残っている買い足しの指値を取り消す。決済したあとに約定して
  /// 建玉が復活してしまわないようにするため。
  Future<void> _cancelAddOnOrder(ManagedPosition position) async {
    if (!position.hasPendingAddOn) return;
    try {
      await _executor.cancelAddOn(position);
    } on MexcApiException catch (e) {
      // 既に約定 / 取消済みなら弾かれる。それ以上できることは無い。
      _log(BotEvent.warning(
        '${position.symbol}: 買い足しの指値を取り消せませんでした (${e.description})',
        symbol: position.symbol,
      ));
    } catch (e) {
      _log(BotEvent.warning(
        '${position.symbol}: 買い足しの指値を取り消せませんでした ($e)',
        symbol: position.symbol,
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
          'MEXC 側を一方向に切り替えて下さい '
          '(建玉・未約定注文・プラン注文を全て無くしてから変更出来ます)。',
        ));
      }
    } catch (e) {
      _log(BotEvent.warning('建玉モードを確認出来ません: $e'));
    }
  }

  // ── ポジション管理 ──────────────────────────────────────────

  /// 取引所の建玉を正として、手元の状態を合わせる。
  ///
  /// 利確は発注時に取引所へ預けてあるので、決済されると建玉一覧から消える。
  /// 通信に失敗したときは保有銘柄の記録をそのまま残す (取りこぼして
  /// 同じ銘柄に重ねて注文を出すより、1 サイクル見送るほうが安全)。
  Future<void> _syncExchangeState({bool includeHistory = false}) async {
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
      // 建玉が減ったら決済されたので、決済の記録もすぐ取り直す。
      final closedSome = (_exchangeOpen?.length ?? 0) > open.length;
      _exchangeOpen = open;
      if (includeHistory ||
          closedSome ||
          DateTime.now().difference(_lastHistoryFetch) >
              historyRefreshInterval) {
        await _refreshExchangeHistory();
      }

      // 発注直後でまだ一覧に載っていない建玉も、保有中として扱い続ける。
      final pending = _positions.values
          .where((p) =>
              DateTime.now().difference(p.openedAt) < exchangeSyncGrace)
          .map((p) => p.symbol);
      // 通ったかどうか分からない注文も、同じだけ猶予を置く。
      _unsureOrders.removeWhere(
        (_, at) => DateTime.now().difference(at) >= exchangeSyncGrace,
      );
      // 出ている注文も取る。手で出した新規の注文がある銘柄には、ボットは
      // 入らない (約定すると手の注文とボットの建玉が 1 つにまとまるため)。
      final orders = await _fetchOpenOrders();
      if (orders != null) _openOrders = orders;
      final manualOrderSymbols = {
        for (final o in _openOrders ?? const <ExchangeOrder>[])
          if (o.opens && !o.fromBot) o.symbol,
      };
      _heldSymbols = {
        ...openSymbols,
        ...pending,
        ..._unsureOrders.keys,
        ...manualOrderSymbols,
      };

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
          // 買い足しの指値が残っていれば取り消す。放っておくと約定して
          // 管理外の建玉になってしまう。
          unawaited(_cancelAddOnOrder(position));
          continue;
        }

        var current = position;
        // 建玉 ID をまだ持っていなければ結び付ける。
        if (current.exchangePositionId == null) {
          current = current.copyWith(exchangePositionId: match.positionId);
        }
        // 買い足しの指値が約定して枚数が増えていたら、平均建値と枚数を
        // 取引所の値に合わせ、利確を全枚数ぶんに置き直す。
        if (current.hasPendingAddOn && match.holdVol > current.vol * 1.0001) {
          current = current.copyWith(
            vol: match.holdVol,
            entryPrice: match.holdAvgPrice > 0 ? match.holdAvgPrice : null,
            addOnFilled: true,
          );
          _log(BotEvent.trade(
            '${current.symbol} ${current.direction.label}の'
            '${current.direction.isShort ? "売り足し" : "買い足し"}が約定 '
            '→ ${match.holdVol} 枚 / 平均建値 ${current.entryPrice}',
            symbol: current.symbol,
            data: current.toJson(),
          ));
          unawaited(_replaceTakeProfitFor(current));
        }
        if (!identical(current, position)) _positions[position.id] = current;
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

      if (orders != null) await _applyPendingExits(open, orders);
    } on MexcApiException catch (e) {
      _log(BotEvent.warning('口座情報の同期に失敗: ${e.description}'));
    } catch (e) {
      _log(BotEvent.warning('口座情報の同期に失敗: $e'));
    }
  }

  /// 最長保有時間 ([SideConfig.maxHoldHours]) を過ぎた建玉を成行で閉じる。
  ///
  /// 利確・損切りは取引所に預けてあるが、時間での決済は取引所に預けられない
  /// ので、ボットが判定サイクルごとに見て出す。止めている間は閉じない。
  Future<void> _closeExpiredPositions() async {
    if (!_rest.hasCredentials) return;
    final now = DateTime.now();
    _expiryRetryAt.removeWhere((id, _) => !_positions.containsKey(id));
    for (final position in _positions.values.toList()) {
      final deadline = position.closeDeadline;
      if (deadline == null || now.isBefore(deadline)) continue;
      final retryAt = _expiryRetryAt[position.id];
      if (retryAt != null && now.isBefore(retryAt)) continue;
      final contract = _feed.contractOf(position.symbol);
      final ticker = _feed.tickerOf(position.symbol);
      if (contract == null || ticker == null) continue;
      final hours = (position.maxHoldMinutes! / 60).toStringAsFixed(0);
      // 先に買い足しの指値を消す。決済のあとに約定すると建玉が復活してしまう。
      await _cancelAddOnOrder(position);
      try {
        final closed = await _executor.close(
          position: position,
          contract: contract,
          config: _config,
          markPrice: ticker.lastPrice,
          note: '最長保有 ($hours 時間) で決済',
        );
        _finishPosition(closed);
        _heldSymbols = {..._heldSymbols}..remove(position.symbol);
        _expiryRetryAt.remove(position.id);
      } on MexcApiException catch (e) {
        _expiryRetryAt[position.id] = now.add(expiryRetryInterval);
        _log(BotEvent.error(
          '${position.symbol}: 最長保有時間を過ぎましたが決済出来ませんでした '
          '(${e.description})。${expiryRetryInterval.inMinutes} 分後にもう一度試します。',
          symbol: position.symbol,
        ));
      } catch (e) {
        _expiryRetryAt[position.id] = now.add(expiryRetryInterval);
        _log(BotEvent.error(
          '${position.symbol}: 最長保有時間を過ぎましたが決済出来ませんでした ($e)。'
          '${expiryRetryInterval.inMinutes} 分後にもう一度試します。',
          symbol: position.symbol,
        ));
      }
    }
  }

  /// 取引所の決済の記録を取り直す。取れなくても売買には関わらないので、
  /// 知らせるだけにする。
  Future<void> _refreshExchangeHistory() async {
    _lastHistoryFetch = DateTime.now();
    try {
      _exchangeClosed = await _rest.fetchHistoryPositions(
        pageSize: maxExchangeClosedInSnapshot,
      );
    } catch (e) {
      _log(BotEvent.warning('決済の記録を取れませんでした: $e'));
    }
  }

  /// 枚数が変わった建玉に、利確 (と損切り) を全枚数ぶんで置き直す。
  Future<void> _replaceTakeProfitFor(ManagedPosition position) async {
    final positionId = position.exchangePositionId;
    if (positionId == null || !_rest.hasCredentials) return;
    try {
      await _rest.placePositionTpSl(
        positionId: positionId,
        vol: position.vol,
        takeProfitPrice: position.takeProfitPrice,
        stopLossPrice: position.stopLossPrice,
      );
      _log(BotEvent.info(
        '${position.symbol}: 利確 ${position.takeProfitPrice} を '
        '${position.vol} 枚ぶんに置き直しました',
        symbol: position.symbol,
      ));
    } catch (e) {
      _log(BotEvent.warning(
        '${position.symbol}: 利確の置き直しに失敗: $e '
        '(チャートから利確ラインを一度動かすと置き直せます)',
        symbol: position.symbol,
      ));
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

  /// 口座と建玉だけを取り直す。
  ///
  /// 判定サイクルの中でしか取りに行かないと、止めている間は残高が
  /// いつまでも空のままになる。画面から呼べるようにしておく。
  Future<void> refreshAccount() async {
    if (!_rest.hasCredentials) {
      _log(BotEvent.warning('APIキーが未設定です。残高を取れません。'));
      _emitSnapshot();
      return;
    }
    // 止まっている間は相場を取っていないので、評価損益に使う現在値と
    // 1 枚あたりの数量をここで取り直す。
    if (!_running) {
      try {
        if (_feed.contracts.isEmpty) await _feed.refreshContracts();
        await _feed.refreshTickers();
        _watchlist = _selectSymbols();
      } catch (e) {
        _log(BotEvent.warning('現在値を取り直せませんでした: $e'));
      }
    }
    await _syncExchangeState(includeHistory: true);
    _emitSnapshot();
  }

  /// 決済済みの記録を消す。[id] が null なら全部消す。
  ///
  /// 建玉そのものには触れない。画面の見通しを良くするためだけの操作。
  void clearHistory({String? id}) {
    if (id == null) {
      _closedPositions.clear();
    } else {
      _closedPositions.removeWhere((p) => p.id == id);
    }
    _emitSnapshot();
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
      _log(BotEvent.warning('${position.symbol}: 相場データが無く決済出来ません'));
      return;
    }
    // 先に買い足しの指値を消す。決済のあとに約定すると建玉が復活してしまう。
    await _cancelAddOnOrder(position);
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

  // ── 手で出す注文 (アプリから) ─────────────────────────────

  /// アプリから手で新規注文を出す。出せたら記録に残した説明を返す。
  ///
  /// 銘柄仕様・現在値・残高はこの場で取り直す (止めている間は相場を
  /// 取っていないため)。中身がおかしいときや取引所が弾いたときは例外を
  /// 投げる (サーバーがそのままアプリへ返す)。
  Future<String> placeManualOrder(ManualOrderRequest request) async {
    if (!_rest.hasCredentials) {
      throw StateError('サーバーに取引所の API キーが入っていないので、注文を出せません。');
    }
    final symbol = request.symbol.trim();
    final contract = await _contractFor(symbol);
    final lastPrice = await _lastPriceFor(symbol, refresh: !_running);
    final errors = request.validate(lastPrice: lastPrice);
    if (errors.isNotEmpty) throw StateError(errors.join(' / '));

    final direction = request.direction;
    final isShort = direction.isShort;
    final minLeverage = contract.minLeverage < 1 ? 1 : contract.minLeverage;
    final maxLeverage = contract.maxLeverage < minLeverage
        ? minLeverage
        : contract.maxLeverage;
    final leverage = request.leverage.clamp(minLeverage, maxLeverage);
    if (leverage != request.leverage) {
      _log(BotEvent.info(
        '$symbol: レバレッジを銘柄の範囲 ($minLeverage〜$maxLeverage 倍) に合わせて '
        '$leverage 倍にします',
        symbol: symbol,
      ));
    }

    // 指値は自分に有利な側 (買いは下 / 売りは上) へ刻みを丸める。利確と
    // 損切りは、建玉の利確 / 損切りを置き直すときと同じ向きに丸める。
    final limitPrice = request.price == null
        ? null
        : contract.roundPrice(request.price!, roundUp: isShort);
    final triggerPrice = request.triggerPrice == null
        ? null
        : contract.roundPrice(
            request.triggerPrice!,
            roundUp: request.triggerPrice! >= lastPrice,
          );
    final takeProfit = request.takeProfitPrice == null
        ? null
        : contract.roundPrice(request.takeProfitPrice!, roundUp: isShort);
    final stopLoss = request.stopLossPrice == null
        ? null
        : contract.roundPrice(request.stopLossPrice!, roundUp: !isShort);

    // 数量は「その値段で建てたら」で決める。成行はいまの値段 (約定しやすい側)。
    final reference = switch (request.kind) {
      ManualOrderKind.market =>
        contract.roundPrice(lastPrice, roundUp: !isShort),
      ManualOrderKind.limit => limitPrice!,
      ManualOrderKind.trigger =>
        request.triggerExecution == TriggerExecution.limit
            ? (limitPrice ?? triggerPrice!)
            : triggerPrice!,
    };

    // 証拠金は、いま使える残高を超えない分にする (手数料の分だけ余らせる)。
    await _refreshAssetQuietly();
    var margin = request.marginUsdt;
    final available = _asset?.availableBalance;
    if (available != null && available > 0 && margin > available * 0.99) {
      margin = available * 0.99;
      _log(BotEvent.info(
        '$symbol: 証拠金を使える残高に合わせて ${margin.toStringAsFixed(2)} USDT に'
        '減らします',
        symbol: symbol,
      ));
    }
    final vol = contract.volumeForMargin(
      marginUsdt: margin,
      leverage: leverage.toDouble(),
      price: reference,
    );
    if (vol == null) {
      throw StateError(
        '$symbol: 証拠金 ${margin.toStringAsFixed(2)} USDT × $leverage 倍では'
        '最小数量 (${contract.minVol} 枚) に届きません。',
      );
    }

    // 建玉が無い状態では leverage + openType + symbol + positionType を
    // すべて渡す必要がある。同じ値なら弾かれることがあるが、発注にも
    // leverage を渡すので続ける。
    try {
      await _rest.changeLeverage(
        leverage: leverage,
        openType: _config.openType,
        symbol: symbol,
        positionType: direction.positionType,
      );
    } on MexcApiException catch (e) {
      _log(BotEvent.info('$symbol: レバレッジ設定をスキップ (${e.description})'));
    }

    final externalOid =
        'man${DateTime.now().millisecondsSinceEpoch}${++_manualOrderSerial}';
    late final String orderId;
    switch (request.kind) {
      case ManualOrderKind.market:
      case ManualOrderKind.limit:
        final result = await _rest.createOrder(
          symbol: symbol,
          price: reference,
          vol: vol,
          side: direction.openSide,
          // 1 = 指値 / 5 = 成行。
          type: request.kind == ManualOrderKind.limit ? 1 : 5,
          openType: _config.openType,
          leverage: leverage,
          // 利確と損切りは発注と同時に取引所へ預ける。
          takeProfitPrice: takeProfit,
          stopLossPrice: stopLoss,
          positionMode: _config.positionModeValue,
          externalOid: externalOid,
        );
        orderId = result.orderId;
      case ManualOrderKind.trigger:
        final baseVol = (_exchangeOpen ?? const <PositionInfo>[])
            .where(
              (p) =>
                  p.symbol == symbol &&
                  p.positionType == direction.positionType,
            )
            .fold<double>(0, (sum, p) => sum + p.holdVol);
        orderId = await _rest.placePlanOrder(
          symbol: symbol,
          vol: vol,
          side: direction.openSide,
          openType: _config.openType,
          triggerPrice: triggerPrice!,
          triggerType: ManualOrderRequest.triggerTypeFor(
            triggerPrice,
            lastPrice,
          ),
          price: request.triggerExecution == TriggerExecution.limit
              ? limitPrice
              : null,
          leverage: leverage,
          orderType: request.triggerExecution.orderType,
        );
        // 取引所の条件付き注文には利確 / 損切りを付けられないので、
        // 発動して建玉ができたらサーバーが置く。
        if (takeProfit != null || stopLoss != null) {
          _pendingExits.add(PendingExit(
            planOrderId: orderId,
            symbol: symbol,
            direction: direction,
            createdAt: DateTime.now(),
            takeProfitPrice: takeProfit,
            stopLossPrice: stopLoss,
            baseVol: baseVol,
          ));
          _pendingExitsChanged();
        }
    }

    final message = '手で注文しました: ${request.describe()} → '
        '${vol.toStringAsFixed(contract.volScale)} 枚 (注文ID $orderId)';
    _log(BotEvent.trade(message, symbol: symbol));
    // 約定すれば建玉になる。ボットが同じ銘柄に重ねて入らないようにする。
    _heldSymbols = {..._heldSymbols, symbol};
    final orders = await _fetchOpenOrders();
    if (orders != null) _openOrders = orders;
    _emitSnapshot();
    // 成行はすぐ建つので、少し待って建玉と残高を取り直す。
    if (request.kind == ManualOrderKind.market) {
      unawaited(
        Future<void>.delayed(const Duration(seconds: 2), () async {
          await _syncExchangeState();
          _emitSnapshot();
        }),
      );
    }
    return message;
  }

  /// 取引所に出ている注文を取り消す ([trigger] なら条件付き注文)。
  Future<void> cancelExchangeOrder({
    required String symbol,
    required String orderId,
    required bool trigger,
  }) async {
    if (!_rest.hasCredentials) {
      throw StateError('サーバーに取引所の API キーが入っていないので、取り消せません。');
    }
    if (trigger) {
      await _rest.cancelPlanOrders([(symbol: symbol, orderId: orderId)]);
      final before = _pendingExits.length;
      _pendingExits.removeWhere((e) => e.planOrderId == orderId);
      if (_pendingExits.length != before) _pendingExitsChanged();
    } else {
      await _rest.cancelOrders([orderId]);
      // ボットの買い足しを消したなら、その建玉の記録からも外す
      // (決済のときに、もう無い注文を取り消しに行かないように)。
      for (final p in _positions.values.toList()) {
        if (p.addOnOrderId == orderId && !p.addOnFilled) {
          _positions[p.id] = p.copyWith(clearAddOn: true);
        }
      }
    }
    _log(BotEvent.trade(
      '$symbol: ${trigger ? "条件付き注文" : "指値"} (注文ID $orderId) を取り消しました',
      symbol: symbol,
    ));
    final orders = await _fetchOpenOrders();
    if (orders != null) _openOrders = orders;
    _emitSnapshot();
  }

  /// ボットが管理していない建玉 (手で建てたもの) に、利確 / 損切りを置く。
  ///
  /// ボットの建玉は [updatePositionExit] で動かす (手元の記録も合わせるため)。
  Future<void> updateExchangePositionExit({
    required int positionId,
    double? takeProfitPrice,
    double? stopLossPrice,
  }) async {
    if (!_rest.hasCredentials) {
      throw StateError('サーバーに取引所の API キーが入っていないので、置けません。');
    }
    if (takeProfitPrice == null && stopLossPrice == null) {
      throw StateError('利確か損切りの値段を入れて下さい。');
    }
    final position = await _exchangePositionOf(positionId);
    final contract = await _contractFor(position.symbol);
    final isShort = position.isShort;
    final tp = takeProfitPrice == null
        ? null
        : contract.roundPrice(takeProfitPrice, roundUp: isShort);
    final sl = stopLossPrice == null
        ? null
        : contract.roundPrice(stopLossPrice, roundUp: !isShort);
    final entry = position.holdAvgPrice;
    if (entry > 0) {
      final side = isShort ? 'ショート' : 'ロング';
      if (tp != null && (isShort ? tp >= entry : tp <= entry)) {
        throw StateError('$sideの利確は建値 ($entry) より${isShort ? "下" : "上"}にして下さい。');
      }
      if (sl != null && (isShort ? sl <= entry : sl >= entry)) {
        throw StateError('$sideの損切りは建値 ($entry) より${isShort ? "上" : "下"}にして下さい。');
      }
    }
    await _rest.placePositionTpSl(
      positionId: positionId,
      vol: position.holdVol,
      takeProfitPrice: tp,
      stopLossPrice: sl,
    );
    _log(BotEvent.trade(
      '${position.symbol}: 手で建てた建玉に 利確 ${tp ?? "-"} / 損切り ${sl ?? "-"} を'
      '置きました (${position.holdVol} 枚)',
      symbol: position.symbol,
    ));
    _emitSnapshot();
  }

  /// ボットが管理していない建玉 (手で建てたもの) を成行で閉じる。
  Future<void> closeExchangePosition(int positionId) async {
    if (!_rest.hasCredentials) {
      throw StateError('サーバーに取引所の API キーが入っていないので、決済出来ません。');
    }
    final position = await _exchangePositionOf(positionId);
    final contract = await _contractFor(position.symbol);
    final lastPrice = await _lastPriceFor(position.symbol, refresh: true);
    final direction = TradeDirection.fromPositionType(position.positionType);
    await _rest.closePosition(
      symbol: position.symbol,
      price: contract.roundPrice(lastPrice, roundUp: direction.isShort),
      vol: position.holdVol,
      side: direction.closeSide,
      openType: position.openType,
      positionId: position.positionId,
      reduceOnly: true,
      positionMode: _config.positionModeValue,
    );
    _log(BotEvent.trade(
      '${position.symbol}: 手で建てた${direction.label}建玉 ${position.holdVol} 枚を'
      '成行で決済しました',
      symbol: position.symbol,
    ));
    await Future<void>.delayed(const Duration(seconds: 1));
    await _syncExchangeState(includeHistory: true);
    _emitSnapshot();
  }

  /// 保存してあった予約を戻す (サーバーの再起動時)。
  void restorePendingExits(Iterable<PendingExit> exits) {
    _pendingExits
      ..clear()
      ..addAll(exits);
    _ensureManualTimer();
  }

  void _pendingExitsChanged() {
    onPendingExitsChanged?.call(List.unmodifiable(_pendingExits));
    _ensureManualTimer();
  }

  /// 止めている間も、予約があれば取引所を見に行く (動いている間は判定の
  /// たびに見るので要らない)。予約が無くなったら止める。
  void _ensureManualTimer() {
    if (_pendingExits.isEmpty) {
      _manualTimer?.cancel();
      _manualTimer = null;
      return;
    }
    _manualTimer ??= Timer.periodic(manualSyncInterval, (_) async {
      if (_running || _cycleInFlight) return;
      await _syncExchangeState();
      _emitSnapshot();
    });
  }

  /// 条件付き注文が発動して建玉ができていたら、予約の利確 / 損切りを置く。
  Future<void> _applyPendingExits(
    List<PositionInfo> open,
    List<ExchangeOrder> orders,
  ) async {
    if (_pendingExits.isEmpty) return;
    final now = DateTime.now();
    final waitingPlans = {
      for (final o in orders)
        if (o.kind == ExchangeOrderKind.trigger) o.id,
    };
    var changed = false;
    for (final exit in _pendingExits.toList()) {
      if (waitingPlans.contains(exit.planOrderId)) {
        _planGoneAt.remove(exit.planOrderId);
        continue;
      }
      final goneAt = _planGoneAt.putIfAbsent(exit.planOrderId, () => now);
      final positions = open.where(
        (p) =>
            p.symbol == exit.symbol &&
            p.positionType == exit.direction.positionType,
      );
      final held = positions.fold<double>(0, (sum, p) => sum + p.holdVol);
      final position = positions.firstOrNull;
      if (position == null || held <= exit.baseVol * 1.0001) {
        // 発動して指値が板に残っている間は待つ。
        final limitWaiting = orders.any(
          (o) =>
              o.kind == ExchangeOrderKind.limit &&
              o.symbol == exit.symbol &&
              o.opens &&
              o.direction == exit.direction &&
              !o.fromBot,
        );
        if (limitWaiting) {
          _planGoneAt[exit.planOrderId] = now;
          continue;
        }
        if (now.difference(goneAt) > pendingExitGoneGrace) {
          _pendingExits.remove(exit);
          _planGoneAt.remove(exit.planOrderId);
          changed = true;
          _log(BotEvent.info(
            '${exit.symbol}: 条件付き注文 (注文ID ${exit.planOrderId}) が建たないまま'
            '消えたので、利確 / 損切りの予約をやめました (取り消し・期限切れなど)',
            symbol: exit.symbol,
          ));
        }
        continue;
      }
      try {
        await _rest.placePositionTpSl(
          positionId: position.positionId,
          vol: held,
          takeProfitPrice: exit.takeProfitPrice,
          stopLossPrice: exit.stopLossPrice,
        );
        _pendingExits.remove(exit);
        _planGoneAt.remove(exit.planOrderId);
        _pendingExitFailures.remove(exit.planOrderId);
        changed = true;
        _log(BotEvent.trade(
          '${exit.symbol}: 条件付き注文が建ったので、利確 ${exit.takeProfitPrice ?? "-"} / '
          '損切り ${exit.stopLossPrice ?? "-"} を $held 枚ぶん置きました',
          symbol: exit.symbol,
        ));
      } catch (e) {
        final failures = (_pendingExitFailures[exit.planOrderId] ?? 0) + 1;
        _pendingExitFailures[exit.planOrderId] = failures;
        if (failures >= 3) {
          _pendingExits.remove(exit);
          _planGoneAt.remove(exit.planOrderId);
          _pendingExitFailures.remove(exit.planOrderId);
          changed = true;
          _log(BotEvent.error(
            '${exit.symbol}: 条件付き注文で建った建玉に利確 / 損切りを置けませんでした ($e)。'
            '取引所の画面かアプリから置いて下さい。',
            symbol: exit.symbol,
          ));
        } else {
          _log(BotEvent.warning(
            '${exit.symbol}: 利確 / 損切りの予約を置けませんでした ($e)。次にもう一度試します。',
            symbol: exit.symbol,
          ));
        }
      }
    }
    if (changed) _pendingExitsChanged();
  }

  /// 指値と条件付き注文をまとめて取る。取れなければ null (前の一覧を使う)。
  Future<List<ExchangeOrder>?> _fetchOpenOrders() async {
    if (!_rest.hasCredentials) return null;
    try {
      final limits = await _rest.fetchOpenOrders();
      final plans = await _rest.fetchPlanOrders();
      _warnedOrderFetch = false;
      return [...limits, ...plans]
        ..sort((a, b) => b.createTime.compareTo(a.createTime));
    } catch (e) {
      if (!_warnedOrderFetch) {
        _warnedOrderFetch = true;
        _log(BotEvent.warning('出ている注文を取れませんでした: $e'));
      }
      return null;
    }
  }

  Future<ContractInfo> _contractFor(String symbol) async {
    var contract = _feed.contractOf(symbol);
    if (contract == null) {
      await _feed.refreshContracts();
      contract = _feed.contractOf(symbol);
    }
    if (contract == null) {
      throw StateError('$symbol は API で取引出来ない銘柄です。');
    }
    return contract;
  }

  Future<double> _lastPriceFor(String symbol, {required bool refresh}) async {
    if (refresh || _feed.tickerOf(symbol) == null) {
      await _feed.refreshTickers();
    }
    final price = _feed.tickerOf(symbol)?.lastPrice;
    if (price == null || price <= 0) {
      throw StateError('$symbol の現在値を取れませんでした。');
    }
    return price;
  }

  Future<void> _refreshAssetQuietly() async {
    try {
      final assets = await _rest.fetchAssets();
      _asset = assets.where((a) => a.currency == 'USDT').firstOrNull ??
          (assets.isEmpty ? null : assets.first);
    } catch (_) {
      // 取れなければ前の残高のまま。取引所も残高を超える注文は弾く。
    }
  }

  Future<PositionInfo> _exchangePositionOf(int positionId) async {
    bool same(PositionInfo p) => p.positionId == positionId;
    var position = (_exchangeOpen ?? const <PositionInfo>[])
        .where(same)
        .firstOrNull;
    if (position == null) {
      final list = await _rest.fetchOpenPositions();
      position = list.where(same).where((p) => p.holdVol > 0).firstOrNull;
    }
    if (position == null) {
      throw StateError('建玉 (ID $positionId) が見つかりません。もう決済されたかもしれません。');
    }
    return position;
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

    _feed.updateFundingsFromTickers();
    // ここで全銘柄ぶんを積むと、同じ枠を使う ticker の取得が後ろで
    // 待たされ、判定サイクルが丸ごと止まる。少しずつ集める。
    _feed.fillMissingFundingCycles();
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
    _manualTimer?.cancel();
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
