import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mexc_bot_app/src/app.dart';
import 'package:mexc_bot_app/src/data/chart_data.dart';
import 'package:mexc_bot_app/src/data/chart_drawing.dart';
import 'package:mexc_bot_app/src/settings/app_settings.dart';
import 'package:mexc_bot_app/src/settings/settings_store.dart';
import 'package:mexc_bot_app/src/state/app_state.dart';
import 'package:mexc_bot_app/src/ui/interactive_chart.dart';
import 'package:mexc_bot_app/src/ui/lock_screen.dart';
import 'package:mexc_bot_app/src/ui/trade_page.dart';
import 'package:mexc_core/mexc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 波打つ値動き。
List<Candle> _candles(int n) => [
  for (var i = 0; i < n; i++)
    Candle(
      openTime: 1700000000 + i * 900,
      open: 100 + 10 * math.sin(i / 10),
      high: 102 + 10 * math.sin(i / 10),
      low: 98 + 10 * math.sin(i / 10),
      close: 100 + 10 * math.sin((i + 1) / 10),
      volume: 1,
      amount: 1,
    ),
];

Widget _chartHost({
  required ChartViewport viewport,
  ChartTool tool = ChartTool.none,
  List<ChartDrawing> drawings = const [],
  ValueChanged<List<ChartDrawing>>? onDrawingsChanged,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 400,
      height: 300,
      child: InteractiveChart(
        candles: _candles(300),
        viewport: viewport,
        bbPeriod: 20,
        bbSigma: 3,
        emaPeriod: 20,
        sigmas: const [3],
        tool: tool,
        drawings: drawings,
        onDrawingsChanged: onDrawingsChanged,
      ),
    ),
  ),
);

/// 取引画面に渡す、通信しないデータ元。[contractExtra] で銘柄の仕様を足せる。
ChartDataSource _fakeSource({Map<String, dynamic> contractExtra = const {}}) {
  final client = MockClient((req) async {
    final path = req.url.path;
    if (path.startsWith('/api/v1/contract/kline/')) {
      final c = _candles(200);
      return http.Response(
        jsonEncode({
          'success': true,
          'code': 0,
          'data': {
            'time': [for (final x in c) x.openTime],
            'open': [for (final x in c) x.open],
            'high': [for (final x in c) x.high],
            'low': [for (final x in c) x.low],
            'close': [for (final x in c) x.close],
            'vol': [for (final _ in c) 1],
            'amount': [for (final _ in c) 1],
          },
        }),
        200,
      );
    }
    if (path == '/api/v1/contract/detail') {
      return http.Response(
        jsonEncode({
          'success': true,
          'code': 0,
          'data': [
            {
              'symbol': 'BTC_USDT',
              'quoteCoin': 'USDT',
              'futureType': 1,
              'apiAllowed': true,
              'state': 0,
              'contractSize': 0.0001,
              'minVol': 1,
              'maxVol': 1000000,
              'volUnit': 1,
              'priceUnit': 0.1,
              'priceScale': 1,
              'maxLeverage': 100,
              ...contractExtra,
            },
          ],
        }),
        200,
      );
    }
    return http.Response('not found', 404);
  });
  return ChartDataSource(rest: MexcRestClient(httpClient: client), client: client);
}

void main() {
  group('取引画面のチャート', () {
    testWidgets('2 本指でつまむと、描く本数が変わる', (tester) async {
      final viewport = ChartViewport(visibleBars: 100);
      await tester.pumpWidget(_chartHost(viewport: viewport));
      final center = tester.getCenter(find.byType(InteractiveChart));
      final a = await tester.startGesture(center - const Offset(40, 0));
      final b = await tester.startGesture(center + const Offset(40, 0));
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await a.moveBy(const Offset(-10, 0));
        await b.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pump();
      // 指を広げたので拡大 = 本数が減る (動き出してからの幅で測るので、
      // 2.25 倍ちょうどにはならない)。
      expect(viewport.visibleBars, lessThan(80));
      expect(viewport.visibleBars, greaterThanOrEqualTo(ChartViewport.minBars));
    });

    testWidgets('1 本指で右へなぞると、過去へ動く', (tester) async {
      final viewport = ChartViewport(visibleBars: 100, rightOffset: 0);
      await tester.pumpWidget(_chartHost(viewport: viewport));
      await tester.drag(find.byType(InteractiveChart), const Offset(150, 0));
      await tester.pump();
      expect(viewport.rightOffset, greaterThan(20));
      expect(viewport.followsLatest, isFalse);
    });

    testWidgets('横線・2 点の線を引いて、消せる', (tester) async {
      final viewport = ChartViewport(visibleBars: 100);
      var drawings = <ChartDrawing>[];
      Future<void> pump(ChartTool tool) => tester.pumpWidget(
        _chartHost(
          viewport: viewport,
          tool: tool,
          drawings: drawings,
          onDrawingsChanged: (list) => drawings = list,
        ),
      );

      await pump(ChartTool.horizontal);
      final chart = tester.getRect(find.byType(InteractiveChart));
      await tester.tapAt(chart.topLeft + const Offset(150, 120));
      await tester.pump();
      expect(drawings, hasLength(1));
      expect(drawings.single.kind, DrawingKind.horizontal);

      await pump(ChartTool.trend);
      await tester.tapAt(chart.topLeft + const Offset(60, 200));
      await tester.pump();
      expect(drawings, hasLength(1)); // 1 点目だけではまだ引かない
      await tester.tapAt(chart.topLeft + const Offset(250, 80));
      await tester.pump();
      expect(drawings, hasLength(2));
      final trend = drawings.last;
      expect(trend.kind, DrawingKind.trend);
      expect(trend.time1!, lessThan(trend.time2!));
      expect(trend.price1, lessThan(trend.price2!));

      await pump(ChartTool.erase);
      await tester.tapAt(chart.topLeft + const Offset(150, 120));
      await tester.pump();
      expect(drawings, hasLength(1));
      expect(drawings.single.kind, DrawingKind.trend);
    });
  });

  group('取引画面', () {
    testWidgets('長押しから指値の値段を入れ、つながっていなければ注文は押せない', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(SettingsStore());
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: MaterialApp(
            home: TradePage(symbol: 'BTC_USDT', source: _fakeSource()),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(InteractiveChart), findsOneWidget);
      expect(find.text('注文'), findsOneWidget);
      expect(find.textContaining('サーバーにつながっていないので'), findsOneWidget);

      await tester.longPress(find.byType(InteractiveChart));
      await tester.pumpAndSettle();
      await tester.tap(find.text('指値で買う (ロング)'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, '指値の値段'),
      );
      expect(double.tryParse(field.controller!.text), isNotNull);

      // 証拠金を入れても、つながっていなければ押せない。
      await tester.enterText(
        find.widgetWithText(TextField, '証拠金 (USDT)'),
        '10',
      );
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('指値で買う (ロング)'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(button.onPressed, isNull);

      // 取り直しのタイマーを止める。
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('銘柄の上限が使える残高より小さければ、% は上限に対する割合', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(SettingsStore());
      state.debugSetSnapshot(
        const BotSnapshot(
          running: false,
          config: StrategyConfig(),
          wsConnected: false,
          watchedSymbolCount: 0,
          subscriptionCount: 0,
          evaluations: [],
          positions: [],
          closedPositions: [],
          asset: AccountAsset(
            currency: 'USDT',
            availableBalance: 800,
            equity: 800,
            positionMargin: 0,
            frozenBalance: 0,
            unrealized: 0,
            cashBalance: 800,
          ),
        ),
      );
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // 上限 20000 枚 × 0.0001 BTC = 2 BTC。いまの値段 (最後の終値) で 1 倍の証拠金にする。
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: MaterialApp(
            home: TradePage(
              symbol: 'BTC_USDT',
              source: _fakeSource(
                contractExtra: {
                  'riskBaseVol': 20000,
                  'riskIncrVol': 0,
                  'riskLevelLimit': 1,
                },
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final last = 100 + 10 * math.sin(200 / 10);
      final limit = 20000 * 0.0001 * last;
      expect(limit, lessThan(800));

      final chip = find.widgetWithText(ActionChip, '25%');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump();
      final margin = tester.widget<TextField>(
        find.widgetWithText(TextField, '証拠金 (USDT)'),
      );
      // 残高 800 の 25% (= 200、上限いっぱい) ではなく、上限の 25%。
      expect(
        double.parse(margin.controller!.text),
        closeTo(limit * 0.25, 0.011),
      );
      expect(find.textContaining('上限に対する割合'), findsOneWidget);

      // 上限を超えて入れると、超えていると出る。
      await tester.enterText(
        find.widgetWithText(TextField, '証拠金 (USDT)'),
        '300',
      );
      await tester.pump();
      expect(find.textContaining('建てられる残り'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('アプリのロック', () {
    testWidgets('ロック中は覆い、10 秒押し続けると開く', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(SettingsStore());
      await state.lockUntilTime(DateTime.now().add(const Duration(hours: 1)));
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: const MaterialApp(
            home: LockGate(child: Scaffold(body: Text('チャートの画面'))),
          ),
        ),
      );
      expect(find.text('ロック中'), findsOneWidget);
      expect(state.isLocked, isTrue);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.lock_open)),
      );
      await tester.pump(const Duration(seconds: 3));
      await gesture.up();
      await tester.pump();
      expect(state.isLocked, isTrue); // 短く離したら開かない

      final hold = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.lock_open)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 11));
      await hold.up();
      await tester.pumpAndSettle();
      expect(state.isLocked, isFalse);
      expect(find.text('ロック中'), findsNothing);
      expect(find.text('チャートの画面'), findsOneWidget);
    });

    test('ロックは保存され、時刻を過ぎていれば解けている', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore();
      final until = DateTime.now().add(const Duration(minutes: 30));
      await store.saveLockUntil(until);
      expect((await store.loadLockUntil())!.isAtSameMomentAs(until), isTrue);
      await store.saveLockUntil(null);
      expect(await store.loadLockUntil(), isNull);
    });
  });

  group('保存', () {
    test('引いた線を銘柄ごとに覚える', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore();
      final trend = ChartDrawing.trend(
        timeA: 2000,
        priceA: 2,
        timeB: 1000,
        priceB: 1,
      );
      await store.saveDrawings({
        'BTC_USDT': [ChartDrawing.horizontal(100), trend],
      });
      final back = await store.loadDrawings();
      expect(back['BTC_USDT'], hasLength(2));
      final t = back['BTC_USDT']!.last;
      // 古い方が 1 点目に並び直り、間の時刻の値段を出せる。
      expect(t.time1, 1000);
      expect(t.priceAt(1500), closeTo(1.5, 1e-9));
    });

    test('描く本数を覚える', () {
      const settings = AppSettings(chartBars: 60);
      expect(AppSettings.fromJson(settings.toJson()).chartBars, 60);
      expect(AppSettings.fromJson(const {}).chartBars, AppSettings.defaultChartBars);
    });
  });
}
