import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Windows でウィンドウを閉じてもボットを止めないための常駐まわり。
///
/// ローカル実行のときは、ウィンドウを閉じる = プロセス終了 = ボット停止 に
/// なってしまうので、閉じる操作をタスクトレイへの収納に置き換える。
/// Android では OS 側の制限があるため、この仕組みは使わない。
class TrayService with TrayListener, WindowListener {
  TrayService();

  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  bool _initialized = false;
  bool _keepInTray = true;

  /// 終了する直前に呼ぶ後片付け。建玉の保存やボットの停止に使う。
  Future<void> Function()? onBeforeExit;

  /// トレイに収納するかどうかを切り替える。
  void setKeepInTray(bool value) {
    _keepInTray = value;
    if (isSupported) {
      // 収納しない設定なら、閉じるボタンをそのまま終了に戻す。
      windowManager.setPreventClose(value);
    }
  }

  Future<void> initialize({
    required bool keepInTray,
    Future<void> Function()? onBeforeExit,
  }) async {
    this.onBeforeExit = onBeforeExit;
    if (!isSupported || _initialized) return;
    _initialized = true;
    _keepInTray = keepInTray;

    windowManager.addListener(this);
    await windowManager.setPreventClose(keepInTray);

    trayManager.addListener(this);
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.ico',
      );
      await trayManager.setToolTip('MEXC 自動売買');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'ウィンドウを表示'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '終了する'),
          ],
        ),
      );
    } catch (e) {
      // トレイアイコンを置けない環境でもアプリ自体は動かす。
      debugPrint('トレイアイコンを設定できませんでした: $e');
    }
  }

  @override
  void onWindowClose() async {
    if (!_keepInTray) {
      await _shutdown();
      return;
    }
    // 閉じる代わりに隠す。ボットはそのまま動き続ける。
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
      case 'exit':
        await _shutdown();
    }
  }

  Future<void> _shutdown() async {
    try {
      await onBeforeExit?.call();
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (_) {}
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  void dispose() {
    if (!isSupported) return;
    windowManager.removeListener(this);
    trayManager.removeListener(this);
  }
}
