import 'dart:async';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/api/claude_client.dart';
import 'package:morex/core/api/trading_exception.dart';
import 'package:morex/core/logger.dart';
import 'package:morex/core/models/managed_position.dart';
import 'package:morex/core/models/position_context.dart';
import 'package:morex/core/models/position.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/db/hive_store.dart';
import 'package:morex/engine/account_lock.dart';
import 'package:morex/engine/engine_status.dart';
import 'package:morex/engine/order_executor.dart';
import 'package:morex/engine/order_monitor.dart';
import 'package:morex/engine/position_manager.dart';
import 'package:morex/engine/price_stream.dart';
import 'package:morex/engine/risk_manager.dart';
import 'package:morex/engine/sentiment_analyzer.dart';
import 'package:morex/engine/trading_lock.dart';

export 'package:morex/engine/engine_status.dart';

class PositionEngine {
  final SentimentAnalyzer _analyzer;
  final RiskManager _riskManager;
  final OrderExecutor _orderExecutor;
  final AlpacaClient _alpacaClient;
  final ClaudeClient _claudeClient;
  final PositionManager _positionManager;
  final OrderMonitor _orderMonitor;
  final PriceStream _priceStream;
  final TradingLock _tradingLock;
  final AccountLock _accountLock;
  final HiveStore? _store;

  Timer? _timer;
  Timer? _retryTimer;
  bool _isCycleRunning = false;
  static const _retryDelay = Duration(minutes: 3);
  EngineStatus _status = const EngineStatus();
  final _statusController = StreamController<EngineStatus>.broadcast();
  final List<TradeLog> _allLogs = [];

  // Pending buy orders waiting for fill to place stop-loss
  final Map<String, _PendingPositionBuy> _pendingBuyOrders = {};
  final Map<String, _PendingPositionSell> _pendingSellOrders = {};

  // Throttle trailing stop updates (per symbol)
  final Map<String, DateTime> _lastTrailingUpdate = {};
  static const _trailingUpdateInterval = Duration(seconds: 60);

  StreamSubscription? _fillSubscription;
  StreamSubscription? _priceSubscription;

  final _criticalAlertController = StreamController<String>.broadcast();

  Stream<EngineStatus> get statusStream => _statusController.stream;
  /// Emits a human-readable message when a position is left unprotected and
  /// cannot be closed automatically. Callers should surface this to the user.
  Stream<String> get criticalAlerts => _criticalAlertController.stream;
  EngineStatus get status => _status;
  List<TradeLog> get tradeLogs => List.unmodifiable(_allLogs);
  PositionManager get positionManager => _positionManager;

  PositionEngine({
    required SentimentAnalyzer analyzer,
    required RiskManager riskManager,
    required OrderExecutor orderExecutor,
    required AlpacaClient alpacaClient,
    required ClaudeClient claudeClient,
    required PositionManager positionManager,
    required OrderMonitor orderMonitor,
    required PriceStream priceStream,
    required TradingLock tradingLock,
    required AccountLock accountLock,
    HiveStore? store,
  })  : _analyzer = analyzer,
        _riskManager = riskManager,
        _orderExecutor = orderExecutor,
        _alpacaClient = alpacaClient,
        _claudeClient = claudeClient,
        _positionManager = positionManager,
        _orderMonitor = orderMonitor,
        _priceStream = priceStream,
        _tradingLock = tradingLock,
        _accountLock = accountLock,
        _store = store {
    if (_store != null) {
      _allLogs.addAll(_store.getTrades());
    }
    _setupTrailingStopListener();
    _watchManagedSymbols();
  }

  void start({Duration interval = const Duration(minutes: 20)}) {
    if (_status.isRunning) return;
    _updateStatus(_status.copyWith(isRunning: true));
    // Set up fill listener only after reconciliation completes so fills that
    // arrive during startup are not processed before reconciliation has run.
    _reconcilePendingOrders().then((_) => _setupFillListener()).catchError((e) {
      Log.e('PositionEngine', 'Startup reconciliation failed', e);
      // Still wire up the fill listener so live fills are not missed.
      _setupFillListener();
    });
    runCycle();
    _timer = Timer.periodic(interval, (_) => runCycle());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _updateStatus(_status.copyWith(isRunning: false));
  }

  /// Called when the app returns to foreground. Re-runs order reconciliation so
  /// any fills that arrived while the WebSocket was disconnected are recovered.
  void reconcileOnForeground() {
    if (!_status.isRunning) return;
    Log.i('PositionEngine', 'Foreground reconciliation triggered');
    unawaited(_reconcilePendingOrders());
  }

  /// Reconcile pending orders on startup: fetch open orders from Alpaca,
  /// match against submitted logs in Hive, and create filled logs retroactively
  /// for orders that completed while the app was stopped.
  /// Retries up to 3 times with exponential backoff if the API is temporarily unavailable.
  Future<void> _reconcilePendingOrders({int attempt = 0}) async {
    if (_store == null) return;
    const maxAttempts = 3;
    try {
      final allOrders = await _alpacaClient.getOrders(status: 'all');
      final submittedLogs = _allLogs
          .where((log) => log.executionStatus == TradeExecutionStatus.submitted)
          .toList();

      for (final log in submittedLogs) {
        final orderId = log.orderId;
        if (orderId == null || orderId.isEmpty) continue;

        final alpacaOrder = allOrders.firstWhere(
          (order) => order['id'] == orderId,
          orElse: () => <String, dynamic>{},
        );

        if (alpacaOrder.isEmpty) continue;

        final status = alpacaOrder['status'] as String?;
        // Defensive parsing: filled_qty and filled_avg_price may be String or num
        final rawQty = alpacaOrder['filled_qty'];
        final filledQty = rawQty == null
            ? null
            : (rawQty is num ? rawQty.toDouble() : double.tryParse('$rawQty'));
        final rawPrice = alpacaOrder['filled_avg_price'];
        final filledPrice = rawPrice == null
            ? null
            : (rawPrice is num ? rawPrice.toDouble() : double.tryParse('$rawPrice'));

        if (status == 'filled' && filledQty != null && filledPrice != null) {
          // Skip if a filled log for this order already exists — prevents
          // duplicate entries when reconciliation is triggered more than once.
          if (_allLogs.any((l) =>
              l.orderId == orderId &&
              l.executionStatus == TradeExecutionStatus.filled)) continue;

          // Create a filled log for this order
          final filledLog = log.copyWith(
            qty: filledQty,
            price: filledPrice,
            executionStatus: TradeExecutionStatus.filled,
            executedAt: DateTime.tryParse(alpacaOrder['filled_at'] ?? '') ??
                DateTime.now(),
          );
          _allLogs.add(filledLog);
          await _store.saveTrade(filledLog);
          // Register with PositionManager so trailing stops, take-profit, and
          // re-evaluation can track this position. Skip if already registered
          // (e.g. the fill listener beat reconciliation).
          if (!_positionManager.isManaged(log.ticker)) {
            await _positionManager.registerBuy(
              symbol: log.ticker,
              orderId: orderId,
              entryPrice: filledPrice,
              qty: filledQty,
            );
          }
          Log.i('PositionEngine',
              'Reconciled: ${log.ticker} filled retroactively (${filledQty}@\$${filledPrice})');
        } else if (status == 'open' || status == 'pending_new') {
          // Order still pending on Alpaca — re-add to pending buys to wait for fill
          final symbol = log.ticker;
          final existingPending = _pendingBuyOrders[orderId];
          if (existingPending == null) {
            final pending = _PendingPositionBuy(
              signal: log.signal,
              submittedAt: log.createdAt,
              roundTripId: log.roundTripId ?? '',
            );
            // If partial fill data is available, set it
            if (filledQty != null && filledPrice != null) {
              pending.filledQty = filledQty;
              pending.filledAvgPrice = filledPrice;
            }
            _pendingBuyOrders[orderId] = pending;
            Log.i('PositionEngine',
                'Reconciled: Re-added pending buy ${symbol} (${orderId}) to await fill');
          }
        } else if (['canceled', 'rejected', 'expired'].contains(status)) {
          // Order failed — log as skipped
          final failedLog = log.copyWith(
            executionStatus: status == 'canceled'
                ? TradeExecutionStatus.canceled
                : status == 'rejected'
                    ? TradeExecutionStatus.rejected
                    : TradeExecutionStatus.expired,
          );
          _allLogs.add(failedLog);
          await _store.saveTrade(failedLog);
          Log.w('PositionEngine',
              'Reconciled: ${log.ticker} order failed with status $status');
        }
      }
    } catch (e) {
      if (attempt < maxAttempts - 1) {
        final delay = Duration(seconds: 5 * (1 << attempt)); // 5s, 10s, 20s
        Log.w('PositionEngine',
            'Fill reconciliation failed (attempt ${attempt + 1}/$maxAttempts), retrying in ${delay.inSeconds}s: $e');
        await Future.delayed(delay);
        unawaited(_reconcilePendingOrders(attempt: attempt + 1));
      } else {
        Log.e('PositionEngine',
            'Fill reconciliation failed after $maxAttempts attempts — submitted orders may be stale', e);
      }
    }
  }

  Future<void> runCycle() async {
    if (_isCycleRunning) {
      Log.w('PositionEngine', 'Cycle already in progress — skipping');
      return;
    }
    _isCycleRunning = true;
    _retryTimer?.cancel();
    _retryTimer = null;

    try {
      final errors = <String>[];

      // 1. Check take-profits on managed positions
      try {
        await _checkTakeProfits();
      } catch (e) {
        Log.e('PositionEngine', 'take-profit check failed', e);
        errors.add('take-profit: $e');
      }

      // 2. Re-evaluate existing positions
      try {
        await _reEvaluatePositions();
      } catch (e) {
        Log.e('PositionEngine', 're-evaluation failed', e);
        errors.add('re-eval: $e');
      }

      // 3. Scan news & analyze for new signals
      try {
        double? equity;
        try {
          final account = await _alpacaClient.getAccount();
          equity = account.equity;
        } catch (_) {}
        final scanResult = await _analyzer.scan(accountEquity: equity);
        Log.i('PositionEngine', 'Scanned ${scanResult.news.length} articles → '
            '${scanResult.signals.length} signals');

        if (scanResult.news.isEmpty) {
          errors.add('No news fetched — check network / feed URLs');
        } else if (scanResult.signals.isNotEmpty) {
          // 4. Evaluate signals against risk rules
          final riskChecks = await _riskManager.evaluate(scanResult.signals);
          Log.i('PositionEngine', 'Risk checks: ${riskChecks.length} '
              '(${riskChecks.where((c) => c.approved).length} approved)');

          // 5. Execute approved trades — each isolated so one bad order doesn't block others
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
            try {
              if (check.signal.sentiment == Sentiment.bullish) {
                await _executeBuy(check);
              } else if (check.signal.sentiment == Sentiment.bearish) {
                await _executeSell(check);
              }
            } catch (e) {
              Log.e('PositionEngine', 'Order failed for ${check.signal.ticker}', e);
              errors.add('order ${check.signal.ticker}: $e');
            }
          }
        }
      } catch (e) {
        Log.e('PositionEngine', 'scan/analyze failed', e);
        errors.add('scan: $e');
      }

      final errorMsg = errors.isEmpty ? null : errors.join(' | ');

      // If there were errors, schedule a retry sooner than the next hourly tick
      if (errors.isNotEmpty && _status.isRunning) {
        Log.i('PositionEngine', 'Scheduling retry in ${_retryDelay.inMinutes}m due to errors');
        _retryTimer = Timer(_retryDelay, runCycle);
      }

      _updateStatus(_status.copyWith(
        lastRun: DateTime.now(),
        lastError: errorMsg,
        recentLogs: _allLogs.reversed.take(10).toList(),
      ));
    } finally {
      _isCycleRunning = false;
    }
  }

  /// Immediately execute a single user-approved signal. Runs through risk
  /// manager (exposure checks, etc.) then calls the same buy/sell path as an
  /// automated cycle. Safe to call while the engine is stopped.
  Future<void> executeSignal(Signal signal) async {
    // When the engine is used for one-off manual execution (without calling
    // start()), the fill listener may not be active yet. Ensure it's running
    // so that the stop-loss is placed after the buy order fills.
    if (_fillSubscription == null) {
      _reconcilePendingOrders().then((_) => _setupFillListener()).catchError((Object e) {
        Log.e('PositionEngine', 'Reconciliation before manual signal failed', e);
        _setupFillListener();
      });
    }
    Log.i('PositionEngine', 'Manual signal execute: ${signal.ticker} '
        '(${signal.sentiment.name}, conf=${signal.confidence.toStringAsFixed(2)})');
    try {
      final checks = await _riskManager.evaluate([signal]);
      for (final check in checks) {
        if (!check.approved) {
          _logTrade(TradeLog(
            ticker: check.signal.ticker,
            action: TradeAction.skip,
            reasoning: 'Risk rejected (manual): ${check.reason}',
            signal: check.signal,
            createdAt: DateTime.now(),
          ));
          continue;
        }
        try {
          if (check.signal.sentiment == Sentiment.bullish) {
            await _executeBuy(check);
          } else if (check.signal.sentiment == Sentiment.bearish) {
            await _executeSell(check);
          }
        } catch (e) {
          Log.e('PositionEngine', 'Manual execute failed for ${check.signal.ticker}', e);
          rethrow;
        }
      }
    } catch (e) {
      Log.e('PositionEngine', 'executeSignal error', e);
      rethrow;
    }
  }

  // --- Buy / Sell ---

  Future<void> _executeBuy(RiskCheck check) async {
    if (!_tradingLock.tryAcquire(check.signal.ticker)) {
      _logTrade(TradeLog(
        ticker: check.signal.ticker,
        action: TradeAction.skip,
        reasoning: 'Another engine is already buying ${check.signal.ticker}',
        signal: check.signal,
        createdAt: DateTime.now(),
      ));
      return;
    }

    try {
      await _accountLock.acquire();
      try {
        final account = await _alpacaClient.getAccount();

        // Re-check exposure inside the lock — another signal may have passed the
        // risk check concurrently before either order was submitted.
        final positions = await _alpacaClient.getPositions();
        final openOrders = await _alpacaClient.getOrders(status: 'open');
        final pendingBuyValue = openOrders
            .where((o) =>
                o['side'] == 'buy' &&
                RiskManager.isPendingOrderStatus(o['status'] as String? ?? ''))
            .fold<double>(0, (sum, o) {
          final notional = double.tryParse(o['notional']?.toString() ?? '');
          return sum + (notional ?? 0);
        });
        final filledExposure =
            positions.fold<double>(0, (sum, p) => sum + p.marketValue.abs());
        final exposurePercent =
            (filledExposure + pendingBuyValue) / account.equity;
        if (exposurePercent >= _riskManager.config.maxTotalExposurePercent) {
          _logTrade(TradeLog(
            ticker: check.signal.ticker,
            action: TradeAction.skip,
            reasoning: 'Exposure re-check inside lock: '
                '${(exposurePercent * 100).toStringAsFixed(1)}% exceeds limit',
            signal: check.signal,
            createdAt: DateTime.now(),
          ));
          return;
        }

        final amount = _riskManager.calculateOrderAmount(account);
        final log = await _orderExecutor.executeBuy(
          signal: check.signal,
          amountDollars: amount,
        );
        _logTrade(log);

        // Track this order so we can place stop-loss on fill
        if (log.wasExecuted && log.orderId != null) {
          _pendingBuyOrders[log.orderId!] = _PendingPositionBuy(
            signal: check.signal,
            submittedAt: log.createdAt,
            roundTripId: log.roundTripId ?? log.orderId!,
          );
        }
      } finally {
        _accountLock.release();
      }
    } finally {
      _tradingLock.release(check.signal.ticker);
    }
  }

  Future<void> _executeSell(RiskCheck check) async {
    if (!_tradingLock.tryAcquire(check.signal.ticker)) {
      _logTrade(TradeLog(
        ticker: check.signal.ticker,
        action: TradeAction.skip,
        reasoning: 'Another engine is already selling ${check.signal.ticker}',
        signal: check.signal,
        createdAt: DateTime.now(),
      ));
      return;
    }

    try {
      final managed = _positionManager.getBySymbol(check.signal.ticker);
      final log = await _orderExecutor.executeSell(signal: check.signal);
      _logTrade(log);

      if (log.wasExecuted && log.orderId != null) {
        _pendingSellOrders[log.orderId!] = _PendingPositionSell(
          symbol: check.signal.ticker,
          action: TradeAction.sell,
          signal: check.signal,
          requestedQty: managed?.remainingQty,
          submittedAt: log.createdAt,
          roundTripId: log.roundTripId ?? log.orderId!,
          reason: log.reasoning,
          existingStopLossOrderId: managed?.stopLossOrderId,
          isFullClose: true,
        );
      }
    } finally {
      _tradingLock.release(check.signal.ticker);
    }
  }

  // --- Fill Listener (places stop-loss after buy fills) ---

  void _setupFillListener() {
    _fillSubscription = _orderMonitor.stream.listen(
      (update) {
        _handleFill(update).catchError((e) {
          Log.e('PositionEngine', 'Fill handler error for ${update.symbol}', e);
        });
      },
      onError: (e) => Log.e('PositionEngine', 'Fill stream error', e),
    );
  }

  Future<void> _handleFill(OrderUpdate update) async {
    if (update.side == 'buy') {
      await _handleBuyOrderUpdate(update);
      return;
    }
    if (update.side == 'sell') {
      await _handleSellOrderUpdate(update);
    }
  }

  Future<void> _handleBuyOrderUpdate(OrderUpdate update) async {
    final pending = _pendingBuyOrders[update.orderId];
    if (pending == null) return;

    if (update.isFilled) {
      _pendingBuyOrders.remove(update.orderId);
      await _finalizeBuyFill(pending, update);
      return;
    }

    if (update.event == OrderEvent.partialFill) {
      // Update pending entry with filled quantity and price, but keep in map
      if (update.filledQty != null && update.filledAvgPrice != null) {
        pending.filledQty = update.filledQty;
        pending.filledAvgPrice = update.filledAvgPrice;
        Log.d('PositionEngine', 'Partial fill: ${update.symbol} '
            '${update.filledQty}x @ \$${update.filledAvgPrice?.toStringAsFixed(2)} — '
            'waiting for full fill');
      }
      return;
    }

    if (update.isFailed) {
      _pendingBuyOrders.remove(update.orderId);
      _logTrade(TradeLog(
        ticker: pending.signal.ticker,
        action: TradeAction.skip,
        orderId: update.orderId,
        roundTripId: pending.roundTripId,
        executionStatus: _executionStatusFor(update.event),
        executedAt: update.timestamp,
        reasoning: 'Buy order ${update.event.name}: ${pending.signal.reasoning}',
        signal: pending.signal,
        createdAt: pending.submittedAt,
      ));
    }
  }

  Future<void> _finalizeBuyFill(
    _PendingPositionBuy pending,
    OrderUpdate update,
  ) async {
    final fillPrice = update.filledAvgPrice;
    final fillQty = update.filledQty;
    if (fillPrice == null || fillQty == null) {
      // Log as failed trade so order doesn't stay stuck
      Log.w('PositionEngine', 'Buy order filled but missing fill data: '
          '${update.symbol} (qty=$fillQty, price=$fillPrice)');
      _logTrade(TradeLog(
        ticker: pending.signal.ticker,
        action: TradeAction.skip,
        orderId: update.orderId,
        roundTripId: pending.roundTripId,
        executionStatus: TradeExecutionStatus.partialFill,
        executedAt: update.timestamp,
        reasoning: 'Buy filled but fill data incomplete (qty=$fillQty, price=$fillPrice)',
        signal: pending.signal,
        createdAt: pending.submittedAt,
      ));
      return;
    }

    Log.i('PositionEngine', 'Buy filled: ${update.symbol} '
        '${fillQty}x @ \$${fillPrice.toStringAsFixed(2)}');

    final config = _riskManager.config;
    final exitRules = ExitRules(
      stopLossPercent: config.stopLossPercent,
      takeProfitPercent: config.takeProfitPercent,
      takeProfitSellFraction: config.takeProfitSellFraction,
      trailingStopEnabled: config.trailingStopEnabled,
      trailingStopPercent: config.trailingStopPercent,
      maxHoldDays: config.maxHoldDays,
    );

    await _positionManager.registerBuy(
      symbol: update.symbol,
      orderId: update.orderId,
      entryPrice: fillPrice,
      qty: fillQty,
      exitRules: exitRules,
    );

    _logTrade(TradeLog(
      ticker: update.symbol,
      action: TradeAction.buy,
      qty: fillQty,
      price: fillPrice,
      orderId: update.orderId,
      roundTripId: pending.roundTripId,
      executionStatus: TradeExecutionStatus.filled,
      executedAt: update.timestamp,
      reasoning: 'Buy filled @ \$${fillPrice.toStringAsFixed(2)} — ${pending.signal.reasoning}',
      signal: pending.signal,
      createdAt: pending.submittedAt,
    ));

    final stopPrice = fillPrice * (1 - config.stopLossPercent);

    // Alpaca rejects stop orders for fractional shares on live accounts.
    // PositionEngine has no in-process price-tick exit (unlike QuickTrade),
    // so a fractional managed position would have no stop-loss at all.
    // Fail fast and emergency-close instead of waiting through 43s of retry
    // backoff that will all fail in production.
    if (_isFractionalQty(fillQty)) {
      Log.e('PositionEngine',
          'Fractional fill (${fillQty.toStringAsFixed(4)}) for ${update.symbol} — '
          'broker stop unsupported, force-closing rather than holding unprotected');
      unawaited(_emergencyCloseUnprotected(
        symbol: update.symbol,
        reason: 'Fractional fill cannot have a broker stop-loss on live Alpaca',
      ));
      _priceStream.watchSymbols([update.symbol]);
      return;
    }

    try {
      final stopOrderId = await _orderExecutor.setStopLoss(
        symbol: update.symbol,
        stopPrice: stopPrice,
        qty: fillQty,
      );
      await _positionManager.updateStopLoss(
        update.symbol,
        orderId: stopOrderId,
        stopPrice: stopPrice,
      );
      Log.i('PositionEngine', 'Stop-loss placed for ${update.symbol} '
          'at \$${stopPrice.toStringAsFixed(2)}');
    } on StopLossException catch (e) {
      Log.e('PositionEngine',
          'Stop-loss placement failed for ${update.symbol} — scheduling retry', e);
      unawaited(_retryStopLossOrClose(
        symbol: update.symbol,
        stopPrice: stopPrice,
        qty: fillQty,
      ));
    }

    _priceStream.watchSymbols([update.symbol]);
  }

  /// True when qty is not a whole share (within float tolerance). Alpaca
  /// rejects stop orders for fractional qty on live accounts.
  static bool _isFractionalQty(double qty) {
    return (qty - qty.roundToDouble()).abs() > 1e-6;
  }

  Future<void> _emergencyCloseUnprotected({
    required String symbol,
    required String reason,
  }) async {
    try {
      final emergencySignal = Signal(
        ticker: symbol,
        sentiment: Sentiment.bearish,
        confidence: 1.0,
        timeframe: Timeframe.short,
        reasoning: reason,
        sourceHeadlines: const [],
        createdAt: DateTime.now(),
      );
      final log = await _orderExecutor.executeSell(signal: emergencySignal);
      _logTrade(log.copyWith(reasoning: reason));
    } catch (e) {
      Log.e('PositionEngine',
          'CRITICAL: Cannot close unprotected position $symbol — manual intervention required', e);
      if (!_criticalAlertController.isClosed) {
        _criticalAlertController.add(
          'UNPROTECTED POSITION: $symbol could not be auto-closed. '
          'Please close it manually on Alpaca.',
        );
      }
      _updateStatus(_status.copyWith(
        lastError: 'CRITICAL: $symbol unprotected — close manually on Alpaca',
      ));
    }
  }

  /// Retries stop-loss placement with 3s/10s/30s backoff.
  /// If all attempts fail, submits a market sell to close the unprotected position.
  Future<void> _retryStopLossOrClose({
    required String symbol,
    required double stopPrice,
    required double qty,
    int attempt = 0,
  }) async {
    const maxAttempts = 3;
    const delays = [Duration(seconds: 3), Duration(seconds: 10), Duration(seconds: 30)];

    await Future.delayed(delays[attempt]);
    if (!_status.isRunning) return;

    try {
      final orderId = await _orderExecutor.setStopLoss(
        symbol: symbol,
        stopPrice: stopPrice,
        qty: qty,
      );
      await _positionManager.updateStopLoss(symbol, orderId: orderId, stopPrice: stopPrice);
      Log.i('PositionEngine', 'Stop-loss placed for $symbol (retry ${attempt + 1})');
    } on StopLossException catch (e) {
      if (attempt + 1 < maxAttempts) {
        Log.w('PositionEngine',
            'Stop-loss retry ${attempt + 1}/$maxAttempts failed for $symbol: $e');
        unawaited(_retryStopLossOrClose(
            symbol: symbol, stopPrice: stopPrice, qty: qty, attempt: attempt + 1));
      } else {
        Log.e('PositionEngine',
            'FORCE-CLOSE: stop-loss failed after $maxAttempts attempts for $symbol — '
            'submitting emergency sell', e);
        try {
          final emergencySignal = Signal(
            ticker: symbol,
            sentiment: Sentiment.bearish,
            confidence: 1.0,
            timeframe: Timeframe.short,
            reasoning: 'Emergency close: stop-loss placement failed after $maxAttempts attempts',
            sourceHeadlines: const [],
            createdAt: DateTime.now(),
          );
          final log = await _orderExecutor.executeSell(signal: emergencySignal);
          _logTrade(log.copyWith(
            reasoning: 'Emergency close: stop-loss placement failed after $maxAttempts attempts',
          ));
        } catch (sellErr) {
          Log.e('PositionEngine',
              'CRITICAL: Cannot close unprotected position $symbol — manual intervention required',
              sellErr);
          // Surface to UI — position is live, unprotected, and cannot be auto-closed.
          if (!_criticalAlertController.isClosed) {
            _criticalAlertController.add(
              'UNPROTECTED POSITION: $symbol has no stop-loss and could not be '
              'closed automatically. Please close it manually on Alpaca.',
            );
          }
          _updateStatus(_status.copyWith(
            lastError: 'CRITICAL: $symbol unprotected — close manually on Alpaca',
          ));
        }
      }
    }
  }

  Future<void> _handleSellOrderUpdate(OrderUpdate update) async {
    var pending = _pendingSellOrders[update.orderId];
    pending ??= _pendingStopLossOrder(update);
    if (pending == null) return;

    if (update.isFilled) {
      _pendingSellOrders.remove(update.orderId);
      await _finalizeSellFill(pending, update);
      return;
    }

    if (update.event == OrderEvent.partialFill) {
      // Update pending entry with filled quantity and price, but keep in map
      if (update.filledQty != null && update.filledAvgPrice != null) {
        pending.filledQty = update.filledQty;
        pending.filledAvgPrice = update.filledAvgPrice;
        Log.d('PositionEngine', 'Partial sell fill: ${update.symbol} '
            '${update.filledQty}x @ \$${update.filledAvgPrice?.toStringAsFixed(2)} — '
            'waiting for full fill');
      }
      return;
    }

    if (update.isFailed) {
      _pendingSellOrders.remove(update.orderId);
      _logTrade(TradeLog(
        ticker: pending.symbol,
        action: TradeAction.skip,
        orderId: update.orderId,
        roundTripId: pending.roundTripId,
        executionStatus: _executionStatusFor(update.event),
        executedAt: update.timestamp,
        reasoning: 'Sell order ${update.event.name}: ${pending.reason}',
        signal: pending.signal,
        createdAt: pending.submittedAt,
      ));
    }
  }

  _PendingPositionSell? _pendingStopLossOrder(OrderUpdate update) {
    final managed = _positionManager.all.where(
      (pos) => pos.stopLossOrderId == update.orderId && pos.symbol == update.symbol,
    );
    if (managed.isEmpty) return null;
    final pos = managed.first;
    final pending = _PendingPositionSell(
      symbol: pos.symbol,
      action: TradeAction.trailingStopSell,
      signal: Signal(
        ticker: pos.symbol,
        sentiment: Sentiment.bearish,
        confidence: 1.0,
        timeframe: Timeframe.short,
        reasoning: 'Stop-loss filled',
        sourceHeadlines: const [],
        createdAt: DateTime.now(),
      ),
      requestedQty: pos.remainingQty,
      submittedAt: DateTime.now(),
      roundTripId: pos.buyOrderId,
      reason: 'Trailing/stop-loss exit',
      existingStopLossOrderId: pos.stopLossOrderId,
      isFullClose: true,
    );
    _pendingSellOrders[update.orderId] = pending;
    return pending;
  }

  Future<void> _finalizeSellFill(
    _PendingPositionSell pending,
    OrderUpdate update,
  ) async {
    final fillPrice = update.filledAvgPrice;
    final fillQty = update.filledQty;
    if (fillPrice == null || fillQty == null) {
      // Log as failed trade so order doesn't stay stuck
      Log.w('PositionEngine', 'Sell order filled but missing fill data: '
          '${update.symbol} (qty=$fillQty, price=$fillPrice)');
      _logTrade(TradeLog(
        ticker: pending.symbol,
        action: TradeAction.skip,
        orderId: update.orderId,
        roundTripId: pending.roundTripId,
        executionStatus: TradeExecutionStatus.partialFill,
        executedAt: update.timestamp,
        reasoning: 'Sell filled but fill data incomplete (qty=$fillQty, price=$fillPrice)',
        signal: pending.signal,
        createdAt: pending.submittedAt,
      ));
      return;
    }

    final managed = _positionManager.getBySymbol(pending.symbol);
    double? entryPrice = (managed?.entryPrice ?? 0) > 0 ? managed!.entryPrice : null;
    if (entryPrice == null) {
      // Position record missing — fall back to the most recent buy log for this round-trip.
      entryPrice = _allLogs
          .where((l) =>
              l.ticker == pending.symbol &&
              l.action == TradeAction.buy &&
              l.roundTripId == pending.roundTripId &&
              (l.price ?? 0) > 0)
          .lastOrNull
          ?.price;
    }
    final String pnlStr;
    if (entryPrice != null && entryPrice > 0) {
      final pnl = (fillPrice - entryPrice) * fillQty;
      pnlStr = pnl >= 0
          ? '+\$${pnl.toStringAsFixed(2)}'
          : '-\$${pnl.abs().toStringAsFixed(2)}';
    } else {
      Log.w('PositionEngine', 'Entry price unavailable for ${pending.symbol} — P&L cannot be calculated');
      pnlStr = 'P&L unknown (entry price unavailable)';
    }

    _logTrade(TradeLog(
      ticker: pending.symbol,
      action: pending.action,
      qty: fillQty,
      price: fillPrice,
      orderId: update.orderId,
      roundTripId: pending.roundTripId,
      executionStatus: TradeExecutionStatus.filled,
      executedAt: update.timestamp,
      reasoning: '${pending.reason} | Fill @ \$${fillPrice.toStringAsFixed(2)} | P&L: $pnlStr',
      signal: pending.signal,
      createdAt: pending.submittedAt,
    ));

    if (pending.isFullClose) {
      if (pending.existingStopLossOrderId != null &&
          pending.existingStopLossOrderId != update.orderId) {
        try {
          await _alpacaClient.cancelOrder(pending.existingStopLossOrderId!);
        } catch (_) {}
      }
      await _positionManager.recordFullClose(pending.symbol);
      return;
    }

    await _positionManager.recordPartialSell(pending.symbol, fillQty);
    final updated = _positionManager.getBySymbol(pending.symbol);
    if (updated == null) return;

    if (updated.remainingQty > 0 && updated.stopLossOrderId != null) {
      final newStopPrice = updated.currentStopPrice ??
          updated.entryPrice * (1 - updated.exitRules.stopLossPercent);
      try {
        final newOrderId = await _orderExecutor.replaceStopLoss(
          oldOrderId: updated.stopLossOrderId,
          symbol: updated.symbol,
          qty: updated.remainingQty,
          newStopPrice: newStopPrice,
        );
        await _positionManager.updateStopLoss(
          updated.symbol,
          orderId: newOrderId,
          stopPrice: newStopPrice,
        );
      } on StopLossException catch (e) {
        Log.e('PositionEngine',
            'Stop-loss replace failed after partial sell for ${updated.symbol} — '
            'cancelling stale stop and placing fresh one',
            e);
        // The old stop order has the original (larger) qty. If it triggers in
        // this state Alpaca will reject it, leaving the position unprotected.
        // Cancel it, then place a correctly-sized replacement.
        if (updated.stopLossOrderId != null) {
          try {
            await _alpacaClient.cancelOrder(updated.stopLossOrderId!);
          } catch (_) {}
        }
        try {
          final freshOrderId = await _orderExecutor.setStopLoss(
            symbol: updated.symbol,
            stopPrice: newStopPrice,
            qty: updated.remainingQty,
          );
          await _positionManager.updateStopLoss(
            updated.symbol,
            orderId: freshOrderId,
            stopPrice: newStopPrice,
          );
          Log.i('PositionEngine',
              'Fresh stop-loss placed for ${updated.symbol} after replace failure');
        } on StopLossException catch (e2) {
          Log.e('PositionEngine',
              'CRITICAL: cannot place stop-loss for ${updated.symbol} after partial sell',
              e2);
          if (!_criticalAlertController.isClosed) {
            _criticalAlertController.add(
              'UNPROTECTED POSITION: ${updated.symbol} has no valid stop-loss '
              'after a partial sell. Please add a stop manually on Alpaca.',
            );
          }
        }
      }
    }
  }

  // --- Trailing Stop-Loss ---

  void _setupTrailingStopListener() {
    _priceSubscription = _priceStream.stream.listen(
      (update) {
        _handleTrailingStopUpdate(update).catchError((Object e) {
          Log.e('PositionEngine', 'Trailing stop error for ${update.symbol}', e);
          if (e is StopLossException && !_criticalAlertController.isClosed) {
            _criticalAlertController.add(
              'TRAILING STOP FAILED: ${update.symbol} stop-loss could not be updated. '
              'Position may be under-protected. Check Alpaca manually.',
            );
          }
        });
      },
      onError: (e) => Log.e('PositionEngine', 'Price stream error', e),
    );
  }

  Future<void> _handleTrailingStopUpdate(PriceUpdate update) async {
    final pos = _positionManager.getBySymbol(update.symbol);
    if (pos == null || !pos.exitRules.trailingStopEnabled) return;
    if (pos.currentStopPrice == null) return;

    // Throttle updates
    final lastUpdate = _lastTrailingUpdate[update.symbol];
    if (lastUpdate != null &&
        DateTime.now().difference(lastUpdate) < _trailingUpdateInterval) {
      return;
    }

    // Calculate new trailing stop
    final newStopPrice =
        update.price * (1 - pos.exitRules.trailingStopPercent);

    // Only move stop UP, never down — and require at least 0.5% increase
    if (newStopPrice <= pos.currentStopPrice!) return;
    final improvement =
        (newStopPrice - pos.currentStopPrice!) / pos.currentStopPrice!;
    if (improvement < 0.005) return;

    // Throws StopLossException on failure — propagates to the catchError in
    // _setupTrailingStopListener, which logs it. Old stop remains active.
    final newOrderId = await _orderExecutor.replaceStopLoss(
      oldOrderId: pos.stopLossOrderId,
      symbol: update.symbol,
      qty: pos.remainingQty,
      newStopPrice: newStopPrice,
    );
    await _positionManager.updateStopLoss(
      update.symbol,
      orderId: newOrderId,
      stopPrice: newStopPrice,
    );
    _lastTrailingUpdate[update.symbol] = DateTime.now();
    Log.i('PositionEngine', 'Trailing stop updated for ${update.symbol}: '
        '\$${pos.currentStopPrice!.toStringAsFixed(2)} → '
        '\$${newStopPrice.toStringAsFixed(2)}');
  }

  // --- Take-Profit ---

  Future<void> _checkTakeProfits() async {
    final managed = _positionManager.all;
    if (managed.isEmpty) return;

    List<Position> positions;
    try {
      positions = await _alpacaClient.getPositions();
    } catch (e) {
      Log.e('PositionEngine', 'Failed to fetch positions for take-profit', e);
      return;
    }

    for (final mp in managed) {
      if (mp.takeProfitTriggered) continue;

      final livePos = positions.where((p) => p.symbol == mp.symbol);
      if (livePos.isEmpty) continue;

      final currentPrice = livePos.first.currentPrice;
      if (mp.entryPrice <= 0) continue;
      final pnlPercent = (currentPrice - mp.entryPrice) / mp.entryPrice;

      if (pnlPercent >= mp.exitRules.takeProfitPercent) {
        final sellQty =
            (mp.remainingQty * mp.exitRules.takeProfitSellFraction)
                .floorToDouble();
        if (sellQty <= 0) continue;

        Log.i('PositionEngine', 'Take-profit triggered for ${mp.symbol}: '
            '+${(pnlPercent * 100).toStringAsFixed(1)}%, '
            'selling $sellQty shares');

        final dummySignal = Signal(
          ticker: mp.symbol,
          sentiment: Sentiment.bullish,
          confidence: 1.0,
          timeframe: Timeframe.short,
          reasoning: 'Take-profit at +${(pnlPercent * 100).toStringAsFixed(1)}%',
          sourceHeadlines: [],
          createdAt: DateTime.now(),
        );

        final log = await _orderExecutor.executePartialSell(
          symbol: mp.symbol,
          qty: sellQty,
          reason: 'Take-profit: +${(pnlPercent * 100).toStringAsFixed(1)}%, '
              'sold $sellQty of ${mp.remainingQty} shares',
          signal: dummySignal,
          action: TradeAction.takeProfitSell,
        );
        _logTrade(log);

        if (log.wasExecuted && log.orderId != null) {
          _pendingSellOrders[log.orderId!] = _PendingPositionSell(
            symbol: mp.symbol,
            action: TradeAction.takeProfitSell,
            signal: dummySignal,
            requestedQty: sellQty,
            submittedAt: log.createdAt,
            roundTripId: mp.buyOrderId,
            reason: log.reasoning,
            existingStopLossOrderId: mp.stopLossOrderId,
            isFullClose: false,
          );
        }
      }
    }
  }

  // --- Position Re-Evaluation ---

  Future<void> _reEvaluatePositions() async {
    final toEval = _positionManager
        .getNeedingReEvaluation(const Duration(hours: 4));
    if (toEval.isEmpty) return;

    List<Position> positions;
    try {
      positions = await _alpacaClient.getPositions();
    } catch (e) {
      Log.e('PositionEngine', 'Failed to fetch positions for re-eval', e);
      return;
    }

    final contexts = <PositionContext>[];
    for (final mp in toEval) {
      final livePos = positions.where((p) => p.symbol == mp.symbol);
      if (livePos.isEmpty) {
        // Position was closed externally
        await _positionManager.recordFullClose(mp.symbol);
        continue;
      }

      final pos = livePos.first;
      contexts.add(PositionContext(
        symbol: mp.symbol,
        entryPrice: mp.entryPrice,
        currentPrice: pos.currentPrice,
        pnlPercent: pos.unrealizedPnLPercent * 100,
        holdDays: mp.holdDays,
        maxHoldDays: mp.exitRules.maxHoldDays,
      ));
    }

    if (contexts.isEmpty) return;

    Log.i('PositionEngine', 'Re-evaluating ${contexts.length} positions');

    final evaluations = await _claudeClient.evaluatePositions(contexts);

    for (final eval in evaluations) {
      final mp = _positionManager.getBySymbol(eval.ticker);
      if (mp == null) continue;

      await _positionManager.markReEvaluated(eval.ticker);

      // Force-sell if way overdue regardless of Claude's opinion
      final forceSell = mp.isWayOverdue;

      if (forceSell) {
        Log.w('PositionEngine',
            'Force-selling ${eval.ticker} — bypassing risk checks (safety exit for overdue position)');
      }

      if (forceSell || (eval.shouldSell && eval.confidence >= _riskManager.config.reEvalSellConfidence)) {
        final action = forceSell ? TradeAction.timeExit : TradeAction.reEvalSell;
        final reason = forceSell
            ? 'Force exit: held ${mp.holdDays}d (2x over ${mp.exitRules.maxHoldDays}d limit)'
            : 'Re-eval sell (${(eval.confidence * 100).toStringAsFixed(0)}%): ${eval.reasoning}';

        Log.i('PositionEngine', 'Selling ${eval.ticker}: $reason');

        final dummySignal = Signal(
          ticker: eval.ticker,
          sentiment: Sentiment.bearish,
          confidence: eval.confidence,
          timeframe: Timeframe.short,
          reasoning: reason,
          sourceHeadlines: [],
          createdAt: DateTime.now(),
        );

        final log = await _orderExecutor.executeSell(signal: dummySignal);
        _logTrade(log.copyWith(action: action, reasoning: reason));

        if (log.wasExecuted && log.orderId != null) {
          _pendingSellOrders[log.orderId!] = _PendingPositionSell(
            symbol: eval.ticker,
            action: action,
            signal: dummySignal,
            requestedQty: mp.remainingQty,
            submittedAt: log.createdAt,
            roundTripId: mp.buyOrderId,
            reason: reason,
            existingStopLossOrderId: mp.stopLossOrderId,
            isFullClose: true,
          );
        }
      } else {
        _logTrade(TradeLog(
          ticker: eval.ticker,
          action: TradeAction.skip,
          reasoning: 'Re-eval hold: ${eval.reasoning}',
          signal: Signal(
            ticker: eval.ticker,
            sentiment: Sentiment.neutral,
            confidence: eval.confidence,
            timeframe: Timeframe.medium,
            reasoning: eval.reasoning,
            sourceHeadlines: [],
            createdAt: DateTime.now(),
          ),
          createdAt: DateTime.now(),
        ));
      }
    }
  }

  // --- Helpers ---

  void _watchManagedSymbols() {
    final symbols = _positionManager.all.map((p) => p.symbol).toList();
    if (symbols.isNotEmpty) {
      _priceStream.watchSymbols(symbols);
    }
  }

  void _logTrade(TradeLog log) {
    _allLogs.add(log);
    _store?.saveTrade(log).catchError((e) {
      Log.e('PositionEngine', 'Failed to persist trade log for ${log.ticker}', e);
    });
  }

  void _updateStatus(EngineStatus newStatus) {
    _status = newStatus;
    if (!_statusController.isClosed) {
      _statusController.add(newStatus);
    }
  }

  void dispose() {
    stop(); // cancels _timer and _retryTimer
    _fillSubscription?.cancel();
    _priceSubscription?.cancel();
    _statusController.close();
    _criticalAlertController.close();
  }
}

class _PendingPositionBuy {
  final Signal signal;
  final DateTime submittedAt;
  final String roundTripId;
  double? filledQty;
  double? filledAvgPrice;

  _PendingPositionBuy({
    required this.signal,
    required this.submittedAt,
    required this.roundTripId,
  }) : filledQty = null, filledAvgPrice = null;
}

class _PendingPositionSell {
  final String symbol;
  final TradeAction action;
  final Signal signal;
  final double? requestedQty;
  final DateTime submittedAt;
  final String roundTripId;
  final String reason;
  final String? existingStopLossOrderId;
  final bool isFullClose;
  double? filledQty;
  double? filledAvgPrice;

  _PendingPositionSell({
    required this.symbol,
    required this.action,
    required this.signal,
    required this.requestedQty,
    required this.submittedAt,
    required this.roundTripId,
    required this.reason,
    required this.existingStopLossOrderId,
    required this.isFullClose,
  }) : filledQty = null, filledAvgPrice = null;
}

TradeExecutionStatus? _executionStatusFor(OrderEvent event) {
  return switch (event) {
    OrderEvent.canceled => TradeExecutionStatus.canceled,
    OrderEvent.rejected => TradeExecutionStatus.rejected,
    OrderEvent.expired => TradeExecutionStatus.expired,
    OrderEvent.partialFill => TradeExecutionStatus.partialFill,
    OrderEvent.fill => TradeExecutionStatus.filled,
    OrderEvent.newOrder => TradeExecutionStatus.submitted,
  };
}
