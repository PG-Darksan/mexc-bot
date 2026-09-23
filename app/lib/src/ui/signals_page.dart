import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import 'format.dart';

/// いま監視している銘柄 × 時間軸の評価を一覧する。
///
/// 却下された組み合わせも理由つきで出すので、「なぜ入らないのか」が追える。
class SignalsPage extends StatefulWidget {
  const SignalsPage({super.key});

  @override
  State<SignalsPage> createState() => _SignalsPageState();
}

class _SignalsPageState extends State<SignalsPage> {
  bool _onlyClose = true;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final config = state.snapshot.config;
    var rows = state.snapshot.evaluations;

    if (_onlyClose) {
      // 「あと一歩」のものだけに絞る。出来高と履歴で落ちたものは隠す。
      rows = rows
          .where(
            (e) =>
                e.rejectReason != RejectReason.lowVolume &&
                e.rejectReason != RejectReason.insufficientData,
          )
          .toList();
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Text(
                '${rows.length} 件を表示',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              FilterChip(
                label: const Text('条件に近いものだけ'),
                selected: _onlyClose,
                onSelected: (v) => setState(() => _onlyClose = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('評価結果がまだありません (起動後しばらくお待ちください)'))
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: DataTable(
                        columnSpacing: 20,
                        headingRowHeight: 40,
                        dataRowMinHeight: 36,
                        dataRowMaxHeight: 40,
                        columns: const [
                          DataColumn(label: Text('銘柄')),
                          DataColumn(label: Text('方向')),
                          DataColumn(label: Text('時間軸')),
                          DataColumn(label: Text('価格')),
                          DataColumn(label: Text('RSI')),
                          DataColumn(label: Text('σ境界')),
                          DataColumn(label: Text('EMA')),
                          DataColumn(label: Text('乖離')),
                          DataColumn(label: Text('利確目標')),
                          DataColumn(label: Text('利確幅')),
                          DataColumn(label: Text('24h代金')),
                          DataColumn(label: Text('調達率')),
                          DataColumn(label: Text('間隔')),
                          DataColumn(label: Text('判定')),
                        ],
                        rows: [
                          for (final e in rows)
                            _row(context, e, config.sideOf(e.direction)),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// 1 行ぶんの表示。方向によって見るバンドとしきい値の向きが変わる。
  DataRow _row(BuildContext context, SignalEvaluation e, SideConfig side) {
    final rsiReached = e.rsi != null &&
        (e.direction.isShort
            ? e.rsi! >= side.rsiThreshold
            : e.rsi! <= side.rsiThreshold);
    final paysFunding = e.fundingRate != null &&
        (e.direction.isShort ? e.fundingRate! < 0 : e.fundingRate! > 0);

    return DataRow(
      color: e.isTriggered
          ? WidgetStatePropertyAll(Colors.green.withValues(alpha: 0.15))
          : null,
      cells: [
        DataCell(
          Text(
            e.symbol.replaceAll('_USDT', ''),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        DataCell(
          Text(
            e.direction.label,
            style: TextStyle(
              fontSize: 12,
              color: e.direction.isShort ? Colors.redAccent : Colors.green,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        DataCell(Text(e.timeframe.label)),
        DataCell(Text(formatPrice(e.price))),
        DataCell(
          Text(
            e.rsi?.toStringAsFixed(1) ?? '-',
            style: TextStyle(
              color: rsiReached ? Colors.green : null,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        DataCell(Text(formatPrice(e.bbBoundary))),
        DataCell(Text(formatPrice(e.ema))),
        DataCell(
          Text(
            e.deviation == null
                ? '-'
                : formatSignedPercent(e.deviation! * 100),
          ),
        ),
        DataCell(Text(formatPrice(e.takeProfitPrice))),
        DataCell(Text(formatPercent(e.expectedProfitPercent))),
        DataCell(Text(formatUsdtCompact(e.amount24))),
        DataCell(
          Text(
            e.fundingRate == null
                ? '-'
                : formatSignedPercent(e.fundingRate! * 100, digits: 4),
            style: TextStyle(color: paysFunding ? Colors.orange : null),
          ),
        ),
        DataCell(
          Text(e.fundingIntervalHours == null ? '-' : '${e.fundingIntervalHours}h'),
        ),
        DataCell(
          e.isTriggered
              ? const Text(
                  '条件成立',
                  style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                )
              : Text(
                  e.rejectReason!.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
        ),
      ],
    );
  }

}
