import 'package:flutter/painting.dart';

/// チャートに自分で引いた線の種類。
enum DrawingKind {
  /// 値段 1 つの横線。
  horizontal,

  /// 2 点を結ぶ線 (トレンドライン)。先は右へ伸ばす。
  trend,
}

/// チャートに自分で引いた線 1 本。
///
/// 時刻はローソク足の始まり (エポック秒) で持つので、時間足を変えても
/// 同じ所に引かれる。
class ChartDrawing {
  const ChartDrawing({
    required this.id,
    required this.kind,
    required this.price1,
    this.time1,
    this.price2,
    this.time2,
    this.color = defaultColor,
  });

  /// 横線を引く。
  factory ChartDrawing.horizontal(double price, {Color color = defaultColor}) =>
      ChartDrawing(
        id: _newId(),
        kind: DrawingKind.horizontal,
        price1: price,
        color: color,
      );

  /// 2 点を結ぶ線を引く。古い方を 1 点目にする。
  factory ChartDrawing.trend({
    required int timeA,
    required double priceA,
    required int timeB,
    required double priceB,
    Color color = defaultColor,
  }) {
    final swap = timeB < timeA;
    return ChartDrawing(
      id: _newId(),
      kind: DrawingKind.trend,
      time1: swap ? timeB : timeA,
      price1: swap ? priceB : priceA,
      time2: swap ? timeA : timeB,
      price2: swap ? priceA : priceB,
      color: color,
    );
  }

  static const Color defaultColor = Color(0xFFFFB300);

  /// 選べる色。
  static const List<Color> palette = [
    Color(0xFFFFB300),
    Color(0xFF42A5F5),
    Color(0xFFAB47BC),
    Color(0xFF66BB6A),
    Color(0xFFEF5350),
    Color(0xFF9E9E9E),
  ];

  static int _serial = 0;
  static String _newId() =>
      'd${DateTime.now().microsecondsSinceEpoch}${_serial++}';

  final String id;
  final DrawingKind kind;
  final double price1;
  final int? time1;
  final double? price2;
  final int? time2;
  final Color color;

  /// 時刻 [time] (エポック秒) での線の値段。横線はいつも同じ値段。
  double priceAt(int time) {
    if (kind == DrawingKind.horizontal) return price1;
    final t1 = time1!;
    final t2 = time2!;
    if (t2 == t1) return price1;
    return price1 + (price2! - price1) * (time - t1) / (t2 - t1);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'price1': price1,
    if (time1 != null) 'time1': time1,
    if (price2 != null) 'price2': price2,
    if (time2 != null) 'time2': time2,
    'color': color.toARGB32(),
  };

  static ChartDrawing? fromJson(Map<String, dynamic> json) {
    final kind = DrawingKind.values.where((e) => e.name == json['kind']);
    final price1 = (json['price1'] as num?)?.toDouble();
    if (kind.isEmpty || price1 == null) return null;
    final drawing = ChartDrawing(
      id: json['id'] as String? ?? _newId(),
      kind: kind.first,
      price1: price1,
      time1: (json['time1'] as num?)?.toInt(),
      price2: (json['price2'] as num?)?.toDouble(),
      time2: (json['time2'] as num?)?.toInt(),
      color: Color((json['color'] as num?)?.toInt() ?? defaultColor.toARGB32()),
    );
    if (drawing.kind == DrawingKind.trend &&
        (drawing.time1 == null ||
            drawing.time2 == null ||
            drawing.price2 == null)) {
      return null;
    }
    return drawing;
  }
}
