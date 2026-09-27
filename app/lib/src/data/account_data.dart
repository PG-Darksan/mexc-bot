import 'package:mexc_core/mexc_core.dart';

/// 口座の残高だけを、端末から直接取りに行く。
///
/// ボット本体の REST クライアントは履歴の穴埋めなどで待ち行列が
/// 詰まりやすく、そこに残高の問い合わせを並べると画面が遅くなる。
/// 別のクライアントを持てば待ち行列も別になり、押した瞬間に取れる。
/// 鍵が端末にあるローカル実行のときだけ使える。
class AccountDataSource {
  AccountDataSource({required String apiKey, required String apiSecret})
    : _rest = MexcRestClient(apiKey: apiKey, apiSecret: apiSecret);

  final MexcRestClient _rest;
  bool _timeSynced = false;

  /// USDT の残高。無ければ先頭の通貨を返す。
  Future<AccountAsset?> fetchUsdt() async {
    // 署名にサーバー時刻を使うので、最初の一度だけ合わせておく。
    if (!_timeSynced) {
      await _rest.syncTime();
      _timeSynced = true;
    }
    final assets = await _rest.fetchAssets();
    if (assets.isEmpty) return null;
    for (final a in assets) {
      if (a.currency == 'USDT') return a;
    }
    return assets.first;
  }

  void dispose() => _rest.close();
}
