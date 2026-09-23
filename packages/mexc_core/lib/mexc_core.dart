/// MEXC USDT無期限先物の自動売買ロジック。
///
/// サーバー常駐 (mexc_server) と、アプリ単体でのローカル実行 (app) の
/// 両方から同じコードを使う。
library;

export 'src/api/mexc_exception.dart';
export 'src/api/mexc_rest_client.dart';
export 'src/api/mexc_ws_client.dart';
export 'src/api/rate_limiter.dart';
export 'src/control/bot_controller.dart';
export 'src/control/protocol.dart';
export 'src/control/remote_bot_controller.dart';
export 'src/engine/bot_engine.dart';
export 'src/engine/market_data_feed.dart';
export 'src/engine/strategy_evaluator.dart';
export 'src/engine/trade_executor.dart';
export 'src/indicators/candle_series.dart';
export 'src/indicators/indicators.dart';
export 'src/models/bot_event.dart';
export 'src/models/candle.dart';
export 'src/models/contract_info.dart';
export 'src/models/market_data.dart';
export 'src/models/position.dart';
export 'src/models/signal.dart';
export 'src/models/strategy_config.dart';
export 'src/models/timeframe.dart';
export 'src/storage/bot_state_store.dart';
