/// ボットをどこで動かすか。
enum RunMode {
  /// この端末だけで完結させる。サーバーは要らないが、アプリを閉じると止まる。
  local,

  /// Oracle Cloud などに常駐させたサーバーにつなぐ。
  remote,
}

/// 画面の明るさ。Flutter の ThemeMode と同じ並び。
enum AppThemeMode { system, light, dark }

/// アプリ固有の設定 (売買ロジックの設定は mexc_core の StrategyConfig)。
class AppSettings {
  const AppSettings({
    this.mode = RunMode.local,
    this.serverUrl = 'ws://127.0.0.1:8080/ws',
    this.serverToken = '',
    this.wasRunning = false,
    this.themeMode = AppThemeMode.system,
    this.chartSigmas = defaultChartSigmas,
    this.chartEmas = defaultChartEmas,
  });

  static const List<double> defaultChartSigmas = [2, 3];
  static const List<int> defaultChartEmas = [50, 100, 150];

  final RunMode mode;
  final String serverUrl;
  final String serverToken;

  /// ローカル実行で、「停止」を押さずに終わったか (閉じた・落ちた)。
  ///
  /// 「開始」から「停止」までを覚えておき、次に開いたとき続きから動かす。
  final bool wasRunning;

  /// 画面の明るさ。端末に合わせるか、明るい / 暗いを選ぶ。
  final AppThemeMode themeMode;

  /// チャートに足して描くボリンジャーバンドの σ。判定に使う σ は別に必ず描く。
  final List<double> chartSigmas;

  /// チャートに足して描く EMA の期間。利確に使う EMA は別に必ず描く。
  final List<int> chartEmas;

  AppSettings copyWith({
    RunMode? mode,
    String? serverUrl,
    String? serverToken,
    bool? wasRunning,
    AppThemeMode? themeMode,
    List<double>? chartSigmas,
    List<int>? chartEmas,
  }) => AppSettings(
    mode: mode ?? this.mode,
    serverUrl: serverUrl ?? this.serverUrl,
    serverToken: serverToken ?? this.serverToken,
    wasRunning: wasRunning ?? this.wasRunning,
    themeMode: themeMode ?? this.themeMode,
    chartSigmas: chartSigmas ?? this.chartSigmas,
    chartEmas: chartEmas ?? this.chartEmas,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'serverUrl': serverUrl,
    'serverToken': serverToken,
    'wasRunning': wasRunning,
    'themeMode': themeMode.name,
    'chartSigmas': chartSigmas,
    'chartEmas': chartEmas,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    mode: RunMode.values.firstWhere(
      (e) => e.name == json['mode'],
      orElse: () => RunMode.local,
    ),
    serverUrl: json['serverUrl'] as String? ?? 'ws://127.0.0.1:8080/ws',
    serverToken: json['serverToken'] as String? ?? '',
    // 以前の「アプリ起動と同時にボットを動かす」がオンなら、続きから動かす。
    wasRunning:
        json['wasRunning'] as bool? ?? json['autoStartBot'] as bool? ?? false,
    themeMode: AppThemeMode.values.firstWhere(
      (e) => e.name == json['themeMode'],
      orElse: () => AppThemeMode.system,
    ),
    chartSigmas:
        (json['chartSigmas'] as List?)
            ?.whereType<num>()
            .map((v) => v.toDouble())
            .toList() ??
        defaultChartSigmas,
    chartEmas:
        (json['chartEmas'] as List?)
            ?.whereType<num>()
            .map((v) => v.toInt())
            .toList() ??
        defaultChartEmas,
  );
}
