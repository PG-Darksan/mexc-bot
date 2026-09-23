import 'package:flutter/material.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import 'format.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final snapshot = state.snapshot;
    final config = snapshot.config;

    final closed = snapshot.closedPositions;
    final wins = closed.where((p) => (p.realizedPnl ?? 0) > 0).length;
    final totalPnl = closed.fold<double>(
      0,
      (sum, p) => sum + (p.realizedPnl ?? 0),
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionTitle('稼働状況'),
        _StatGrid(
          items: [
            _Stat(
              '状態',
              snapshot.running ? '稼働中' : '停止中',
              color: snapshot.running ? Colors.green : Colors.grey,
            ),
            _Stat(
              '相場データ',
              snapshot.wsConnected ? '接続中' : '未接続',
              color: snapshot.wsConnected ? Colors.green : Colors.orange,
            ),
            _Stat('監視銘柄', '${snapshot.watchedSymbolCount} 銘柄'),
            _Stat('購読系列', '${snapshot.subscriptionCount} 系列'),
            if (snapshot.pendingHistoryCount > 0)
              _Stat(
                '履歴の読み込み',
                '残り ${snapshot.pendingHistoryCount} 系列',
                color: Colors.orange,
              ),
            _Stat('最終判定', formatTimeShort(snapshot.lastCycleAt)),
            _Stat(
              '判定所要',
              snapshot.lastCycleDurationMs == null
                  ? '-'
                  : '${snapshot.lastCycleDurationMs} ms',
            ),
          ],
        ),
        const SizedBox(height: 24),
        _SectionTitle('口座'),
        _StatGrid(
          items: [
            _Stat(
              '残高',
              snapshot.asset == null
                  ? '-'
                  : '${snapshot.asset!.availableBalance.toStringAsFixed(2)} USDT',
            ),
            _Stat(
              '証拠金',
              snapshot.asset == null
                  ? '-'
                  : '${snapshot.asset!.positionMargin.toStringAsFixed(2)} USDT',
            ),
            _Stat(
              '評価損益',
              snapshot.asset == null
                  ? '-'
                  : formatPnl(snapshot.asset!.unrealized),
              color: (snapshot.asset?.unrealized ?? 0) >= 0
                  ? Colors.green
                  : Colors.red,
            ),
            _Stat('保有中', '${snapshot.positions.length} 件'),
            _Stat('決済済み', '${closed.length} 件'),
            _Stat(
              '累計損益',
              formatPnl(totalPnl),
              color: totalPnl >= 0 ? Colors.green : Colors.red,
            ),
            if (closed.isNotEmpty)
              _Stat(
                '勝率',
                '${(wins / closed.length * 100).toStringAsFixed(1)}%',
              ),
          ],
        ),
        const SizedBox(height: 24),
        _SectionTitle('いまの条件'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 方向に依らない条件。
                Wrap(
                  spacing: 24,
                  runSpacing: 12,
                  children: [
                    _Condition(
                      '24h出来高',
                      '${formatUsdtCompact(config.minAmount24Usdt)} USDT 以上',
                    ),
                    _Condition(
                      '時間軸',
                      config.timeframes.map((t) => t.label).join(' / '),
                    ),
                    _Condition(
                      '判定間隔',
                      '${config.evaluationIntervalSeconds} 秒ごと',
                    ),
                    if (!config.fundingFilterEnabled)
                      const _Condition('資金調達', 'フィルタなし'),
                  ],
                ),
                const Divider(height: 24),
                // ショートとロングは同じ並びで、広い画面では左右に置く。
                LayoutBuilder(
                  builder: (context, constraints) {
                    final cards = [
                      for (final side in config.enabledSides)
                        _SideConditions(side: side, config: config),
                    ];
                    if (cards.isEmpty) {
                      return const Text('ショートもロングも切ってあります。');
                    }
                    if (constraints.maxWidth < 560 || cards.length == 1) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < cards.length; i++) ...[
                            if (i > 0) const SizedBox(height: 16),
                            cards[i],
                          ],
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: cards[0]),
                        const SizedBox(width: 16),
                        Expanded(child: cards[1]),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        _SectionTitle('直近の検知'),
        _RecentSignals(events: state.events),
      ],
    );
  }
}

class _RecentSignals extends StatelessWidget {
  const _RecentSignals({required this.events});

  final List<BotEvent> events;

  @override
  Widget build(BuildContext context) {
    final trades = events
        .where((e) => e.level == BotLogLevel.trade)
        .take(10)
        .toList();
    if (trades.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('まだ検知はありません')),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          for (final e in trades)
            ListTile(
              dense: true,
              leading: const Icon(Icons.bolt, size: 18),
              title: Text(e.message, style: const TextStyle(fontSize: 13)),
              trailing: Text(
                formatTimeShort(e.time),
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _Stat {
  _Stat(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.items});

  final List<_Stat> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 200).floor().clamp(2, 6);
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 2.4,
          children: [
            for (final item in items)
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.value,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: item.color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 片方向ぶんの条件をまとめて出す。設定タブと同じ並びにしてある。
class _SideConditions extends StatelessWidget {
  const _SideConditions({required this.side, required this.config});

  final SideConfig side;
  final StrategyConfig config;

  @override
  Widget build(BuildContext context) {
    final isShort = side.direction.isShort;
    final color = isShort ? Colors.redAccent : Colors.green;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isShort ? Icons.trending_down : Icons.trending_up,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(
              side.direction.label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            _Condition(
              'RSI(${config.rsiPeriod})',
              '${side.rsiThreshold} ${isShort ? "以上" : "以下"}',
            ),
            _Condition(
              'BB(${config.bbPeriod})',
              '${isShort ? "+" : "-"}${side.bbSigma}σ を'
                  '${isShort ? "上抜け" : "下抜け"}',
            ),
            _Condition(
              '利確',
              'EMA(${config.emaPeriod})乖離 × ${side.takeProfitFactor}',
            ),
            _Condition(
              '損切り',
              side.stopLossEnabled ? '${side.stopLossPercent}%' : 'なし',
            ),
            _Condition(
              '建玉',
              '${side.marginPerTradeUsdt} USDT × ${side.leverage} 倍',
            ),
            if (config.fundingFilterEnabled)
              _Condition(
                '資金調達',
                '負担 ${side.maxFundingBurdenPercent}% 超 / '
                    '間隔 ${side.minFundingIntervalHours}h 未満は除外',
              ),
          ],
        ),
      ],
    );
  }
}

class _Condition extends StatelessWidget {
  const _Condition(this.label, this.value);

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
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
