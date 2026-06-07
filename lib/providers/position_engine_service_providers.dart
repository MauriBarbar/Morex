import 'dart:async';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/models/managed_position.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/engine/position_engine.dart';

/// Sends commands to the background service's PositionEngine.
class PositionEngineServiceController {
  final _service = FlutterBackgroundService();

  Future<void> start() async {
    final isRunning = await _service.isRunning();
    if (!isRunning) {
      await _service.startService();
      await Future.delayed(const Duration(milliseconds: 600));
    }
    _service.invoke('pe_start');
  }

  void stop() => _service.invoke('pe_stop');

  void runOnce() => _service.invoke('pe_run_once');

  Future<void> shutdown() async => _service.invoke('shutdown');

  void executeSignal(Signal signal) {
    _service.invoke('pe_execute_signal', {
      'ticker': signal.ticker,
      'sentiment': signal.sentiment.name,
      'confidence': signal.confidence,
      'timeframe': signal.timeframe.name,
      'reasoning': signal.reasoning,
      'sourceHeadlines': signal.sourceHeadlines,
    });
  }

  void closePosition(String symbol) {
    _service.invoke('pe_close_position', {'symbol': symbol});
  }
}

final positionEngineServiceProvider =
    Provider<PositionEngineServiceController>((ref) {
  return PositionEngineServiceController();
});

/// Streams EngineStatus from the background service's PositionEngine.
final positionEngineStatusProvider = StreamProvider<EngineStatus>((ref) {
  final service = FlutterBackgroundService();
  final controller = StreamController<EngineStatus>.broadcast();

  // Seed with stopped status immediately.
  scheduleMicrotask(() {
    if (!controller.isClosed) controller.add(const EngineStatus());
  });

  final sub = service.on('pe_status').listen((event) {
    if (event == null || controller.isClosed) return;
    controller.add(EngineStatus(
      isRunning: event['isRunning'] as bool? ?? false,
      lastRun: event['lastRun'] != null
          ? DateTime.tryParse(event['lastRun'] as String)
          : null,
      lastError: event['lastError'] as String?,
    ));
  });

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});

/// Accumulates trade logs from the background service's PositionEngine.
final positionEngineLogsProvider =
    StateNotifierProvider<PositionEngineLogsNotifier, List<TradeLog>>((ref) {
  return PositionEngineLogsNotifier();
});

class PositionEngineLogsNotifier extends StateNotifier<List<TradeLog>> {
  StreamSubscription? _sub;

  PositionEngineLogsNotifier() : super([]) {
    final service = FlutterBackgroundService();
    _sub = service.on('pe_logs').listen((event) {
      if (event == null) return;
      final logMaps = (event['logs'] as List?) ?? [];
      state = logMaps.map((m) {
        final map = Map<String, dynamic>.from(m as Map);
        final ticker = map['ticker'] as String;
        return TradeLog(
          ticker: ticker,
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
            ticker: ticker,
            sentiment: Sentiment.neutral,
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

/// Live list of ManagedPosition objects from the background PositionEngine.
final positionEnginePositionsProvider =
    StateNotifierProvider<PositionEnginePositionsNotifier, List<ManagedPosition>>((ref) {
  return PositionEnginePositionsNotifier();
});

class PositionEnginePositionsNotifier extends StateNotifier<List<ManagedPosition>> {
  StreamSubscription? _sub;

  PositionEnginePositionsNotifier() : super([]) {
    final service = FlutterBackgroundService();
    _sub = service.on('pe_positions').listen((event) {
      if (event == null) return;
      final rawList = (event['positions'] as List?) ?? [];
      state = rawList
          .map((m) => ManagedPosition.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// Streams the result of a manual pe_close_position invocation.
final positionEngineCloseResultProvider = StreamProvider<Map<String, dynamic>>((ref) {
  final service = FlutterBackgroundService();
  final controller = StreamController<Map<String, dynamic>>.broadcast();

  final sub = service.on('pe_close_result').listen((event) {
    if (event == null || controller.isClosed) return;
    controller.add(Map<String, dynamic>.from(event));
  });

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});

/// Streams the result of a manual pe_execute_signal invocation.
final positionEngineSignalResultProvider = StreamProvider<Map<String, dynamic>>((ref) {
  final service = FlutterBackgroundService();
  final controller = StreamController<Map<String, dynamic>>.broadcast();

  final sub = service.on('pe_signal_result').listen((event) {
    if (event == null || controller.isClosed) return;
    controller.add(Map<String, dynamic>.from(event));
  });

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});
