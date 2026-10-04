import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:mexc_core/mexc_core.dart';

import '../ui/format.dart';

/// 端末の通知を出す。Android は通知、Windows はトースト。
///
/// 通知を出せない端末や、利用者が許可しなかったときは何もしない
/// (売買には関わらないので、失敗しても止めない)。
class TradeNotifier {
  final FlutterLocalNotificationsPlugin _android =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 0;

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  Future<void> initialize() async {
    if (!isSupported || _ready) return;
    try {
      if (Platform.isAndroid) {
        await _android.initialize(
          const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
        );
        // Android 13 以降は利用者の許可が要る。返事を待つとボットの起動まで
        // 待たされるので、尋ねるだけにする。
        unawaited(
          _android
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission(),
        );
      } else {
        await localNotifier.setup(appName: 'MEXC 自動売買');
      }
      _ready = true;
    } catch (e) {
      debugPrint('通知の準備に失敗しました: $e');
    }
  }

  Future<void> show(TradeMessage message) async {
    if (!_ready) return;
    try {
      if (Platform.isAndroid) {
        await _android.show(
          _nextId++,
          message.title,
          message.body,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'trades',
              '売買',
              channelDescription: '建てたときと決済したときの知らせ',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        );
      } else {
        await LocalNotification(
          title: message.title,
          body: message.body,
        ).show();
      }
    } catch (e) {
      debugPrint('通知を出せませんでした: $e');
    }
  }
}

/// 通知 1 件の文面。
typedef TradeMessage = ({String title, String body});

String _symbol(ManagedPosition p) => p.symbol.replaceAll('_', '');

String _side(ManagedPosition p) =>
    p.direction.isShort ? '売り (ショート)' : '買い (ロング)';

/// 建てたときの文面。
TradeMessage openedMessage(ManagedPosition p) => (
  title: '建てました: ${_symbol(p)} ${_side(p)}',
  body:
      '${p.vol} 枚 @ ${formatPrice(p.entryPrice)} / '
      '利確 ${formatPrice(p.takeProfitPrice)} (${p.timeframe.label})',
);

/// 決済したときの文面。
TradeMessage closedMessage(ManagedPosition p) => (
  title: '決済しました: ${_symbol(p)} ${formatPnl(p.realizedPnl)}',
  body:
      '${_side(p)} ${p.vol} 枚 / '
      '${formatPrice(p.entryPrice)} → ${formatPrice(p.closePrice)}'
      '${p.note == null ? '' : ' (${p.note})'}',
);

/// サーバーのボットが動き出した / 止まったときの文面。
TradeMessage runningMessage(bool running) => running
    ? (
        title: 'ボットを開始しました',
        body: 'サーバーで売買を始めました。「停止」を押すまで動き続けます。',
      )
    : (
        title: 'ボットを停止しました',
        body: 'サーバーのボットが止まりました。建玉と預けた利確はそのまま残ります。',
      );

/// 状態の移り変わりから、新しく建った建玉と決済された建玉を拾う。
///
/// 繋いだ直後 ([reset] の後) の 1 回目は、いまある分を覚えるだけで何も
/// 返さない。前からあった建玉を「建てました」と知らせないため。
/// 繋ぎ直しで途切れても覚えた分は残すので、その間に建った / 決済した
/// ものは、次に届いたときに知らせる。
class PositionChangeTracker {
  Set<String>? _open;
  Set<String>? _closed;

  void reset() {
    _open = null;
    _closed = null;
  }

  ({List<ManagedPosition> opened, List<ManagedPosition> closed}) update(
    BotSnapshot snapshot,
  ) {
    final knownOpen = _open;
    final knownClosed = _closed;
    _open = {for (final p in snapshot.positions) p.id};
    _closed = {for (final p in snapshot.closedPositions) p.id};
    if (knownOpen == null || knownClosed == null) {
      return (opened: const [], closed: const []);
    }
    return (
      opened: [
        for (final p in snapshot.positions)
          if (!knownOpen.contains(p.id) && !knownClosed.contains(p.id)) p,
      ],
      closed: [
        for (final p in snapshot.closedPositions)
          if (!knownClosed.contains(p.id)) p,
      ],
    );
  }
}
