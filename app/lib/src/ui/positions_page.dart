import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import 'format.dart';

/// 保有中の建玉を並べる。状況タブに埋め込んで使う。
class OpenPositionsList extends StatelessWidget {
  const OpenPositionsList({
    super.key,
    required this.positions,
    required this.markPrices,
    required this.onClose,
    this.embedded = false,
  });

  final List<ManagedPosition> positions;
  final Map<String, double> markPrices;
  final Future<void> Function(String id) onClose;

  /// 別のスクロールの中に置くか。true なら自前ではスクロールしない。
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    if (positions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            '保有中のポジションはありません',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(16),
      itemCount: positions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final p = positions[index];
        final mark = markPrices[p.symbol];
        final pnl = mark == null ? null : p.unrealizedPnl(mark);
        final progress = _takeProfitProgress(p, mark);
        final isShort = p.direction.isShort;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      p.symbol.replaceAll('_USDT', ''),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: (isShort ? Colors.red : Colors.green).withValues(
                          alpha: 0.2,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${p.direction.label} ${p.leverage}x',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      p.timeframe.label,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Spacer(),
                    if (pnl != null)
                      Text(
                        formatPnl(pnl),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: pnl >= 0 ? Colors.green : Colors.red,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    _Field('建値', formatPrice(p.entryPrice)),
                    _Field('現在値', formatPrice(mark)),
                    _Field('利確目標', formatPrice(p.takeProfitPrice)),
                    if (p.stopLossPrice != null)
                      _Field('損切り', formatPrice(p.stopLossPrice)),
                    _Field('数量', '${p.vol} 枚'),
                    _Field('名目', '${p.notional.toStringAsFixed(2)} USDT'),
                    _Field('検知時EMA', formatPrice(p.emaAtSignal)),
                    _Field(
                      '検知時乖離',
                      formatSignedPercent(p.deviationAtSignal * 100),
                    ),
                    _Field('建てた時刻', formatTime(p.openedAt)),
                  ],
                ),
                if (progress != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text('利確まで ${(progress * 100).toStringAsFixed(0)}%'),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: () => _confirmClose(context, p),
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('成行で決済'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmClose(BuildContext context, ManagedPosition p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ポジションを決済しますか'),
        content: Text('${p.symbol} の${p.direction.label} ${p.vol} 枚を成行で決済します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('決済する'),
          ),
        ],
      ),
    );
    if (ok == true) await onClose(p.id);
  }
}

/// 建値から利確目標までの、いまの進み具合 (0.0〜1.0)。
///
/// 目標が建値と同じ側に無い (計算できない) ときは null。
double? _takeProfitProgress(ManagedPosition p, double? mark) {
  if (mark == null) return null;
  final span = p.direction.isShort
      ? p.entryPrice - p.takeProfitPrice
      : p.takeProfitPrice - p.entryPrice;
  if (span <= 0) return null;
  final done = p.direction.isShort ? p.entryPrice - mark : mark - p.entryPrice;
  return (done / span).clamp(0.0, 1.0);
}

/// 決済済みの履歴。横に長いので横スクロールで見る。
class ClosedPositionsTable extends StatelessWidget {
  const ClosedPositionsTable({super.key, required this.positions});

  final List<ManagedPosition> positions;

  @override
  Widget build(BuildContext context) {
    if (positions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            '決済済みの記録はありません',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: DataTable(
          columnSpacing: 20,
          columns: const [
            DataColumn(label: Text('銘柄')),
            DataColumn(label: Text('方向')),
            DataColumn(label: Text('時間軸')),
            DataColumn(label: Text('建てた時刻')),
            DataColumn(label: Text('決済時刻')),
            DataColumn(label: Text('建値')),
            DataColumn(label: Text('決済値')),
            DataColumn(label: Text('数量')),
            DataColumn(label: Text('損益')),
            DataColumn(label: Text('備考')),
          ],
          rows: [
            for (final p in positions)
              DataRow(
                cells: [
                  DataCell(Text(p.symbol.replaceAll('_USDT', ''))),
                  DataCell(Text(p.direction.label)),
                  DataCell(Text(p.timeframe.label)),
                  DataCell(Text(formatTime(p.openedAt))),
                  DataCell(Text(formatTime(p.closedAt))),
                  DataCell(Text(formatPrice(p.entryPrice))),
                  DataCell(Text(formatPrice(p.closePrice))),
                  DataCell(Text('${p.vol}')),
                  DataCell(
                    Text(
                      formatPnl(p.realizedPnl),
                      style: TextStyle(
                        color: (p.realizedPnl ?? 0) >= 0
                            ? Colors.green
                            : Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  DataCell(
                    Text(p.note ?? '', style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
