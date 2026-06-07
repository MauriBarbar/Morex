import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:morex/config/env.dart';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/api/alpaca_websocket.dart';
import 'package:morex/core/api/claude_client.dart';
import 'package:morex/core/api/news_client.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/engine/account_lock.dart';
import 'package:morex/engine/order_executor.dart';
import 'package:morex/engine/order_monitor.dart';
import 'package:morex/engine/position_engine.dart';
import 'package:morex/engine/position_manager.dart';
import 'package:morex/engine/price_stream.dart';
import 'package:morex/engine/quick_trade_engine.dart';
import 'package:morex/engine/risk_manager.dart';
import 'package:morex/engine/sentiment_analyzer.dart';
import 'package:morex/engine/trading_lock.dart';
import 'package:morex/core/logger.dart';
import 'package:morex/db/hive_store.dart';

const _notificationChannelId = 'morex_quick_trade';
const _notificationId = 888;
const _quickTradeWatchlistKey = 'quick_trade_watchlist';
const _quickTradeAutoResumeKey = 'quick_trade_auto_resume';

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  final androidConfig = AndroidConfiguration(
    onStart: _onStart,
    autoStart: false,
    isForegroundMode: true,
    notificationChannelId: _notificationChannelId,
    initialNotificationTitle: 'Morex Trading',
    initialNotificationContent: 'Engines ready',
    foregroundServiceNotificationId: _notificationId,
    foregroundServiceTypes: [AndroidForegroundType.dataSync],
  );

  final iosConfig = IosConfiguration(
    autoStart: false,
    onForeground: _onStart,
    onBackground: _onIosBackground,
  );

  await service.configure(
    androidConfiguration: androidConfig,
    iosConfiguration: iosConfig,
  );
}

Future<void> setupNotificationChannel() async {
  final notifications = FlutterLocalNotificationsPlugin();
  const androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings();
  const initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );
  await notifications.initialize(initSettings);

  final androidPlugin =
      notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      _notificationChannelId,
      'Morex Trading Engines',
      description: 'Shows when trading engines are active',
      importance: Importance.low,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
Future<void> _onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  await dotenv.load(fileName: '.env');

  // ── Validate configuration ────────────────────────────────────────────────
  if (!Env.isConfigured) {
    final missingKeys = <String>[];
    if (Env.alpacaApiKey.isEmpty) missingKeys.add('ALPACA_API_KEY');
    if (Env.alpacaApiSecret.isEmpty) missingKeys.add('ALPACA_API_SECRET');
    final message = 'Missing required API credentials: ${missingKeys.join(", ")}. '
        'Configure your .env file and restart the app.';
    service.invoke('config_error', {'message': message});
    service.stopSelf();
    return;
  }

  final notifications = FlutterLocalNotificationsPlugin();

  // ── Shared dependencies ─────────────────────────────────────────────────
  final client = AlpacaClient();
  final dataWs = AlpacaWebSocket(url: Env.alpacaDataStreamUrl);
  final tradingWs = AlpacaWebSocket(url: Env.alpacaTradingStreamUrl);
  final priceStream = PriceStream(dataWebSocket: dataWs);
  final orderMonitor = OrderMonitor(tradingWebSocket: tradingWs);
  final tradingLock = TradingLock(); // Shared between engines
  final accountLock = AccountLock(); // Shared between engines for exposure checking
  HiveStore? store;

  // ── Quick Trade engine ───────────────────────────────────────────────────
  QuickTradeEngine? qtEngine;

  // ── Position engine dependencies ─────────────────────────────────────────
  final claudeClient = ClaudeClient();
  final newsClient = NewsClient(alpacaClient: client);
  final sentimentAnalyzer = SentimentAnalyzer(
    newsClient: newsClient,
    claudeClient: claudeClient,
  );
  var riskManager = RiskManager(client: client);
  final orderExecutor = OrderExecutor(client: client);
  PositionManager? positionManager;
  PositionEngine? peEngine;
  StreamSubscription? peCriticalAlertSub;
  var peIsRunningCycle = false;

  // ── Helper: ensure store is ready ────────────────────────────────────────
  Future<HiveStore> ensureStore() async {
    if (store != null) return store!;
    store = HiveStore();
    await store!.init();
    return store!;
  }

  List<String> normalizeWatchlist(List<dynamic> rawWatchlist) {
    return rawWatchlist
        .map((symbol) => '$symbol'.trim().toUpperCase())
        .where((symbol) => symbol.isNotEmpty)
        .toSet()
        .toList();
  }

  RiskConfig _loadRiskConfig(HiveStore s) {
    return RiskConfig(
      stopLossPercent: (s.getSetting<double>('risk_stop_loss_pct', defaultValue: 8.0)! / 100),
      takeProfitPercent: (s.getSetting<double>('risk_take_profit_pct', defaultValue: 15.0)! / 100),
      takeProfitSellFraction: (s.getSetting<double>('risk_take_profit_sell_fraction', defaultValue: 50.0)! / 100),
      maxTotalExposurePercent: (s.getSetting<double>('risk_max_exposure_pct', defaultValue: 80.0)! / 100),
      maxPositionPercent: (s.getSetting<double>('risk_max_position_pct', defaultValue: 10.0)! / 100),
      maxOrderDollars: s.getSetting<double>('risk_max_order_dollars', defaultValue: 1000)!,
      trailingStopEnabled: s.getSetting<bool>('risk_trailing_stop_enabled', defaultValue: true)!,
      trailingStopPercent: (s.getSetting<double>('risk_trailing_stop_pct', defaultValue: 5.0)! / 100),
      maxHoldDays: s.getSetting<int>('risk_max_hold_days', defaultValue: 14)!,
      minConfidence: (s.getSetting<double>('risk_min_confidence', defaultValue: 60.0)! / 100),
      dailyLossLimitPercent: (s.getSetting<double>('risk_daily_loss_limit_pct', defaultValue: 3.0)! / 100),
      reEvalSellConfidence: (s.getSetting<double>('risk_re_eval_sell_confidence', defaultValue: 65.0)! / 100),
    );
  }

  Future<void> startQuickTrade(
    List<dynamic> rawWatchlist, {
    double? budgetDollars,
  }) async {
    final watchlist = normalizeWatchlist(rawWatchlist);
    if (watchlist.isEmpty) return;

    final s = await ensureStore();
    await s.setSetting(_quickTradeWatchlistKey, watchlist);
    await s.setSetting(_quickTradeAutoResumeKey, true);

    // Always rebuild with current settings — dispose stale engine if stopped.
    if (qtEngine != null && qtEngine!.status.state != QuickTradeEngineState.running) {
      qtEngine!.dispose();
      qtEngine = null;
    }

    riskManager = RiskManager(client: client, config: _loadRiskConfig(s));

    orderMonitor.start();
    qtEngine ??= QuickTradeEngine(
      client: client,
      priceStream: priceStream,
      store: s,
      orderMonitor: orderMonitor,
      tradingLock: tradingLock,
      riskManager: riskManager,
      accountLock: accountLock,
      config: QuickTradeConfig(maxOrderDollars: riskManager.config.maxOrderDollars),
    );
    await qtEngine!.start(watchlist, budgetDollars: budgetDollars);

    _updateNotification(notifications, _buildTitle(qtEngine, peEngine),
        _buildBody(qtEngine, peEngine));
  }

  Future<void> stopQuickTrade() async {
    qtEngine?.stop();
    final s = await ensureStore();
    await s.setSetting(_quickTradeAutoResumeKey, false);
    _updateNotification(notifications, _buildTitle(qtEngine, peEngine),
        _buildBody(qtEngine, peEngine));
  }

  // ── Helper: run position engine cycle with concurrency guard ─────────────
  Future<void> runPositionEngineCycle() async {
    if (peIsRunningCycle) return;
    peIsRunningCycle = true;
    try {
      await peEngine?.runCycle();
    } finally {
      peIsRunningCycle = false;
    }
  }

  // ── Quick Trade commands ─────────────────────────────────────────────────
  service.on('start').listen((event) async {
    final watchlist = (event?['watchlist'] as List?) ??
        ['NVDA', 'TSLA', 'AMD', 'AAPL'];
    final budgetDollars = (event?['budgetDollars'] as num?)?.toDouble();
    await startQuickTrade(watchlist, budgetDollars: budgetDollars);
  });

  service.on('stop').listen((_) async {
    await stopQuickTrade();
  });

  service.on('status_request').listen((_) {
    final qs = qtEngine?.status ?? const QuickTradeStatus();
    service.invoke('status', {
      'state': qs.state.name,
      'budgetUsed': qs.budgetUsed,
      'budgetLimit': qs.budgetLimit,
      'openPositions': qs.openPositions,
      'totalTrades': qs.totalTrades,
      'sessionPnL': qs.sessionPnL,
      'lastError': qs.lastError,
      'updatedAt': qs.updatedAt?.toIso8601String(),
    });
  });

  // ── Position Engine commands ──────────────────────────────────────────────
  service.on('pe_start').listen((_) async {
    // Cancel previous alert subscription before disposing the old engine.
    await peCriticalAlertSub?.cancel();
    peCriticalAlertSub = null;
    // Always dispose and recreate so settings changes take effect on restart.
    peEngine?.dispose();
    peEngine = null;
    peIsRunningCycle = false; // Reset guard so pe_run_once works after restart.

    final s = await ensureStore();
    positionManager = PositionManager(store: s);
    orderMonitor.start();

    // Load user-configured risk settings (saved by Settings screen)
    riskManager = RiskManager(client: client, config: _loadRiskConfig(s));

    final scanIntervalMin = s.getSetting<int>('engine_scan_interval_min', defaultValue: 20)!;

    peEngine = PositionEngine(
      analyzer: sentimentAnalyzer,
      riskManager: riskManager,
      orderExecutor: orderExecutor,
      alpacaClient: client,
      claudeClient: claudeClient,
      positionManager: positionManager!,
      orderMonitor: orderMonitor,
      priceStream: priceStream,
      tradingLock: tradingLock,
      accountLock: accountLock,
      store: s,
    );

    // Forward critical alerts to the UI and push a high-priority notification.
    peCriticalAlertSub = peEngine!.criticalAlerts.listen((message) {
      service.invoke('critical_alert', {'message': message});
      notifications.show(
        _notificationId + 1,
        '⚠️ Morex: Action Required',
        message,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _notificationChannelId,
            'Morex Trading Engines',
            importance: Importance.max,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(presentAlert: true, presentSound: true),
        ),
      );
    });

    peEngine!.start(interval: Duration(minutes: scanIntervalMin));

    _updateNotification(notifications, _buildTitle(qtEngine, peEngine),
        _buildBody(qtEngine, peEngine));
  });

  service.on('pe_stop').listen((_) {
    peEngine?.stop();
    _updateNotification(notifications, _buildTitle(qtEngine, peEngine),
        _buildBody(qtEngine, peEngine));
  });

  service.on('pe_close_position').listen((event) async {
    final symbol = event?['symbol'] as String?;
    if (symbol == null || symbol.isEmpty) return;
    try {
      await client.closePosition(symbol);
      service.invoke('pe_close_result', {'success': true, 'symbol': symbol});
      Log.i('BackgroundService', 'Manually closed position: $symbol');
    } catch (e) {
      Log.e('BackgroundService', 'Failed to close position $symbol: $e');
      service.invoke('pe_close_result', {'success': false, 'symbol': symbol, 'error': '$e'});
    }
  });

  service.on('pe_run_once').listen((_) {
    unawaited(runPositionEngineCycle());
  });

  service.on('pe_execute_signal').listen((event) async {
    if (event == null) return;
    final s = await ensureStore();
    positionManager ??= PositionManager(store: s); // reuse if pe_start already ran
    orderMonitor.start();

    // Reuse existing engine if running; otherwise create a fresh one with
    // current settings so manual signal execution always uses fresh config.
    if (peEngine == null) {
      riskManager = RiskManager(client: client, config: _loadRiskConfig(s));
      peEngine = PositionEngine(
        analyzer: sentimentAnalyzer,
        riskManager: riskManager,
        orderExecutor: orderExecutor,
        alpacaClient: client,
        claudeClient: claudeClient,
        positionManager: positionManager!,
        orderMonitor: orderMonitor,
        priceStream: priceStream,
        tradingLock: tradingLock,
        accountLock: accountLock,
        store: s,
      );
    }

    try {
      final signal = Signal(
        ticker: event['ticker'] as String,
        sentiment: Sentiment.values.firstWhere(
          (s) => s.name == event['sentiment'],
          orElse: () => Sentiment.neutral,
        ),
        confidence: (event['confidence'] as num?)?.toDouble() ?? 0.5,
        timeframe: Timeframe.values.firstWhere(
          (t) => t.name == event['timeframe'],
          orElse: () => Timeframe.medium,
        ),
        reasoning: event['reasoning'] as String? ?? '',
        sourceHeadlines: List<String>.from(event['sourceHeadlines'] as List? ?? []),
        createdAt: DateTime.now(),
      );
      await peEngine!.executeSignal(signal);
      service.invoke('pe_signal_result', {'success': true, 'ticker': signal.ticker});
    } catch (e) {
      Log.e('BackgroundService', 'pe_execute_signal error: $e');
      service.invoke('pe_signal_result', {'success': false, 'error': '$e'});
    }
  });

  // ── Foreground reconciliation ─────────────────────────────────────────────
  // Triggered when the app returns to foreground so fills missed while the
  // WebSocket was disconnected are recovered before the next price tick.
  service.on('reconcile').listen((_) async {
    try {
      if (qtEngine != null) await qtEngine!.reconcileOnForeground();
      peEngine?.reconcileOnForeground();
      Log.i('BackgroundService', 'Foreground reconciliation complete');
    } catch (e) {
      Log.e('BackgroundService', 'Foreground reconciliation error', e);
      service.invoke('critical_alert', {
        'message': 'Order reconciliation failed after returning to foreground. '
            'Open positions may be out of sync — check Alpaca manually.',
      });
    }
  });

  // ── Emergency Stop ────────────────────────────────────────────────────────
  service.on('emergency_stop').listen((_) async {
    try {
      // Stop both engines
      qtEngine?.stop();
      peEngine?.stop();

      // Cancel all open orders on Alpaca
      var cancelledCount = 0;
      try {
        final openOrders = await client.getOrders(status: 'open');
        for (final order in openOrders) {
          final orderId = order['id'] as String?;
          if (orderId != null) {
            await client.cancelOrder(orderId);
            cancelledCount++;
          }
        }
      } catch (e) {
        Log.e('BackgroundService', 'Failed to cancel orders: $e');
      }

      // Persist auto-resume = false
      final s = await ensureStore();
      await s.setSetting(_quickTradeAutoResumeKey, false);

      // Notify UI
      service.invoke('emergency_stop_complete', {'cancelledCount': cancelledCount});
      _updateNotification(notifications, _buildTitle(qtEngine, peEngine),
          _buildBody(qtEngine, peEngine));
    } catch (e) {
      Log.e('BackgroundService', 'Emergency stop error: $e');
      service.invoke('emergency_stop_complete', {'error': '$e'});
    }
  });

  // ── Shutdown ──────────────────────────────────────────────────────────────
  Timer? statusTimer;
  service.on('shutdown').listen((_) async {
    statusTimer?.cancel();
    await peCriticalAlertSub?.cancel();
    qtEngine?.dispose();
    peEngine?.dispose();
    orderMonitor.dispose();
    priceStream.dispose();
    dataWs.dispose();
    tradingWs.dispose();
    service.stopSelf();
  });

  final s = await ensureStore();
  final shouldAutoResume =
      s.getSetting<bool>(_quickTradeAutoResumeKey, defaultValue: false) ?? false;
  final savedWatchlist =
      normalizeWatchlist(s.getSetting<List>(_quickTradeWatchlistKey, defaultValue: const []) ?? const []);
  if (shouldAutoResume && savedWatchlist.isNotEmpty) {
    await startQuickTrade(savedWatchlist);
  }

  // ── Periodic status push + watchdog ──────────────────────────────────────
  statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
    // Quick Trade status
    if (qtEngine != null) {
      final qs = qtEngine!.status;
      service.invoke('status', {
        'state': qs.state.name,
        'budgetUsed': qs.budgetUsed,
        'budgetLimit': qs.budgetLimit,
        'openPositions': qs.openPositions,
        'totalTrades': qs.totalTrades,
        'sessionPnL': qs.sessionPnL,
        'lastError': qs.lastError,
      });

      final qLogs = qtEngine!.logs;
      if (qLogs.isNotEmpty) {
        service.invoke('logs', {
          'logs': qLogs.reversed.take(20).map((l) => {
            'ticker': l.ticker,
            'action': l.action.name,
            'qty': l.qty,
            'price': l.price,
            'orderId': l.orderId,
            'roundTripId': l.roundTripId,
            'executionStatus': l.executionStatus?.name,
            'executedAt': l.executedAt?.toIso8601String(),
            'reasoning': l.reasoning,
            'createdAt': l.createdAt.toIso8601String(),
          }).toList(),
        });
      }

      final prices = priceStream.latestPrices;
      if (prices.isNotEmpty) {
        service.invoke('prices', Map<String, dynamic>.from(
          prices.map((s, u) => MapEntry(s, {
            'price': u.price,
            'timestamp': u.timestamp.toIso8601String(),
          })),
        ));
      }
    }

    // Position Engine status
    if (peEngine != null) {
      final ps = peEngine!.status;
      service.invoke('pe_status', {
        'isRunning': ps.isRunning,
        'lastRun': ps.lastRun?.toIso8601String(),
        'lastError': ps.lastError,
      });

      final pLogs = peEngine!.tradeLogs;
      if (pLogs.isNotEmpty) {
        service.invoke('pe_logs', {
          'logs': pLogs.reversed.take(30).map((l) => {
            'ticker': l.ticker,
            'action': l.action.name,
            'qty': l.qty,
            'price': l.price,
            'orderId': l.orderId,
            'roundTripId': l.roundTripId,
            'executionStatus': l.executionStatus?.name,
            'executedAt': l.executedAt?.toIso8601String(),
            'reasoning': l.reasoning,
            'createdAt': l.createdAt.toIso8601String(),
          }).toList(),
        });
      }

      // Managed positions
      final positions = positionManager?.all ?? [];
      service.invoke('pe_positions', {
        'positions': positions.map((p) => p.toMap()).toList(),
      });

      // Watchdog: if running but stalled >30 min, trigger a cycle
      if (ps.isRunning && ps.lastRun != null) {
        final stale = DateTime.now().difference(ps.lastRun!);
        if (stale > const Duration(minutes: 30)) {
          unawaited(runPositionEngineCycle());
        }
      }
    }

    // Combined notification update
    if ((qtEngine?.status.state == QuickTradeEngineState.running) ||
        (peEngine?.status.isRunning == true)) {
      _updateNotification(notifications, _buildTitle(qtEngine, peEngine),
          _buildBody(qtEngine, peEngine));
    }
  });
}

// ── Notification helpers ────────────────────────────────────────────────────

String _buildTitle(QuickTradeEngine? qt, PositionEngine? pe) {
  final parts = <String>[];
  if (qt?.status.state == QuickTradeEngineState.running) parts.add('Quick Trade');
  if (pe?.status.isRunning == true) parts.add('Position');
  if (parts.isEmpty) return 'Morex — Engines idle';
  return 'Morex — ${parts.join(' + ')} running';
}

String _buildBody(QuickTradeEngine? qt, PositionEngine? pe) {
  final parts = <String>[];
  if (qt != null && qt.status.state == QuickTradeEngineState.running) {
    final s = qt.status;
    final sign = s.sessionPnL >= 0 ? '+' : '';
    parts.add('QT P&L: $sign\$${s.sessionPnL.toStringAsFixed(2)} '
        '| ${s.openPositions} open');
  }
  if (pe != null && pe.status.isRunning) {
    final lastRun = pe.status.lastRun;
    if (lastRun != null) {
      final mins = DateTime.now().difference(lastRun).inMinutes;
      parts.add('PE last run: ${mins}m ago');
    } else {
      parts.add('PE: scanning...');
    }
  }
  return parts.isEmpty ? 'No active engines' : parts.join('  •  ');
}

void _updateNotification(
  FlutterLocalNotificationsPlugin notifications,
  String title,
  String body,
) {
  notifications.show(
    _notificationId,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _notificationChannelId,
        'Morex Trading Engines',
        ongoing: true,
        playSound: false,
        enableVibration: false,
        importance: Importance.low,
        priority: Priority.low,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: DarwinNotificationDetails(),
    ),
  );
}
