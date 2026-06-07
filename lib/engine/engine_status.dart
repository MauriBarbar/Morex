import 'package:morex/core/models/trade_log.dart';

class EngineStatus {
  final bool isRunning;
  final DateTime? lastRun;
  final String? lastError;
  final List<TradeLog> recentLogs;

  const EngineStatus({
    this.isRunning = false,
    this.lastRun,
    this.lastError,
    this.recentLogs = const [],
  });

  EngineStatus copyWith({
    bool? isRunning,
    DateTime? lastRun,
    String? lastError,
    List<TradeLog>? recentLogs,
  }) {
    return EngineStatus(
      isRunning: isRunning ?? this.isRunning,
      lastRun: lastRun ?? this.lastRun,
      lastError: lastError ?? this.lastError,
      recentLogs: recentLogs ?? this.recentLogs,
    );
  }
}
