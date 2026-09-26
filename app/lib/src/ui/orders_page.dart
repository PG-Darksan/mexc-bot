import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import 'format.dart';
import 'log_page.dart';

/// 注文と記録をまとめて見る画面。
///
/// 保有中・決済済み・ログの3つを切り替える。
class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final snapshot = state.snapshot;

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          TabBar(
            labelStyle: const TextStyle(fontSize: 13),
            tabs: [
              Tab(text: '保有中 (${snapshot.positions.length})'),
              Tab(text: '決済済み (${snapshot.closedPositions.length})'),
              const Tab(text: 'ログ'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _OpenOrders(
                  positions: snapshot.positions,
                  markPrices: snapshot.markPrices,
                  onClose: state.closePosition,
                ),
                _ClosedOrders(
                  positions: snapshot.closedPositions,
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

class _OpenOrders extends StatelessWidget {
  const _OpenOrders({
    required this.positions,
    required this.markPrices,
    required this.onClose,
  });

  final List<ManagedPosition> positions;
  final Map<String, double> markPrices;
  final Future<void> Function(String id) onClose;

  @override
  Widget build(BuildContext context) {
    if (positions.isEmpty) {
      return const Center(child: Text('保有中のポジションはありません'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: positions.length,
      separatorBuilder: (_, _) => const Divider(height: 20),
      itemBuilder: (context, index) {
        final p = positions[index];
        final mark = markPrices[p.symbol];
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

class _ClosedOrders extends StatelessWidget {
  const _ClosedOrders({
    required this.positions,
    required this.onDelete,
    required this.onClearAll,
  });

  final List<ManagedPosition> positions;
  final Future<void> Function(String id) onDelete;
  final Future<void> Function() onClearAll;

  @override
  Widget build(BuildContext context) {
    if (positions.isEmpty) {
      return const Center(child: Text('決済済みの記録はありません'));
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 12, 0),
            child: TextButton.icon(
              onPressed: () => _confirmClearAll(context),
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('全削除'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            itemCount: positions.length,
            separatorBuilder: (_, _) => const Divider(height: 20),
            itemBuilder: (context, index) {
              final p = positions[index];
              return _OrderTile(
                position: p,
                open: false,
                trailing: IconButton(
                  tooltip: '記録を消す',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => onDelete(p.id),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('記録を全部消しますか'),
        content: const Text('決済済みの記録だけを消します。建玉や口座には触れません。'),
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
    if (ok == true) await onClearAll();
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
        _Line('建てた時刻', formatTime(position.openedAt)),
        _Line('建値', formatPrice(position.entryPrice)),
        _Line('数量', '${position.vol} 枚'),
        _Line('利確', formatPrice(position.takeProfitPrice)),
        if (position.stopLossPrice != null)
          _Line('損切り', formatPrice(position.stopLossPrice)),
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

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
