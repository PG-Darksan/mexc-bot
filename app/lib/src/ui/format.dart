import 'package:intl/intl.dart';

final _time = DateFormat('MM/dd HH:mm:ss');
final _timeShort = DateFormat('HH:mm:ss');

String formatTime(DateTime? value) =>
    value == null ? '-' : _time.format(value.toLocal());

String formatTimeShort(DateTime? value) =>
    value == null ? '-' : _timeShort.format(value.toLocal());

/// 1,234,567 → 123.4万 のように読みやすくする。
String formatUsdtCompact(double value) {
  if (value >= 1e9) return '${(value / 1e9).toStringAsFixed(2)}B';
  if (value >= 1e6) return '${(value / 1e6).toStringAsFixed(1)}M';
  if (value >= 1e3) return '${(value / 1e3).toStringAsFixed(1)}K';
  return value.toStringAsFixed(2);
}

/// 価格は桁数がまちまちなので、大きさに応じて有効桁を変える。
String formatPrice(double? value) {
  if (value == null) return '-';
  final abs = value.abs();
  if (abs >= 1000) return value.toStringAsFixed(2);
  if (abs >= 1) return value.toStringAsFixed(4);
  if (abs >= 0.01) return value.toStringAsFixed(6);
  return value.toStringAsExponential(4);
}

String formatPercent(double? value, {int digits = 2}) =>
    value == null ? '-' : '${value.toStringAsFixed(digits)}%';

String formatSignedPercent(double? value, {int digits = 2}) {
  if (value == null) return '-';
  final sign = value > 0 ? '+' : '';
  return '$sign${value.toStringAsFixed(digits)}%';
}

String formatPnl(double? value) {
  if (value == null) return '-';
  final sign = value > 0 ? '+' : '';
  return '$sign${value.toStringAsFixed(4)} USDT';
}
