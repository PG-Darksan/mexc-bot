/// ボットをどこで動かすか。
enum RunMode {
  /// この端末だけで完結させる。サーバーは要らないが、アプリを閉じると止まる。
  local,

  /// Oracle Cloud などに常駐させたサーバーにつなぐ。
  remote,
}

/// アプリ固有の設定 (売買ロジックの設定は mexc_core の StrategyConfig)。
class AppSettings {
  const AppSettings({
    this.mode = RunMode.local,
    this.serverUrl = 'ws://127.0.0.1:8080/ws',
    this.serverToken = '',
    this.allowSelfSignedCertificate = false,
    this.keepRunningInTray = true,
    this.autoStartBot = false,
  });

  final RunMode mode;
  final String serverUrl;
  final String serverToken;

  /// 自己署名証明書を許可するか。本番では false のままにする。
  final bool allowSelfSignedCertificate;

  /// Windows でウィンドウを閉じてもタスクトレイに常駐させるか。
  final bool keepRunningInTray;

  /// アプリ起動時にボットも起動するか。
  final bool autoStartBot;

  AppSettings copyWith({
    RunMode? mode,
    String? serverUrl,
    String? serverToken,
    bool? allowSelfSignedCertificate,
    bool? keepRunningInTray,
    bool? autoStartBot,
  }) => AppSettings(
    mode: mode ?? this.mode,
    serverUrl: serverUrl ?? this.serverUrl,
    serverToken: serverToken ?? this.serverToken,
    allowSelfSignedCertificate:
        allowSelfSignedCertificate ?? this.allowSelfSignedCertificate,
    keepRunningInTray: keepRunningInTray ?? this.keepRunningInTray,
    autoStartBot: autoStartBot ?? this.autoStartBot,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'serverUrl': serverUrl,
    'serverToken': serverToken,
    'allowSelfSignedCertificate': allowSelfSignedCertificate,
    'keepRunningInTray': keepRunningInTray,
    'autoStartBot': autoStartBot,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    mode: RunMode.values.firstWhere(
      (e) => e.name == json['mode'],
      orElse: () => RunMode.local,
    ),
    serverUrl: json['serverUrl'] as String? ?? 'ws://127.0.0.1:8080/ws',
    serverToken: json['serverToken'] as String? ?? '',
    allowSelfSignedCertificate:
        json['allowSelfSignedCertificate'] as bool? ?? false,
    keepRunningInTray: json['keepRunningInTray'] as bool? ?? true,
    autoStartBot: json['autoStartBot'] as bool? ?? false,
  );
}
