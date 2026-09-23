import 'dart:async';

import '../api/mexc_rest_client.dart';
import '../api/mexc_ws_client.dart';
import '../indicators/candle_series.dart';
import '../models/contract_info.dart';
import '../models/market_data.dart';
import '../models/timeframe.dart';

/// 相場データの取得と保持をまとめた層。
///
/// * 銘柄仕様と 24h 売買代金は REST でまとめて取る (ticker は全銘柄 1 リクエスト)。
/// * ローソク足は起動時に REST で履歴を埋め、その後は WebSocket の push で更新する。
/// * 出来高ゼロの銘柄には push が来ないので、ticker の最新値で進行中の足を進める。
class MarketDataFeed {
  MarketDataFeed({
    required MexcRestClient rest,
    required MexcWsClient ws,
    this.onLog,
  }) : _rest = rest,
       _ws = ws {
    _klineSub = _ws.klines.listen(_onKline);
  }

  final MexcRestClient _rest;
  final MexcWsClient _ws;
  final void Function(String message)? onLog;

  StreamSubscription<KlineUpdate>? _klineSub;

  final Map<String, ContractInfo> _contracts = {};
  final Map<String, TickerSnapshot> _tickers = {};
  final Map<String, FundingInfo> _fundings = {};
  final Map<String, CandleSeries> _series = {};

  /// 履歴の読み込みが終わった系列。二重取得を避ける。
  final Set<String> _loaded = {};
  final Set<String> _loading = {};

  /// 銘柄ごとの資金調達の間隔 (時間)。ほとんど変わらないので長くキャッシュする。
  final Map<String, int> _fundingCycles = {};
  final Set<String> _cycleLoading = {};

  /// いま監視している対象。取りこぼした履歴を後から埋めるのに使う。
  List<String> _watchedSymbols = const [];
  List<Timeframe> _watchedTimeframes = const [];
  int _historyBars = 300;

  Map<String, ContractInfo> get contracts => Map.unmodifiable(_contracts);
  Map<String, TickerSnapshot> get tickers => Map.unmodifiable(_tickers);
  Map<String, FundingInfo> get fundings => Map.unmodifiable(_fundings);

  bool get wsConnected => _ws.isConnected;
  int get subscriptionCount => _ws.subscriptionCount;
  int get loadedSeriesCount => _loaded.length;
  int get pendingSeriesCount => _loading.length;

  static String keyOf(String symbol, Timeframe tf) => '$symbol|${tf.interval}';

  ContractInfo? contractOf(String symbol) => _contracts[symbol];
  TickerSnapshot? tickerOf(String symbol) => _tickers[symbol];
  FundingInfo? fundingOf(String symbol) => _fundings[symbol];
  CandleSeries? seriesOf(String symbol, Timeframe tf) =>
      _series[keyOf(symbol, tf)];

  /// 銘柄仕様を取り直す。数分おきで十分。
  Future<void> refreshContracts() async {
    final list = await _rest.fetchContracts();
    _contracts
      ..clear()
      ..addEntries(list.map((c) => MapEntry(c.symbol, c)));
    onLog?.call('銘柄仕様を更新: ${_contracts.length} 件 (USDT無期限・API発注可)');
  }

  /// 全銘柄のティッカーを 1 リクエストで取る。
  Future<void> refreshTickers() async {
    final list = await _rest.fetchTickers();
    for (final t in list) {
      _tickers[t.symbol] = t;
    }
  }

  /// ティッカーに入っている資金調達率で、監視中の銘柄の情報を更新する。
  ///
  /// 資金調達率は ticker に含まれているので、全銘柄ぶんを 1 リクエストで賄える。
  /// 一方、調達の間隔 (8時間 / 4時間 / 1時間) は ticker に無いので
  /// [fillMissingFundingCycles] で別に集め、ここではキャッシュを使う。
  /// 間隔がまだ分からない銘柄は情報を作らない (判定側で「未取得」として見送られる)。
  void updateFundingsFromTickers() {
    final now = DateTime.now();
    for (final ticker in _tickers.values) {
      final cycle = _fundingCycles[ticker.symbol];
      if (cycle == null) continue;
      _fundings[ticker.symbol] = FundingInfo(
        symbol: ticker.symbol,
        fundingRate: ticker.fundingRate,
        collectCycleHours: cycle,
        nextSettleTime: 0,
        fetchedAt: now,
      );
    }
  }

  /// 調達間隔をまだ知らない銘柄を少しずつ取得する。
  ///
  /// 1 銘柄 1 リクエストと重いが、値がほぼ変わらないので一度取れば使い回せる。
  void fillMissingFundingCycles({int maxPerCall = 20}) {
    var queued = 0;
    for (final symbol in _watchedSymbols) {
      if (queued >= maxPerCall) return;
      if (_fundingCycles.containsKey(symbol)) continue;
      if (_cycleLoading.contains(symbol)) continue;
      _cycleLoading.add(symbol);
      queued++;
      unawaited(_loadFundingCycle(symbol));
    }
  }

  Future<void> _loadFundingCycle(String symbol) async {
    try {
      final info = await _rest.fetchFundingRate(symbol);
      _fundingCycles[symbol] = info.collectCycleHours;
      _fundings[symbol] = info;
    } catch (e) {
      // 取れなければ次のサイクルでまた試す。
      onLog?.call('$symbol の資金調達の間隔を取得できません (後で再取得します): $e');
    } finally {
      _cycleLoading.remove(symbol);
    }
  }

  /// 調達間隔のキャッシュを捨てて取り直させる。1日1回程度で十分。
  void invalidateFundingCycles() => _fundingCycles.clear();

  /// 調達間隔がまだ分からない監視銘柄の数。
  int get pendingFundingCycleCount =>
      _watchedSymbols.where((s) => !_fundingCycles.containsKey(s)).length;

  /// 監視対象を差し替える。足りない履歴は裏で読み込む。
  Future<void> setWatchlist(
    List<String> symbols,
    List<Timeframe> timeframes, {
    required int historyBars,
  }) async {
    final wanted = <String>{};
    final subs = <KlineSubscription>{};
    for (final symbol in symbols) {
      for (final tf in timeframes) {
        wanted.add(keyOf(symbol, tf));
        subs.add(KlineSubscription(symbol, tf));
      }
    }

    // 対象から外れた系列は捨てる。
    _series.removeWhere((key, _) {
      if (wanted.contains(key)) return false;
      _loaded.remove(key);
      return true;
    });

    await _ws.setSubscriptions(subs);

    _watchedSymbols = symbols;
    _watchedTimeframes = timeframes;
    _historyBars = historyBars;

    // 監視対象が変わった直後は全部まとめて積む。
    // レートリミッタが順番待ちをさせるので、積みすぎても叩きすぎにはならない。
    fillMissingHistory(maxPerCall: subs.length);
  }

  /// まだ履歴を持っていない系列を埋める。
  ///
  /// 起動直後はレート制限に当たって取りこぼすことがあるので、
  /// 判定サイクルのたびに呼んで少しずつ補う。
  void fillMissingHistory({int maxPerCall = 40}) {
    var queued = 0;
    for (final symbol in _watchedSymbols) {
      for (final tf in _watchedTimeframes) {
        if (queued >= maxPerCall) return;
        final key = keyOf(symbol, tf);
        if (_loaded.contains(key) || _loading.contains(key)) continue;
        _loading.add(key);
        queued++;
        unawaited(_loadHistory(symbol, tf, _historyBars));
      }
    }
  }

  /// 履歴がまだ揃っていない系列の数。
  int get missingSeriesCount {
    var missing = 0;
    for (final symbol in _watchedSymbols) {
      for (final tf in _watchedTimeframes) {
        if (!_loaded.contains(keyOf(symbol, tf))) missing++;
      }
    }
    return missing;
  }

  Future<void> _loadHistory(String symbol, Timeframe tf, int bars) async {
    final key = keyOf(symbol, tf);
    try {
      final candles = await _rest.fetchKlines(symbol, tf, bars: bars);
      if (candles.isEmpty) {
        onLog?.call('$symbol ${tf.label}: 履歴が空でした');
      } else {
        final series = _series.putIfAbsent(
          key,
          () => CandleSeries(
            symbol: symbol,
            timeframe: tf,
            maxBars: bars + 50,
          ),
        );
        series.replaceAll(candles);
        series.lastUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        _loaded.add(key);
      }
    } catch (e) {
      // ここで _loaded に入れないので、次のサイクルで自動的に再取得される。
      onLog?.call('$symbol ${tf.label} の履歴取得に失敗 (後で再取得します): $e');
    } finally {
      _loading.remove(key);
    }
  }

  void _onKline(KlineUpdate update) {
    final key = keyOf(update.symbol, update.timeframe);
    final series = _series[key];
    // 履歴を読む前に push が来ることがある。履歴で上書きされるので捨ててよい。
    if (series == null) return;
    series.upsert(update.candle);
    series.lastUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  /// ticker の最新値で進行中の足を進める。
  ///
  /// 無取引の銘柄では WebSocket の push が来ないため、これが無いと
  /// 足が止まったまま古い値で判定してしまう。
  void applyTickerPrices(List<Timeframe> timeframes) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final entry in _tickers.entries) {
      final price = entry.value.lastPrice;
      if (price <= 0) continue;
      for (final tf in timeframes) {
        final series = _series[keyOf(entry.key, tf)];
        if (series == null || series.isEmpty) continue;
        series.applyPrice(price, nowSec);
      }
    }
  }

  Future<void> dispose() async {
    await _klineSub?.cancel();
  }
}
