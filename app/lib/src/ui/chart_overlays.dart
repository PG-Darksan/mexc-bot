import 'package:flutter/material.dart';

import '../app.dart';

/// 選べるバンドの σ。判定に使う σ がこれ以外なら、それも選べる。
const List<double> chartSigmaChoices = [2, 3, 4];

/// 選んだバンドのうち、チャートに描くもの。以前の版で選んだ ±1σ・±5σ など、
/// いまは選べない σ は描かない (外す手段が無くなるため)。
List<double> visibleChartSigmas(List<double> chosen, double strategySigma) => [
  for (final s in chosen)
    if (chartSigmaChoices.contains(s) || s == strategySigma) s,
];

/// チャートに足して描く線を選ぶボタン。どのチャートでも同じ選択を使う。
class ChartOverlayButton extends StatelessWidget {
  const ChartOverlayButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '線の表示',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.stacked_line_chart, size: 18),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => const _OverlaySheet(),
      ),
    );
  }
}

class _OverlaySheet extends StatelessWidget {
  const _OverlaySheet();

  static const List<int> _emas = [20, 50, 100, 150, 200];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final settings = state.settings;
    final side = state.snapshot.config.primarySide;
    final theme = Theme.of(context);

    void setSigmas(List<double> v) =>
        state.updateAppSettings(state.settings.copyWith(chartSigmas: v));
    void setEmas(List<int> v) =>
        state.updateAppSettings(state.settings.copyWith(chartEmas: v));

    String sigmaLabel(double s) => '${s == s.roundToDouble() ? s.toInt() : s}σ';

    // 画面が低いとき (横向きなど) にはみ出さないよう、スクロールできるようにする。
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'チャートに足す線',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '利確に使う EMA${side.emaPeriod} はいつも描きます。'
              '判定に使うバンドは ±${sigmaLabel(side.bbSigma)} です。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Text(
              'ボリンジャーバンド (期間 ${side.bbPeriod})',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final s in {...chartSigmaChoices, side.bbSigma}.toList()..sort())
                  FilterChip(
                    label: Text(
                      s == side.bbSigma
                          ? '±${sigmaLabel(s)} (判定)'
                          : '±${sigmaLabel(s)}',
                    ),
                    selected: settings.chartSigmas.contains(s),
                    onSelected: (on) => setSigmas(
                      on
                          ? [...settings.chartSigmas, s]
                          : ([...settings.chartSigmas]..remove(s)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('EMA', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final p in _emas)
                  FilterChip(
                    label: Text('EMA$p'),
                    selected: settings.chartEmas.contains(p),
                    onSelected: (on) => setEmas(
                      on
                          ? [...settings.chartEmas, p]
                          : ([...settings.chartEmas]..remove(p)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
