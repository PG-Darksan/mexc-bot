/// 監視する時間軸。
///
/// [interval] は MEXC の kline API / WebSocket が受け付ける文字列。
/// [seconds] は 1 本あたりの秒数で、足の境界計算に使う。
enum Timeframe {
  m1('Min1', 60, '1分足'),
  m5('Min5', 300, '5分足'),
  m15('Min15', 900, '15分足'),
  m30('Min30', 1800, '30分足'),
  h1('Min60', 3600, '1時間足'),
  h4('Hour4', 14400, '4時間足'),
  h8('Hour8', 28800, '8時間足'),
  d1('Day1', 86400, '日足'),
  w1('Week1', 604800, '週足');

  const Timeframe(this.interval, this.seconds, this.label);

  /// MEXC API に渡す interval 文字列 (Min15 / Hour4 など)。
  final String interval;

  /// 1 本あたりの秒数。
  final int seconds;

  /// 画面表示用の日本語名。
  final String label;

  static Timeframe? fromInterval(String value) {
    for (final tf in Timeframe.values) {
      if (tf.interval == value) return tf;
    }
    return null;
  }

  static Timeframe? fromName(String value) {
    for (final tf in Timeframe.values) {
      if (tf.name == value) return tf;
    }
    return null;
  }

  /// 指定時刻 (UNIX 秒) が属する足の開始時刻を返す。
  ///
  /// 週足だけは UNIX エポック (木曜) 起点ではなく月曜起点に合わせる。
  int bucketStart(int epochSeconds) {
    if (this == Timeframe.w1) {
      // 1970-01-05(月) を起点にする。
      const mondayEpoch = 345600;
      final delta = epochSeconds - mondayEpoch;
      return mondayEpoch + (delta ~/ seconds) * seconds;
    }
    return (epochSeconds ~/ seconds) * seconds;
  }
}
