import 'dart:io';

import 'package:mexc_core/mexc_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mexc_store_test');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  // サーバーは立ち上がり直したとき、最後に押された「開始 / 停止」を引き継ぐ。
  test('最後に押した「開始 / 停止」を覚える', () async {
    final store = FileBotStateStore(dir);
    expect(await store.loadRunning(), isNull);

    await store.saveRunning(false);
    expect(await FileBotStateStore(dir).loadRunning(), isFalse);

    await store.saveRunning(true);
    expect(await FileBotStateStore(dir).loadRunning(), isTrue);
  });
}
