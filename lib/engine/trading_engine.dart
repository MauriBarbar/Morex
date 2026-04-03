import 'dart:async';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/engine/order_executor.dart';
import 'package:morex/engine/risk_manager.dart';
import 'package:morex/engine/sentiment_analyzer.dart';

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

class TradingEngine {
  final SentimentAnalyzer _analyzer;
  final RiskManager _riskManager;
  final OrderExecutor _orderExecutor;
  final AlpacaClient _alpacaClient;

  Timer? _timer;
  EngineStatus _status = const EngineStatus();
  final _statusController = StreamController<EngineStatus>.broadcast();
  final List<TradeLog> _allLogs = [];

  Stream<EngineStatus> get statusStream => _statusController.stream;
  EngineStatus get status => _status;
  List<TradeLog> get tradeLogs => List.unmodifiable(_allLogs);

  TradingEngine({
    required SentimentAnalyzer analyzer,
    required RiskManager riskManager,
    required OrderExecutor orderExecutor,
    required AlpacaClient alpacaClient,
  })  : _analyzer = analyzer,
        _riskManager = riskManager,
        _orderExecutor = orderExecutor,
        _alpacaClient = alpacaClient;

  void start({Duration interval = const Duration(hours: 4)}) {
    if (_status.isRunning) return;
    _updateStatus(_status.copyWith(isRunning: true));
    // Run immediately, then on interval
    runCycle();
    _timer = Timer.periodic(interval, (_) => runCycle());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _updateStatus(_status.copyWith(isRunning: false));
  }

  Future<void> runCycle() async {
    try {
      // 1. Scan news & analyze
      final scanResult = await _analyzer.scan();

      // 2. Evaluate signals against risk rules
      final riskChecks = await _riskManager.evaluate(scanResult.signals);

      // 3. Execute approved trades
      for (final check in riskChecks) {
        if (!check.approved) {
          _logTrade(TradeLog(
            ticker: check.signal.ticker,
            action: TradeAction.skip,
            reasoning: check.reason,
            signal: check.signal,
            createdAt: DateTime.now(),
          ));
          continue;
        }

        if (check.signal.sentiment == Sentiment.bullish) {
          await _executeBuy(check);
        } else if (check.signal.sentiment == Sentiment.bearish) {
          await _executeSell(check);
        }
      }

      _updateStatus(_status.copyWith(
        lastRun: DateTime.now(),
        lastError: null,
        recentLogs: _allLogs.reversed.take(10).toList(),
      ));
    } catch (e) {
      _updateStatus(_status.copyWith(
        lastRun: DateTime.now(),
        lastError: e.toString(),
        recentLogs: _allLogs.reversed.take(10).toList(),
      ));
    }
  }

  Future<void> _executeBuy(RiskCheck check) async {
    final account = await _alpacaClient.getAccount();
    final amount = _riskManager.calculateOrderAmount(account);

    final log = await _orderExecutor.executeBuy(
      signal: check.signal,
      amountDollars: amount,
    );
    _logTrade(log);

    // Set stop-loss if order went through
    if (log.wasExecuted && log.price != null) {
      final stopPrice =
          log.price! * (1 - _riskManager.config.stopLossPercent);
      await _orderExecutor.setStopLoss(
        symbol: check.signal.ticker,
        stopPrice: stopPrice,
      );
    }
  }

  Future<void> _executeSell(RiskCheck check) async {
    final log = await _orderExecutor.executeSell(signal: check.signal);
    _logTrade(log);
  }

  void _logTrade(TradeLog log) {
    _allLogs.add(log);
  }

  void _updateStatus(EngineStatus newStatus) {
    _status = newStatus;
    _statusController.add(newStatus);
  }

  void dispose() {
    stop();
    _statusController.close();
  }
}
