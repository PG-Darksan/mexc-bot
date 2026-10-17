import '../models/signal.dart';

/// 一度検知したシグナルを、その足が確定するまで覚えておく。
///
/// 判定は進行中の足で何度も (既定 10 秒ごとに) 行うので、条件を満たした
/// ままの間は毎回検知してしまう。注文を出せなかったとき (保有中・上限・
/// 残高不足など) も含めて、同じ手法・銘柄・時間軸・向きの検知は 1 本の
/// 足につき 1 回にする。
class SignalLatch {
  /// 手法・銘柄・時間軸・向きごとの、検知した足の開始時刻と確定する時刻
  /// (どちらも UNIX 秒)。
  final Map<String, ({int barOpenTime, int closesAt})> _detected = {};

  static String _key(SignalEvaluation e) =>
      '${e.strategy.name}|${e.symbol}|${e.timeframe.name}|${e.direction.name}';

  /// [evaluation] と同じ足で、すでに検知しているか。
  bool isLatched(SignalEvaluation evaluation) =>
      _detected[_key(evaluation)]?.barOpenTime == evaluation.barOpenTime;

  /// [evaluation] の足で検知したと覚える。
  void latch(SignalEvaluation evaluation) {
    _detected[_key(evaluation)] = (
      barOpenTime: evaluation.barOpenTime,
      closesAt: evaluation.barOpenTime + evaluation.timeframe.seconds,
    );
  }

  /// 確定してから [keep] たった足の覚えを捨てる ([nowSeconds] は UNIX 秒)。
  ///
  /// 次の足で検知すれば上書きされるので、捨てるのは覚えが溜まらないため
  /// だけ。足の切り替わりが遅れても二重に検知しないよう、少し長めに持つ。
  void prune(int nowSeconds, {Duration keep = const Duration(hours: 1)}) {
    _detected.removeWhere(
      (_, bar) => bar.closesAt + keep.inSeconds <= nowSeconds,
    );
  }

  /// 覚えている数 (テスト用)。
  int get length => _detected.length;
}
