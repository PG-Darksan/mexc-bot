import 'package:mexc_core/mexc_core.dart';

/// 口座の残高・建玉・決済の記録を、端末から直接取りに行く。
///
/// ボット本体の REST クライアントは履歴の穴埋めなどで待ち行列が
/// 詰まりやすく、そこに残高の問い合わせを並べると画面が遅くなる。
/// 別のクライアントを持てば待ち行列も別になり、押した瞬間に取れる。
/// 端末に鍵があれば、サーバー接続のときも使う (サーバーが返すのは
/// ボットが建てた建玉だけなので、手で建てたものはこちらで拾う)。
class AccountDataSource {
  AccountDataSource({required String apiKey, required String apiSecret})
    : _rest = MexcRestClient(apiKey: apiKey, apiSecret: apiSecret);

  final MexcRestClient _rest;
  bool _timeSynced = false;
  Map<String, double>? _contractSizes;

  /// 署名にサーバー時刻を使うので、最初の一度だけ合わせておく。
  Future<void> _syncTimeOnce() async {
    if (_timeSynced) return;
    await _rest.syncTime();
    _timeSynced = true;
  }

  /// USDT の残高。無ければ先頭の通貨を返す。
  Future<AccountAsset?> fetchUsdt() async {
    await _syncTimeOnce();
    final assets = await _rest.fetchAssets();
    if (assets.isEmpty) return null;
    for (final a in assets) {
      if (a.currency == 'USDT') return a;
    }
    return assets.first;
  }

  /// 取引所にある建玉。ボットが建てたものも、手で建てたものも入る。
  Future<List<PositionInfo>> fetchOpenPositions() async {
    await _syncTimeOnce();
    final list = await _rest.fetchOpenPositions();
    return list.where((p) => p.isOpen && p.holdVol > 0).toList();
  }

  /// 決済済みの建玉。新しい順。
  Future<List<PositionInfo>> fetchClosedPositions({int count = 100}) async {
    await _syncTimeOnce();
    return _rest.fetchHistoryPositions(pageSize: count);
  }

  /// 全銘柄の現在値 (公開 API、1 回で全部返る)。
  Future<Map<String, double>> fetchLastPrices() async {
    final tickers = await _rest.fetchTickers();
    return {for (final t in tickers) t.symbol: t.lastPrice};
  }

  /// 銘柄ごとの 1 枚あたりの数量。評価損益の計算に使う。まず変わらないので
  /// 一度だけ取る。
  Future<Map<String, double>> contractSizes() async {
    final cached = _contractSizes;
    if (cached != null) return cached;
    final contracts = await _rest.fetchContracts();
    return _contractSizes = {
      for (final c in contracts) c.symbol: c.contractSize,
    };
  }

  void dispose() => _rest.close();
}
