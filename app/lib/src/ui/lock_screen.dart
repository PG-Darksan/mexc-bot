import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../state/app_state.dart';

/// ロックしている間、画面全体を覆う (チャートや値段を見えなくする)。
///
/// 下の画面は作ったまま隠す (外すと、開いていた取引画面などが消えるため)。
/// 売買の通知はサーバーから届き続ける。
class LockGate extends StatelessWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final locked = state.isLocked;
    return Stack(
      children: [
        ExcludeSemantics(
          excluding: locked,
          child: AbsorbPointer(absorbing: locked, child: child),
        ),
        if (locked) const Positioned.fill(child: LockScreen()),
      ],
    );
  }
}

/// ロック中の画面。解ける時刻までの残りと、長押しで解くボタンだけを出す。
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  /// 長押しで解くのに要る長さ。思わず開けてしまわないように長めにする。
  static const Duration holdToUnlock = Duration(seconds: 10);

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: LockScreen.holdToUnlock,
  )..addStatusListener(_onHoldStatus);
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    _hold.dispose();
    super.dispose();
  }

  void _onHoldStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      unawaited(AppScope.of(context).unlock());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    final until = state.lockUntil;
    final left = until?.difference(DateTime.now()) ?? Duration.zero;
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_clock, size: 64, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  'ロック中',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  until == null
                      ? ''
                      : 'あと ${formatLockLeft(left)}  (${_clock(until)} に開きます)',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'チャートから離れて、ひと休みしましょう。\n'
                  'ボットはサーバーで${state.isRunning ? '動いています' : '止まっています'}。'
                  '売買の通知は届きます。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 40),
                GestureDetector(
                  onLongPressStart: (_) => _hold.forward(from: 0),
                  onLongPressEnd: (_) {
                    if (_hold.status != AnimationStatus.completed) _hold.reset();
                  },
                  onLongPressCancel: () {
                    if (_hold.status != AnimationStatus.completed) _hold.reset();
                  },
                  child: AnimatedBuilder(
                    animation: _hold,
                    builder: (context, _) => SizedBox(
                      width: 96,
                      height: 96,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 96,
                            height: 96,
                            child: CircularProgressIndicator(
                              value: _hold.value,
                              strokeWidth: 6,
                              backgroundColor:
                                  theme.colorScheme.surfaceContainerHighest,
                            ),
                          ),
                          Icon(
                            Icons.lock_open,
                            size: 36,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '急ぎのときは、${LockScreen.holdToUnlock.inSeconds} 秒押し続けると開きます',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay
        ? '${two(t.hour)}:${two(t.minute)}'
        : '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// 残り時間を「1 時間 05 分」「42 分 10 秒」のように出す。
String formatLockLeft(Duration left) {
  if (left.isNegative) return '0 秒';
  final h = left.inHours;
  final m = left.inMinutes % 60;
  final s = left.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (h > 0) return '$h 時間 ${two(m)} 分';
  return '$m 分 ${two(s)} 秒';
}

/// ロックする長さを選ぶ窓。選んだら [AppState.lockUntilTime] まで呼ぶ。
Future<void> showLockDialog(BuildContext context) async {
  final state = AppScope.of(context);
  final now = DateTime.now();
  final tomorrowMorning = DateTime(now.year, now.month, now.day + 1, 7);
  final choices = <(String, DateTime)>[
    ('15 分', now.add(const Duration(minutes: 15))),
    ('30 分', now.add(const Duration(minutes: 30))),
    ('1 時間', now.add(const Duration(hours: 1))),
    ('2 時間', now.add(const Duration(hours: 2))),
    ('4 時間', now.add(const Duration(hours: 4))),
    ('8 時間', now.add(const Duration(hours: 8))),
    ('明日の朝 7:00 まで', tomorrowMorning),
  ];
  final picked = await showDialog<DateTime>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('アプリをロックする'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            'ロックの間はチャートも値段も見えません。'
            '急ぎのときは、ロック画面のボタンを 10 秒押し続けると開きます。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        for (final (label, until) in choices)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(until),
            child: Text(label),
          ),
        SimpleDialogOption(
          onPressed: () async {
            final time = await showTimePicker(
              context: context,
              initialTime: TimeOfDay.fromDateTime(
                now.add(const Duration(hours: 1)),
              ),
              helpText: '何時まで?',
            );
            if (time == null || !context.mounted) return;
            var until = DateTime(
              now.year,
              now.month,
              now.day,
              time.hour,
              time.minute,
            );
            if (!until.isAfter(now)) until = until.add(const Duration(days: 1));
            Navigator.of(context).pop(until);
          },
          child: const Text('時刻を決める…'),
        ),
      ],
    ),
  );
  if (picked != null) await state.lockUntilTime(picked);
}

/// 上のバーに置くロックのボタン。
class LockButton extends StatelessWidget {
  const LockButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'アプリをロック (チャートを見ないように)',
    icon: const Icon(Icons.lock_outline, size: 20),
    onPressed: () => showLockDialog(context),
  );
}
