import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mexc_core/mexc_core.dart';

/// 恐怖指数 (Crypto Fear & Greed Index) の 1 点。
class FearGreedPoint {
  const FearGreedPoint({
    required this.time,
    required this.value,
    required this.label,
  });

  final DateTime time;

  /// 0 (極度の恐怖) 〜 100 (極度の強欲)。
  final int value;

  /// 英語の区分をそのまま持つ (Extreme Fear など)。
  final String label;

  /// 区分の日本語名。
  String get japaneseLabel => switch (value) {
    < 25 => '極度の恐怖',
    < 45 => '恐怖',
    < 55 => '中立',
    < 75 => '強欲',
    _ => '極度の強欲',
  };
}

/// 画面に絵を描くための材料を、端末が自分で集める。
///
/// 売買そのものはサーバー (またはローカルのエンジン) の仕事で、
/// チャートの表示にサーバーは通さない。どちらも公開APIなので鍵は要らない。
class ChartDataSource {
  ChartDataSource({MexcRestClient? rest, http.Client? client})
    : _rest = rest ?? MexcRestClient(),
      _client = client ?? http.Client();

  final MexcRestClient _rest;
  final http.Client _client;

  static const String fearGreedEndpoint = 'https://api.alternative.me/fng/';

  /// ローソク足を取る。MEXC の公開 API なので鍵は要らない。
  Future<List<Candle>> klines(
    String symbol,
    Timeframe timeframe, {
    int bars = 800,
  }) => _rest.fetchKlines(symbol, timeframe, bars: bars);

  /// 取引できる USDT 無期限の全銘柄の、いまの値段と 24 時間の動き。
  ///
  /// 銘柄一覧の並べ替えに使う。ticker は 1 リクエストで全部返る。
  Future<List<TickerSnapshot>> tickers() async {
    final results = await Future.wait([
      _rest.fetchContracts(),
      _rest.fetchTickers(),
    ]);
    final contracts = results[0] as List<ContractInfo>;
    final tickers = results[1] as List<TickerSnapshot>;
    final tradable = {
      for (final c in contracts)
        if (c.isPerpetualUsdt && c.isTradable) c.symbol,
    };
    return tickers.where((t) => tradable.contains(t.symbol)).toList();
  }

  /// 取引できる USDT 無期限の銘柄を、名前順で返す。検索に使う。
  Future<List<String>> symbols() async {
    final contracts = await _rest.fetchContracts();
    final names = contracts
        .where((c) => c.isPerpetualUsdt && c.isTradable)
        .map((c) => c.symbol)
        .toList();
    names.sort();
    return names;
  }

  /// 恐怖指数を新しい順から取り、古い順に並べ替えて返す。
  Future<List<FearGreedPoint>> fearGreed({int days = 60}) async {
    final uri = Uri.parse('$fearGreedEndpoint?limit=$days&format=json');
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw StateError('恐怖指数を取れませんでした (HTTP ${response.statusCode})');
    }
    final json = jsonDecode(response.body);
    final list = (json is Map ? json['data'] : null) as List?;
    if (list == null) return const [];

    final points = <FearGreedPoint>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final value = int.tryParse('${raw['value']}');
      final seconds = int.tryParse('${raw['timestamp']}');
      if (value == null || seconds == null) continue;
      points.add(
        FearGreedPoint(
          time: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
          value: value,
          label: '${raw['value_classification'] ?? ''}',
        ),
      );
    }
    // API は新しい順に返すので、古い順に直す。
    points.sort((a, b) => a.time.compareTo(b.time));
    return points;
  }

  void dispose() {
    _rest.close();
    _client.close();
  }
}
