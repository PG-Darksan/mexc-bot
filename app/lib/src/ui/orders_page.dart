import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import 'format.dart';
import 'log_page.dart';

/// 注文と記録をまとめて見る画面。
///
/// 保有中・決済済み・ログの3つを切り替える。建玉と決済の記録は、端末に
/// 鍵があれば取引所から直接取ったものも出す (手で建てた建玉も見えるように)。
class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final snapshot = state.snapshot;
    final foreign = state.foreignPositions;
    final exchangeClosed = state.exchangeClosed;

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          TabBar(
            labelStyle: const TextStyle(fontSize: 13),
            tabs: [
              Tab(text: '保有中 (${snapshot.positions.length + foreign.length})'),
              Tab(
                text:
                    '決済済み (${exchangeClosed?.length ?? snapshot.closedPositions.length})',
              ),
              const Tab(text: 'ログ'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _OpenOrders(
                  positions: snapshot.positions,
                  foreign: foreign,
                  onClose: state.closePosition,
                ),
                _ClosedOrders(
                  positions: snapshot.closedPositions,
                  exchange: exchangeClosed,
                  onDelete: (id) => state.clearHistory(id: id),
                  onClearAll: state.clearHistory,
                ),
                const LogPage(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 端末から取引所へ聞けなかったときの知らせ。
class _ExchangeError extends StatelessWidget {
  const _ExchangeError(this.error);

  final String error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ipBlocked = error.contains('whitelist') || error.contains('406');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        ipBlocked
            ? '取引所から直接取れませんでした。この端末に入れた API キーは IP 制限が'
                  '付いていて、この端末の IP が許可されていません。手で建てた建玉も'
                  '出すには、設定タブに IP 制限の無い閲覧用のキーを入れてください。'
                  'いまはボットが建てた建玉だけを出しています。'
            : '取引所から直接取れませんでした ($error)。'
                  'いまはボットが建てた建玉だけを出しています。',
        style: TextStyle(fontSize: 12, color: theme.colorScheme.onErrorContainer),
      ),
    );
  }
}

class _OpenOrders extends StatelessWidget {
  const _OpenOrders({
    required this.positions,
    required this.foreign,
    required this.onClose,
  });

  final List<ManagedPosition> positions;

  /// 取引所にあって、ボットが管理していない建玉。
  final List<PositionInfo> foreign;
  final Future<void> Function(String id) onClose;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final error = state.exchangeError;
    final total = positions.length + foreign.length;

    return Column(
      children: [
        if (error != null) _ExchangeError(error),
        Expanded(
          child: total == 0
              ? const Center(child: Text('保有中のポジションはありません'))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: total,
                  separatorBuilder: (_, _) => const Divider(height: 20),
                  itemBuilder: (context, index) {
                    if (index >= positions.length) {
                      final p = foreign[index - positions.length];
                      final mark = state.lastPriceOf(p.symbol);
                      return _ExchangeTile(
                        position: p,
                        open: true,
                        markPrice: mark,
                        pnl: mark == null
                            ? null
                            : p.unrealizedPnl(
                                mark,
                                state.contractSizeOf(p.symbol),
                              ),
                        note: 'ボット管理外 (手で建てたものなど)',
                      );
                    }
                    final p = positions[index];
                    final mark = state.lastPriceOf(p.symbol);
                    final pnl = mark == null ? null : p.unrealizedPnl(mark);
                    return _OrderTile(
                      position: p,
                      open: true,
                      markPrice: mark,
                      pnl: pnl,
                      trailing: IconButton(
                        tooltip: '成行で決済',
                        icon: const Icon(Icons.logout, size: 20),
                        onPressed: () => _confirmClose(context, p),
                      ),
                    );
                  },
                ),
        ),
      ],
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

class _ClosedOrders extends StatefulWidget {
  const _ClosedOrders({
    required this.positions,
    required this.exchange,
    required this.onDelete,
    required this.onClearAll,
  });

  /// ボットの記録。
  final List<ManagedPosition> positions;

  /// 取引所の記録。端末から取れていなければ null。
  final List<PositionInfo>? exchange;
  final Future<void> Function(String id) onDelete;
  final Future<void> Function() onClearAll;

  @override
  State<_ClosedOrders> createState() => _ClosedOrdersState();
}

class _ClosedOrdersState extends State<_ClosedOrders> {
  /// 取引所の記録を見ているか。取れているときは、こちらを先に出す。
  bool _showExchange = true;

  @override
  Widget build(BuildContext context) {
    final exchange = widget.exchange;
    final showExchange = exchange != null && _showExchange;
    final state = AppScope.of(context);

    return Column(
      children: [
        if (state.exchangeError != null) _ExchangeError(state.exchangeError!),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              if (exchange != null)
                Expanded(
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: [
                      ButtonSegment(
                        value: true,
                        label: Text(
                          '取引所 (${exchange.length})',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text(
                          'ボット (${widget.positions.length})',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                    selected: {showExchange},
                    onSelectionChanged: (v) =>
                        setState(() => _showExchange = v.first),
                  ),
                )
              else
                const Spacer(),
              if (!showExchange && widget.positions.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _confirmClearAll(context),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('全削除'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: showExchange
              ? _exchangeList(exchange)
              : _botList(),
        ),
      ],
    );
  }

  Widget _exchangeList(List<PositionInfo> exchange) {
    if (exchange.isEmpty) {
      return const Center(child: Text('取引所に決済の記録はありません'));
    }
    // ボットが建てたものなら、時間軸と決済のしかたを添える。
    final botNotes = {
      for (final p in widget.positions)
        if (p.exchangePositionId != null)
          p.exchangePositionId!: [
            p.timeframe.label,
            if (p.note != null) p.note!,
          ].join(' / '),
    };
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: exchange.length,
      separatorBuilder: (_, _) => const Divider(height: 20),
      itemBuilder: (context, index) {
        final p = exchange[index];
        return _ExchangeTile(
          position: p,
          open: false,
          note: botNotes[p.positionId] == null
              ? '取引所の記録'
              : 'ボット / ${botNotes[p.positionId]}',
        );
      },
    );
  }

  Widget _botList() {
    if (widget.positions.isEmpty) {
      return const Center(child: Text('決済済みの記録はありません'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: widget.positions.length,
      separatorBuilder: (_, _) => const Divider(height: 20),
      itemBuilder: (context, index) {
        final p = widget.positions[index];
        return _OrderTile(
          position: p,
          open: false,
          trailing: IconButton(
            tooltip: '記録を消す',
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => widget.onDelete(p.id),
          ),
        );
      },
    );
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('記録を全部消しますか'),
        content: const Text('ボットの決済済みの記録だけを消します。建玉や口座、取引所の記録には触れません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('消す'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.onClearAll();
  }
}

/// 取引所の建玉 1 件ぶんの表示 (保有中・決済済みの両方)。
class _ExchangeTile extends StatelessWidget {
  const _ExchangeTile({
    required this.position,
    required this.open,
    required this.note,
    this.markPrice,
    this.pnl,
  });

  final PositionInfo position;
  final bool open;
  final String note;
  final double? markPrice;
  final double? pnl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = position;
    final sideColor = p.isShort ? Colors.redAccent : Colors.green;
    DateTime? at(int ms) =>
        ms <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              p.symbol.replaceAll('_', ''),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            _Tag(p.isShort ? '売り (ショート)' : '買い (ロング)', color: sideColor),
            _Tag('${p.leverage}x', color: theme.colorScheme.primary),
            _Tag(
              open ? '保有中' : '決済済み',
              color: open ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
          ],
        ),
        const SizedBox(height: 4),
        _Lines([
          _Line('建てた時刻', formatTime(at(p.createTime))),
          if (open) ...[
            _Line('建値', formatPrice(p.holdAvgPrice)),
            _Line('数量', '${p.holdVol} 枚'),
            if (markPrice != null) _Line('現在値', formatPrice(markPrice)),
            if (pnl != null)
              _Line(
                '評価損益',
                formatPnl(pnl),
                color: pnl! >= 0 ? Colors.green : Colors.red,
              ),
            if (p.liquidatePrice > 0)
              _Line('強制決済', formatPrice(p.liquidatePrice)),
          ] else ...[
            _Line('決済した時刻', formatTime(at(p.updateTime))),
            _Line('建値', formatPrice(p.openAvgPrice)),
            _Line('決済した値段', formatPrice(p.closeAvgPrice)),
            _Line('数量', '${p.closeVol} 枚'),
            _Line(
              '損益',
              formatPnl(p.realised),
              color: p.realised >= 0 ? Colors.green : Colors.red,
            ),
          ],
          _Line('備考', note),
        ]),
      ],
    );
  }
}

/// 注文 1 件ぶんの表示。参考にした画面と同じ並びにしてある。
class _OrderTile extends StatelessWidget {
  const _OrderTile({
    required this.position,
    required this.open,
    required this.trailing,
    this.markPrice,
    this.pnl,
  });

  final ManagedPosition position;
  final bool open;
  final Widget trailing;
  final double? markPrice;
  final double? pnl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isShort = position.direction.isShort;
    final sideColor = isShort ? Colors.redAccent : Colors.green;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    position.symbol.replaceAll('_', ''),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  _Tag(isShort ? '売り (ショート)' : '買い (ロング)', color: sideColor),
                  _Tag(
                    '${position.leverage}x',
                    color: theme.colorScheme.primary,
                  ),
                  _Tag(
                    open ? '保有中' : '決済済み',
                    color: open
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                ],
              ),
            ),
            trailing,
          ],
        ),
        const SizedBox(height: 4),
        _Lines([
          _Line('建てた時刻', formatTime(position.openedAt)),
          _Line('建値', formatPrice(position.entryPrice)),
          _Line('数量', '${position.vol} 枚'),
          _Line('利確', formatPrice(position.takeProfitPrice)),
          if (position.stopLossPrice != null)
            _Line('損切り', formatPrice(position.stopLossPrice)),
          if (position.addOnOrderId != null)
            _Line(
              isShort ? '売り足し' : '買い足し',
              '${position.addOnVol ?? '-'} 枚 @ ${formatPrice(position.addOnPrice)} '
                  '(${position.addOnFilled ? "約定済み・建値は平均後" : "指値で待機中"})',
              color: position.addOnFilled ? Colors.green : Colors.amber.shade800,
            ),
          if (open && markPrice != null) _Line('現在値', formatPrice(markPrice)),
          if (open && pnl != null)
            _Line(
              '評価損益',
              formatPnl(pnl),
              color: pnl! >= 0 ? Colors.green : Colors.red,
            ),
          if (!open) ...[
            _Line('決済した時刻', formatTime(position.closedAt)),
            _Line('決済した値段', formatPrice(position.closePrice)),
            _Line(
              '損益',
              formatPnl(position.realizedPnl),
              color: (position.realizedPnl ?? 0) >= 0 ? Colors.green : Colors.red,
            ),
          ],
          _Line(
            '備考',
            [
              position.timeframe.label,
              if (position.note != null) position.note!,
            ].join(' / '),
          ),
        ]),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 項目名と値の 1 行分。
class _Line {
  const _Line(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;
}

/// 項目名と値を表にして並べる。
///
/// 項目名の列は一番長い項目名に合わせ、項目名は折り返さない。幅を
/// 決め打ちにすると、文字の大きい端末で「決済した時/刻」のように途中で
/// 折り返してしまうため。
class _Lines extends StatelessWidget {
  const _Lines(this.lines);

  final List<_Line> lines;

  @override
  Widget build(BuildContext context) {
    final labelColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return Table(
      columnWidths: const {
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        for (final line in lines)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 12, bottom: 2),
                child: Text(
                  line.label,
                  softWrap: false,
                  style: TextStyle(fontSize: 12, color: labelColor),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  line.value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: line.color,
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
