import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mexc_core/mexc_core.dart';

import '../app.dart';
import 'format.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final Set<BotLogLevel> _levels = {
    BotLogLevel.info,
    BotLogLevel.warning,
    BotLogLevel.error,
    BotLogLevel.trade,
  };

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final events = state.events
        .where((e) => _levels.contains(e.level))
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final level in [
                    BotLogLevel.trade,
                    BotLogLevel.info,
                    BotLogLevel.warning,
                    BotLogLevel.error,
                  ])
                    FilterChip(
                      label: Text(_levelLabel(level)),
                      selected: _levels.contains(level),
                      onSelected: (v) => setState(() {
                        if (v) {
                          _levels.add(level);
                        } else {
                          _levels.remove(level);
                        }
                      }),
                    ),
                ],
              ),
              const Spacer(),
              IconButton(
                tooltip: 'クリップボードにコピー',
                icon: const Icon(Icons.copy_all, size: 18),
                onPressed: () {
                  final text = events
                      .map(
                        (e) =>
                            '${formatTime(e.time)} [${_levelLabel(e.level)}] ${e.message}',
                      )
                      .join('\n');
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('ログをコピーしました')));
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: events.isEmpty
              ? const Center(child: Text('ログはまだありません'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: events.length,
                  itemBuilder: (context, index) {
                    final e = events[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 68,
                            child: Text(
                              formatTimeShort(e.time),
                              style: TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Icon(
                            _levelIcon(e.level),
                            size: 14,
                            color: _levelColor(e.level),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SelectableText(
                              e.message,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _levelLabel(BotLogLevel level) => switch (level) {
    BotLogLevel.debug => 'デバッグ',
    BotLogLevel.info => '情報',
    BotLogLevel.warning => '注意',
    BotLogLevel.error => 'エラー',
    BotLogLevel.trade => '売買',
  };

  IconData _levelIcon(BotLogLevel level) => switch (level) {
    BotLogLevel.debug => Icons.bug_report_outlined,
    BotLogLevel.info => Icons.info_outline,
    BotLogLevel.warning => Icons.warning_amber_outlined,
    BotLogLevel.error => Icons.error_outline,
    BotLogLevel.trade => Icons.bolt,
  };

  Color _levelColor(BotLogLevel level) => switch (level) {
    BotLogLevel.debug => Colors.grey,
    BotLogLevel.info => Colors.blueGrey,
    BotLogLevel.warning => Colors.orange,
    BotLogLevel.error => Colors.red,
    BotLogLevel.trade => Colors.green,
  };
}
