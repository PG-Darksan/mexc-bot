import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/candle.dart';
import '../models/contract_info.dart';
import '../models/market_data.dart';
import '../models/position.dart';
import '../models/timeframe.dart';
import 'mexc_exception.dart';
import 'rate_limiter.dart';

/// 発注結果。
class OrderResult {
  OrderResult({required this.orderId, required this.timestamp});

  /// 19 桁になることがあるので必ず文字列で扱う。
  final String orderId;
  final int timestamp;
}

/// MEXC 先物 REST クライアント。
///
/// * 基底 URL は 2026-01 に `contract.mexc.com` から `api.mexc.com` へ移行済み。
/// * 署名は `HMAC-SHA256(secret, apiKey + requestTime + parameterString)`。
///   GET は辞書順に並べたクエリ文字列、POST は送信する JSON 文字列そのものを
///   parameterString に使う。POST は署名対象とボディを同じ文字列にすること。
class MexcRestClient {
  MexcRestClient({
    this.baseUrl = 'https://api.mexc.com',
    this.apiKey,
    this.apiSecret,
    http.Client? httpClient,
    this.recvWindowMs = 20000,
    this.timeout = const Duration(seconds: 15),
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final String? apiKey;
  final String? apiSecret;
  final http.Client _http;
  final int recvWindowMs;
  final Duration timeout;

  final RateLimiter _queryLimiter = RateLimiter.query();
  final RateLimiter _orderLimiter = RateLimiter.order();
  final RateLimiter _detailLimiter = RateLimiter.contractDetail();
  final RateLimiter _publicLimiter = RateLimiter.publicMarket();
  final RateLimiter _historyLimiter = RateLimiter.history();

  /// サーバー時刻との差 (ミリ秒)。端末時計がずれていると署名が弾かれる。
  int _timeOffsetMs = 0;

  /// オフセット測定後の経過は単調時計で測り、時計のジャンプに影響されないようにする。
  final Stopwatch _sinceSync = Stopwatch();
  int _syncedServerTimeMs = 0;

  bool get hasCredentials =>
      (apiKey?.isNotEmpty ?? false) && (apiSecret?.isNotEmpty ?? false);

  int get timeOffsetMs => _timeOffsetMs;

  void close() => _http.close();

  /// 現在のサーバー時刻 (ミリ秒) の推定値。
  int get nowMs {
    if (_sinceSync.isRunning) {
      return _syncedServerTimeMs + _sinceSync.elapsedMilliseconds;
    }
    return DateTime.now().millisecondsSinceEpoch + _timeOffsetMs;
  }

  /// サーバー時刻を取得してオフセットを補正する。起動時と定期的に呼ぶ。
  Future<void> syncTime() async {
    final before = DateTime.now().millisecondsSinceEpoch;
    final data = await _publicGet('/api/v1/contract/ping');
    final after = DateTime.now().millisecondsSinceEpoch;
    final serverMs = (data as num).toInt();
    // 往復の半分を足して片道遅延を補正する。
    final localMid = (before + after) ~/ 2;
    _timeOffsetMs = serverMs - localMid;
    _syncedServerTimeMs = serverMs + (after - before) ~/ 2;
    _sinceSync
      ..reset()
      ..start();
  }

  // ── 公開エンドポイント ──────────────────────────────────────

  /// 全銘柄の仕様。USDT 無期限かつ API 発注が許可されたものだけを返す。
  Future<List<ContractInfo>> fetchContracts({bool onlyTradable = true}) async {
    await _detailLimiter.acquire();
    final data = await _publicGet('/api/v1/contract/detail');
    final list = (data as List)
        .cast<Map<String, dynamic>>()
        .map(ContractInfo.fromJson)
        .where((c) => !onlyTradable || (c.isTradable && c.isPerpetualUsdt))
        .toList();
    return list;
  }

  /// 全銘柄のティッカー。1 リクエストで全部返るので毎分呼んでも軽い。
  Future<List<TickerSnapshot>> fetchTickers() async {
    await _publicLimiter.acquire();
    final data = await _publicGet('/api/v1/contract/ticker');
    return (data as List)
        .cast<Map<String, dynamic>>()
        .map(TickerSnapshot.fromJson)
        .toList();
  }

  /// ローソク足。[bars] 本ぶん遡って取得する。
  ///
  /// start / end は **秒**。ミリ秒を渡すと空配列が返るだけでエラーにならない。
  Future<List<Candle>> fetchKlines(
    String symbol,
    Timeframe timeframe, {
    int bars = 300,
  }) async {
    // 履歴は専用の枠で取る。判定サイクルが使う ticker を待たせないため。
    await _historyLimiter.acquire();
    final end = nowMs ~/ 1000;
    // 1 回の上限は 2000 本。
    final count = bars.clamp(1, 2000);
    final start = end - timeframe.seconds * (count + 1);
    final data = await _publicGet(
      '/api/v1/contract/kline/$symbol',
      query: {
        'interval': timeframe.interval,
        'start': '$start',
        'end': '$end',
      },
    );
    return _parseKline(data as Map<String, dynamic>);
  }

  List<Candle> _parseKline(Map<String, dynamic> data) {
    final times = (data['time'] as List?) ?? const [];
    final opens = (data['open'] as List?) ?? const [];
    final highs = (data['high'] as List?) ?? const [];
    final lows = (data['low'] as List?) ?? const [];
    final closes = (data['close'] as List?) ?? const [];
    final vols = (data['vol'] as List?) ?? const [];
    final amounts = (data['amount'] as List?) ?? const [];
    final n = times.length;
    final out = <Candle>[];
    for (var i = 0; i < n; i++) {
      out.add(
        Candle(
          openTime: (times[i] as num).toInt(),
          open: (opens[i] as num).toDouble(),
          high: (highs[i] as num).toDouble(),
          low: (lows[i] as num).toDouble(),
          close: (closes[i] as num).toDouble(),
          volume: i < vols.length ? (vols[i] as num).toDouble() : 0,
          amount: i < amounts.length ? (amounts[i] as num).toDouble() : 0,
        ),
      );
    }
    return out;
  }

  /// 資金調達率と調達間隔。collectCycle は銘柄ごとに 8/4/1 時間と異なる。
  Future<FundingInfo> fetchFundingRate(String symbol) async {
    await _publicLimiter.acquire();
    final data = await _publicGet('/api/v1/contract/funding_rate/$symbol');
    return FundingInfo.fromJson(
      data as Map<String, dynamic>,
      fetchedAt: DateTime.now(),
    );
  }

  // ── プライベートエンドポイント ──────────────────────────────

  /// 先物口座の残高一覧。
  Future<List<AccountAsset>> fetchAssets() async {
    await _queryLimiter.acquire();
    final data = await _privateGet('/api/v1/private/account/assets');
    return (data as List)
        .cast<Map<String, dynamic>>()
        .map(AccountAsset.fromJson)
        .toList();
  }

  /// 保有中の建玉。
  Future<List<PositionInfo>> fetchOpenPositions({String? symbol}) async {
    await _queryLimiter.acquire();
    final data = await _privateGet(
      '/api/v1/private/position/open_positions',
      query: {if (symbol != null) 'symbol': symbol},
    );
    if (data == null) return const [];
    return (data as List)
        .cast<Map<String, dynamic>>()
        .map(PositionInfo.fromJson)
        .toList();
  }

  /// 建玉モード (1=ヘッジ / 2=一方向)。
  Future<int> fetchPositionMode() async {
    await _queryLimiter.acquire();
    final data = await _privateGet('/api/v1/private/position/position_mode');
    if (data is Map<String, dynamic>) {
      return (data['positionMode'] as num?)?.toInt() ?? 1;
    }
    return (data as num?)?.toInt() ?? 1;
  }

  /// レバレッジ変更。
  ///
  /// 建玉が無いときは [positionId] ではなく
  /// leverage + openType + symbol + positionType の 4 点をすべて渡す必要がある。
  Future<void> changeLeverage({
    required int leverage,
    int? positionId,
    int? openType,
    String? symbol,
    int? positionType,
  }) async {
    await _orderLimiter.acquire();
    await _privatePost('/api/v1/private/position/change_leverage', {
      'leverage': leverage,
      if (positionId != null) 'positionId': positionId,
      if (openType != null) 'openType': openType,
      if (symbol != null) 'symbol': symbol,
      if (positionType != null) 'positionType': positionType,
    });
  }

  /// 新規注文。
  ///
  /// side: 1=買い新規 / 2=売り決済 / 3=売り新規 / 4=買い決済。
  /// type: 1=指値 / 2=Post Only / 3=IOC / 4=FOK / 5=成行。
  /// openType: 1=分離 / 2=クロス。
  Future<OrderResult> createOrder({
    required String symbol,
    required double price,
    required double vol,
    required int side,
    required int type,
    required int openType,
    int? leverage,
    int? positionId,
    double? takeProfitPrice,
    double? stopLossPrice,
    int? positionMode,
    String? externalOid,
    bool? reduceOnly,
  }) async {
    await _orderLimiter.acquire();
    final body = <String, dynamic>{
      'symbol': symbol,
      'price': price,
      'vol': vol,
      'side': side,
      'type': type,
      'openType': openType,
      if (leverage != null) 'leverage': leverage,
      if (positionId != null) 'positionId': positionId,
      if (takeProfitPrice != null) 'takeProfitPrice': takeProfitPrice,
      if (stopLossPrice != null) 'stopLossPrice': stopLossPrice,
      if (positionMode != null) 'positionMode': positionMode,
      if (externalOid != null) 'externalOid': externalOid,
      if (reduceOnly != null) 'reduceOnly': reduceOnly,
    };
    final data = await _privatePost('/api/v1/private/order/create', body);
    if (data is Map<String, dynamic>) {
      return OrderResult(
        orderId: '${data['orderId']}',
        timestamp: (data['ts'] as num?)?.toInt() ?? nowMs,
      );
    }
    // 古い仕様では data が注文 ID 単体だった。
    return OrderResult(orderId: '$data', timestamp: nowMs);
  }

  /// 既存ポジションに利確 / 損切りを設定する。
  Future<void> placePositionTpSl({
    required int positionId,
    required double vol,
    double? takeProfitPrice,
    double? stopLossPrice,
    int lossTrend = 1,
    int profitTrend = 1,
  }) async {
    if (takeProfitPrice == null && stopLossPrice == null) return;
    await _orderLimiter.acquire();
    await _privatePost('/api/v1/private/stoporder/place', {
      'positionId': positionId,
      'vol': vol,
      'lossTrend': lossTrend,
      'profitTrend': profitTrend,
      if (takeProfitPrice != null) 'takeProfitPrice': takeProfitPrice,
      if (stopLossPrice != null) 'stopLossPrice': stopLossPrice,
    });
  }

  /// 注文の取消。
  Future<void> cancelOrders(List<String> orderIds) async {
    if (orderIds.isEmpty) return;
    await _orderLimiter.acquire();
    await _privatePostRaw('/api/v1/private/order/cancel', orderIds);
  }

  /// 指定ポジションを成行で全決済する。
  ///
  /// ヘッジモードでは side に決済方向 (ショートなら 2) と positionId を渡す。
  Future<OrderResult> closePosition({
    required String symbol,
    required double price,
    required double vol,
    required int side,
    required int openType,
    int? positionId,
    bool? reduceOnly,
    int? positionMode,
  }) => createOrder(
    symbol: symbol,
    price: price,
    vol: vol,
    side: side,
    type: 5,
    openType: openType,
    positionId: positionId,
    reduceOnly: reduceOnly,
    positionMode: positionMode,
  );

  // ── 内部実装 ────────────────────────────────────────────────

  Future<dynamic> _publicGet(
    String path, {
    Map<String, String> query = const {},
  }) async {
    final uri = Uri.parse(
      '$baseUrl$path',
    ).replace(queryParameters: query.isEmpty ? null : query);
    return _send(() => _http.get(uri), path);
  }

  Future<dynamic> _privateGet(
    String path, {
    Map<String, String> query = const {},
  }) async {
    _requireCredentials();
    final sorted = Map<String, String>.fromEntries(
      query.entries.where((e) => e.value.isNotEmpty).toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    );
    final paramString = sorted.entries
        .map((e) => '${e.key}=${e.value}')
        .join('&');
    final headers = _signedHeaders(paramString);
    final uri = Uri.parse(
      '$baseUrl$path',
    ).replace(queryParameters: sorted.isEmpty ? null : sorted);
    return _send(() => _http.get(uri, headers: headers), path);
  }

  Future<dynamic> _privatePost(String path, Map<String, dynamic> body) =>
      _privatePostRaw(path, body);

  /// POST は「署名した文字列」と「送るボディ」を完全に同一にする必要がある。
  /// 再シリアライズするとキー順や空白が変わって 602 になる。
  Future<dynamic> _privatePostRaw(String path, Object body) async {
    _requireCredentials();
    final payload = jsonEncode(body);
    final headers = _signedHeaders(payload);
    final uri = Uri.parse('$baseUrl$path');
    return _send(
      () => _http.post(uri, headers: headers, body: payload),
      path,
    );
  }

  void _requireCredentials() {
    if (!hasCredentials) {
      throw MexcApiException(
        code: 511,
        message: 'APIキーが設定されていません。',
      );
    }
  }

  Map<String, String> _signedHeaders(String paramString) {
    final requestTime = '$nowMs';
    final target = '$apiKey$requestTime$paramString';
    final mac = Hmac(sha256, utf8.encode(apiSecret!));
    final signature = mac.convert(utf8.encode(target)).toString();
    return {
      'ApiKey': apiKey!,
      'Request-Time': requestTime,
      'Signature': signature,
      'Content-Type': 'application/json',
      'Recv-Window': '$recvWindowMs',
    };
  }

  Future<dynamic> _send(
    Future<http.Response> Function() request,
    String endpoint, {
    int attempt = 0,
  }) async {
    http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        return _send(request, endpoint, attempt: attempt + 1);
      }
      throw MexcNetworkException('タイムアウトしました。', endpoint: endpoint);
    } catch (e) {
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        return _send(request, endpoint, attempt: attempt + 1);
      }
      throw MexcNetworkException('$e', endpoint: endpoint);
    }

    if (response.statusCode == 429) {
      if (attempt < 3) {
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
        return _send(request, endpoint, attempt: attempt + 1);
      }
      throw MexcApiException(
        code: 510,
        message: 'レート制限 (HTTP 429)',
        endpoint: endpoint,
        httpStatus: 429,
      );
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw MexcNetworkException(
        'レスポンスを解析できません (HTTP ${response.statusCode})',
        endpoint: endpoint,
      );
    }

    final success = json['success'] == true;
    final code = (json['code'] as num?)?.toInt() ?? -1;
    if (!success || code != 0) {
      final error = MexcApiException(
        code: code,
        message: '${json['message'] ?? json['msg'] ?? '不明なエラー'}',
        endpoint: endpoint,
        httpStatus: response.statusCode,
      );
      if (error.isRetryable && attempt < 4) {
        // レート超過は間を広めに取る。詰めて叩き直すと状況が悪化する。
        final backoff = error.isRateLimited
            ? Duration(seconds: 2 << attempt)
            : Duration(seconds: 1 << attempt);
        await Future<void>.delayed(backoff);
        return _send(request, endpoint, attempt: attempt + 1);
      }
      throw error;
    }
    return json['data'];
  }
}
