import 'dart:async';
import 'dart:collection';

/// 「N 回 / T 秒」形式のレート制限を守るための単純なスライディングウィンドウ。
///
/// MEXC の先物 API はエンドポイントごとに上限が違う
/// (発注は 4回/2秒、照会系は 20回/2秒 など) ので、用途ごとに 1 つ作る。
class RateLimiter {
  RateLimiter({required this.maxCalls, required this.window});

  /// 発注系 (order/create など)。
  factory RateLimiter.order() =>
      RateLimiter(maxCalls: 4, window: const Duration(seconds: 2));

  /// 認証つきの照会系 (position/open_positions, account/assets)。
  factory RateLimiter.query() =>
      RateLimiter(maxCalls: 20, window: const Duration(seconds: 2));

  /// 公開エンドポイントのうち、判定サイクルが毎回使うもの (ticker, funding_rate)。
  ///
  /// 公式には 20回/2秒 だが、実測では 510 (レート超過) が返る。IP 単位で
  /// 公開系が合算されているとみて、[history] と合わせて 8回/2秒 に収めている。
  factory RateLimiter.publicMarket() =>
      RateLimiter(maxCalls: 5, window: const Duration(seconds: 2));

  /// ローソク足の履歴取得。
  ///
  /// [publicMarket] と枠を分けているのは、起動時に数千本の履歴を積むと
  /// 同じキューに並んだ ticker 取得が後ろで延々と待たされ、判定サイクルが
  /// 丸ごと止まってしまうため。履歴は遅れて揃えばよいので、こちらを細くする。
  factory RateLimiter.history() =>
      RateLimiter(maxCalls: 3, window: const Duration(seconds: 2));

  /// 銘柄一覧 (contract/detail)。
  factory RateLimiter.contractDetail() =>
      RateLimiter(maxCalls: 10, window: const Duration(seconds: 2));

  final int maxCalls;
  final Duration window;

  final Queue<DateTime> _hits = Queue<DateTime>();
  Future<void> _tail = Future<void>.value();

  /// 枠が空くまで待ってから呼び出し権を返す。
  ///
  /// 呼び出しを直列化しているので、並行して呼んでも順番に消化される。
  Future<void> acquire() {
    final completer = Completer<void>();
    _tail = _tail.then((_) async {
      await _waitForSlot();
      _hits.add(DateTime.now());
      completer.complete();
    });
    return completer.future;
  }

  Future<void> _waitForSlot() async {
    while (true) {
      final now = DateTime.now();
      while (_hits.isNotEmpty && now.difference(_hits.first) >= window) {
        _hits.removeFirst();
      }
      if (_hits.length < maxCalls) return;
      final wait = window - now.difference(_hits.first);
      await Future<void>.delayed(
        wait.isNegative ? const Duration(milliseconds: 1) : wait,
      );
    }
  }
}
