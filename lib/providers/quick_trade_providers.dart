import 'dart:async';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/engine/quick_trade_engine.dart';
import 'package:morex/providers/storage_providers.dart';

/// Controller that sends commands to the background service.
class QuickTradeServiceController {
  final _service = FlutterBackgroundService();

  Future<void> start(List<String> watchlist, {double? budgetDollars}) async {
    final isRunning = await _service.isRunning();
    if (!isRunning) {
      await _service.startService();
      // Give the isolate a moment to initialize
      await Future.delayed(const Duration(milliseconds: 500));
    }
    _service.invoke('start', {
      'watchlist': watchlist,
      if (budgetDollars != null) 'budgetDollars': budgetDollars,
    });
  }

  void stop() {
    _service.invoke('stop');
  }

  void emergencyStop() {
    _service.invoke('emergency_stop');
  }

  void requestStatus() {
    _service.invoke('status_request');
  }

  Future<void> shutdown() async {
    _service.invoke('shutdown');
  }

  Future<bool> get isRunning => _service.isRunning();
}

final quickTradeServiceProvider = Provider<QuickTradeServiceController>((ref) {
  return QuickTradeServiceController();
});

/// Listens to status updates from the background service.
final quickTradeStatusProvider = StreamProvider<QuickTradeStatus>((ref) {
  final service = FlutterBackgroundService();
  final quickTradeController = ref.read(quickTradeServiceProvider);
  final controller = StreamController<QuickTradeStatus>.broadcast();

  // Seed with stopped status
  controller.add(const QuickTradeStatus());

  final sub = service.on('status').listen((event) {
    if (event == null) return;
    controller.add(QuickTradeStatus(
      state: event['state'] == 'running'
          ? QuickTradeEngineState.running
          : QuickTradeEngineState.stopped,
      budgetUsed: (event['budgetUsed'] as num?)?.toDouble() ?? 0,
      budgetLimit: (event['budgetLimit'] as num?)?.toDouble() ?? 0,
      openPositions: (event['openPositions'] as num?)?.toInt() ?? 0,
      totalTrades: (event['totalTrades'] as num?)?.toInt() ?? 0,
      sessionPnL: (event['sessionPnL'] as num?)?.toDouble() ?? 0,
      lastError: event['lastError'] as String?,
      updatedAt: event['updatedAt'] != null
          ? DateTime.tryParse(event['updatedAt'] as String)
          : null,
    ));
  });

  scheduleMicrotask(quickTradeController.requestStatus);

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});

/// Listens to trade logs from the background service.
final quickTradeLogsProvider =
    StateNotifierProvider<QuickTradeLogsNotifier, List<TradeLog>>((ref) {
  return QuickTradeLogsNotifier();
});

class QuickTradeLogsNotifier extends StateNotifier<List<TradeLog>> {
  StreamSubscription? _sub;

  QuickTradeLogsNotifier() : super([]) {
    final service = FlutterBackgroundService();
    _sub = service.on('logs').listen((event) {
      if (event == null) return;
      final logMaps = (event['logs'] as List?) ?? [];
      state = logMaps.map((m) {
        final map = Map<String, dynamic>.from(m as Map);
        return TradeLog(
          ticker: map['ticker'] as String,
          action: TradeAction.values.firstWhere(
            (a) => a.name == map['action'],
            orElse: () => TradeAction.skip,
          ),
          qty: (map['qty'] as num?)?.toDouble(),
          price: (map['price'] as num?)?.toDouble(),
          orderId: map['orderId'] as String?,
          roundTripId: map['roundTripId'] as String?,
          executionStatus: _parseExecutionStatus(map['executionStatus']),
          executedAt: map['executedAt'] != null
              ? DateTime.tryParse(map['executedAt'] as String? ?? '')
              : null,
          reasoning: map['reasoning'] as String? ?? '',
          signal: Signal(
            ticker: map['ticker'] as String,
            sentiment: Sentiment.bullish,
            confidence: 1.0,
            timeframe: Timeframe.short,
            reasoning: '',
            sourceHeadlines: [],
            createdAt: DateTime.now(),
          ),
          createdAt: DateTime.tryParse(map['createdAt'] as String? ?? '') ??
              DateTime.now(),
        );
      }).toList();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

TradeExecutionStatus? _parseExecutionStatus(Object? raw) {
  if (raw == null) return null;
  for (final status in TradeExecutionStatus.values) {
    if (status.name == raw) return status;
  }
  return null;
}

/// Keeps a rolling window of recent price ticks per symbol for charting.
/// Now fed by the background service IPC instead of a direct PriceStream.
const _maxPriceHistory = 120;

class PricePoint {
  final double price;
  final DateTime time;
  const PricePoint(this.price, this.time);
}

class PriceHistoryNotifier
    extends StateNotifier<Map<String, List<PricePoint>>> {
  StreamSubscription? _sub;

  PriceHistoryNotifier() : super({}) {
    final service = FlutterBackgroundService();
    _sub = service.on('prices').listen((event) {
      if (event == null) return;
      final newState = Map<String, List<PricePoint>>.from(state);
      for (final entry in event.entries) {
        final symbol = entry.key;
        if (entry.value is! Map) continue;
        final data = Map<String, dynamic>.from(entry.value as Map);
        final price = (data['price'] as num?)?.toDouble();
        final ts = DateTime.tryParse(data['timestamp'] as String? ?? '');
        if (price == null || ts == null) continue;

        final current = newState[symbol] ?? [];
        final updated = [...current, PricePoint(price, ts)];
        newState[symbol] = updated.length > _maxPriceHistory
            ? updated.sublist(updated.length - _maxPriceHistory)
            : updated;
      }
      state = newState;
    });
  }

  void clear() => state = {};

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final priceHistoryProvider =
    StateNotifierProvider<PriceHistoryNotifier, Map<String, List<PricePoint>>>(
  (ref) => PriceHistoryNotifier(),
);

final quickTradeAnalyticsProvider = Provider<QuickTradeAnalytics>((ref) {
  final persistedTrades = ref.watch(storedTradesProvider).valueOrNull ?? [];
  final liveLogs = ref.watch(quickTradeLogsProvider);
  final deduped = <String, TradeLog>{};

  // Dedup by orderId (unique per broker order) falling back to roundTripId+action.
  // Timestamp is intentionally excluded — reconciliation can restamp the same
  // trade, and including it would create duplicates in analytics.
  for (final log in [...persistedTrades, ...liveLogs]) {
    if (log.roundTripId == null) continue;
    final key = log.orderId != null
        ? 'order|${log.orderId}'
        : '${log.roundTripId}|${log.action.name}';
    deduped[key] = log;
  }

  return QuickTradeAnalytics.fromTradeLogs(deduped.values.toList());
});
