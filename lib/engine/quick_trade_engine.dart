import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/api/trading_exception.dart';
import 'package:morex/core/logger.dart';
import 'package:morex/engine/account_lock.dart';
import 'package:morex/core/models/position.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/db/hive_store.dart';
import 'package:morex/engine/order_monitor.dart';
import 'package:morex/engine/price_stream.dart';
import 'package:morex/engine/risk_manager.dart';
import 'package:morex/engine/trading_lock.dart';

enum EntryType { dip, breakout, maCrossover }

class QuickTradeConfig {
  final double budgetPercent;
  final double maxOrderDollars;
  final int maxOpenPositions;
  final int priceWindowSize;
  final int cooldownSeconds;

  // -- Adaptive thresholds (base values, adjusted by history) --
  final double baseDipThreshold;
  final double baseBreakoutThreshold;
  final double baseTakeProfitPercent;
  final double baseStopLossPercent;
  final int baseMaxHoldSeconds;

  // -- Momentum / volume --
  final int momentumWindow;
  final double volumeSpikeMultiplier;

  // -- RSI --
  final int rsiPeriod;
  final double rsiOverbought; // don't enter above this
  final double rsiOversold; // dip filter: prefer below this

  // -- Moving averages --
  final int maShortPeriod;
  final int maLongPeriod;

  // -- Session risk --
  final double maxSessionLossPercent;
  final int maxConsecutiveLosses;

  // -- Limit-order entries --
  // When true, entries submit a marketable LIMIT order at currentPrice
  // (1 + slippageBuffer) with whole-share qty (qty = floor(dollars/price)).
  // Prevents surprise slippage on volatile names and produces only whole-
  // share positions (which can have broker-side stops on live Alpaca).
  // When false (default), legacy market+notional behavior is used, which
  // creates fractional positions managed by the in-process exit engine.
  final bool useLimitEntries;
  final double limitSlippageBuffer;

  const QuickTradeConfig({
    this.budgetPercent = 0.10,
    this.baseDipThreshold = 0.015, // 1.5% — more realistic for intraday
    this.baseBreakoutThreshold = 0.015,
    this.baseTakeProfitPercent = 0.015,
    this.baseStopLossPercent = 0.01,
    this.baseMaxHoldSeconds = 300,
    this.maxOpenPositions = 3,
    this.priceWindowSize = 60,
    this.cooldownSeconds = 60, // 1 min cooldown — was 2 min
    this.maxOrderDollars = 500,
    this.momentumWindow = 20,
    this.volumeSpikeMultiplier = 1.5,
    this.rsiPeriod = 14,
    this.rsiOverbought = 70,
    this.rsiOversold = 60, // 60 — allows dip entry during mild pullbacks in uptrend
    this.maShortPeriod = 5,  // faster signal — was 10
    this.maLongPeriod = 20,  // faster signal — was 30
    this.maxSessionLossPercent = 0.03,
    this.maxConsecutiveLosses = 3,
    this.useLimitEntries = false,
    this.limitSlippageBuffer = 0.001,
  });
}

class QuickTradePosition {
  final String symbol;
  double entryPrice;
  double qty;
  final String orderId;
  final String roundTripId;
  final DateTime entryTime;
  final EntryType entryType;
  double stopPrice;
  double targetPrice;
  double trailingHigh;
  String? stopLossOrderId;

  QuickTradePosition({
    required this.symbol,
    required this.entryPrice,
    required this.qty,
    required this.orderId,
    required this.roundTripId,
    required this.entryTime,
    required this.entryType,
    required this.stopPrice,
    required this.targetPrice,
    required this.trailingHigh,
    this.stopLossOrderId,
  });

  int get holdSeconds => DateTime.now().difference(entryTime).inSeconds;
  double pnlPercent(double currentPrice) =>
      entryPrice == 0 ? 0 : (currentPrice - entryPrice) / entryPrice;
  bool get isProtected => stopLossOrderId != null;
}

enum QuickTradeEngineState { stopped, running }

class QuickTradeStatus {
  final QuickTradeEngineState state;
  final double budgetUsed;
  final double budgetLimit;
  final int openPositions;
  final int totalTrades;
  final double sessionPnL;
  final List<TradeLog> recentLogs;
  final String? lastError;
  final DateTime? updatedAt;

  const QuickTradeStatus({
    this.state = QuickTradeEngineState.stopped,
    this.budgetUsed = 0,
    this.budgetLimit = 0,
    this.openPositions = 0,
    this.totalTrades = 0,
    this.sessionPnL = 0,
    this.recentLogs = const [],
    this.lastError,
    this.updatedAt,
  });

  QuickTradeStatus copyWith({
    QuickTradeEngineState? state,
    double? budgetUsed,
    double? budgetLimit,
    int? openPositions,
    int? totalTrades,
    double? sessionPnL,
    List<TradeLog>? recentLogs,
    String? lastError,
    DateTime? updatedAt,
  }) {
    return QuickTradeStatus(
      state: state ?? this.state,
      budgetUsed: budgetUsed ?? this.budgetUsed,
      budgetLimit: budgetLimit ?? this.budgetLimit,
      openPositions: openPositions ?? this.openPositions,
      totalTrades: totalTrades ?? this.totalTrades,
      sessionPnL: sessionPnL ?? this.sessionPnL,
      recentLogs: recentLogs ?? this.recentLogs,
      lastError: lastError ?? this.lastError,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class QuickTradeEntryAnalytics {
  final EntryType entryType;
  final int rounds;
  final int wins;
  final int losses;
  final double netPnl;
  final double avgPnl;
  final double avgWin;
  final double avgLoss;

  const QuickTradeEntryAnalytics({
    required this.entryType,
    this.rounds = 0,
    this.wins = 0,
    this.losses = 0,
    this.netPnl = 0,
    this.avgPnl = 0,
    this.avgWin = 0,
    this.avgLoss = 0,
  });

  double get winRate => rounds == 0 ? 0 : wins / rounds;
}

class QuickTradeAnalytics {
  final int rounds;
  final int wins;
  final int losses;
  final double netPnl;
  final double avgPnl;
  final double avgWin;
  final double avgLoss;
  final Map<EntryType, QuickTradeEntryAnalytics> byEntryType;
  final Map<String, QuickTradeEntryAnalytics> bySymbol;

  const QuickTradeAnalytics({
    this.rounds = 0,
    this.wins = 0,
    this.losses = 0,
    this.netPnl = 0,
    this.avgPnl = 0,
    this.avgWin = 0,
    this.avgLoss = 0,
    this.byEntryType = const {},
    this.bySymbol = const {},
  });

  double get winRate => rounds == 0 ? 0 : wins / rounds;
  double get expectancy => avgPnl;
  // Cap at 99 to avoid infinity in JSON serialisation and UI display.
  double get profitFactor => avgLoss == 0
      ? (avgWin > 0 ? 99.0 : 0)
      : avgWin / avgLoss.abs();

  bool get hasData => rounds > 0;

  static QuickTradeAnalytics fromTradeLogs(List<TradeLog> logs) {
    final ordered = List<TradeLog>.from(logs)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final openBuys = <String, TradeLog>{};
    final completed = <_CompletedRound>[];

    for (final log in ordered) {
      if (_isExecutionEligible(log) && log.action == TradeAction.buy) {
        openBuys[log.roundTripId ?? log.ticker] = log;
        continue;
      }

      if (!_isExecutionEligible(log) || log.action == TradeAction.skip)
        continue;

      final buy = openBuys.remove(log.roundTripId ?? log.ticker);
      if (buy == null || buy.price == null || log.price == null) continue;

      final qty = log.qty ?? buy.qty;
      if (qty == null || qty <= 0) continue;

      completed.add(
        _CompletedRound(
          entryType: _inferEntryType(buy),
          pnl: (log.price! - buy.price!) * qty,
          symbol: log.ticker,
        ),
      );
    }

    if (completed.isEmpty) return const QuickTradeAnalytics();

    final wins = completed.where((r) => r.pnl > 0).toList();
    final losses = completed.where((r) => r.pnl <= 0).toList();

    final byEntryType = <EntryType, QuickTradeEntryAnalytics>{};
    for (final entryType in EntryType.values) {
      final rounds = completed.where((r) => r.entryType == entryType).toList();
      if (rounds.isEmpty) continue;
      final roundWins = rounds.where((r) => r.pnl > 0).toList();
      final roundLosses = rounds.where((r) => r.pnl <= 0).toList();
      byEntryType[entryType] = QuickTradeEntryAnalytics(
        entryType: entryType,
        rounds: rounds.length,
        wins: roundWins.length,
        losses: roundLosses.length,
        netPnl: rounds.fold(0.0, (sum, round) => sum + round.pnl),
        avgPnl:
            rounds.fold(0.0, (sum, round) => sum + round.pnl) / rounds.length,
        avgWin: roundWins.isEmpty
            ? 0
            : roundWins.fold(0.0, (sum, round) => sum + round.pnl) /
                  roundWins.length,
        avgLoss: roundLosses.isEmpty
            ? 0
            : roundLosses.fold(0.0, (sum, round) => sum + round.pnl) /
                  roundLosses.length,
      );
    }

    return QuickTradeAnalytics(
      rounds: completed.length,
      wins: wins.length,
      losses: losses.length,
      netPnl: completed.fold(0.0, (sum, round) => sum + round.pnl),
      avgPnl:
          completed.fold(0.0, (sum, round) => sum + round.pnl) /
          completed.length,
      avgWin: wins.isEmpty
          ? 0
          : wins.fold(0.0, (sum, round) => sum + round.pnl) / wins.length,
      avgLoss: losses.isEmpty
          ? 0
          : losses.fold(0.0, (sum, round) => sum + round.pnl) / losses.length,
      byEntryType: byEntryType,
      bySymbol: _buildBySymbol(completed),
    );
  }

  static Map<String, QuickTradeEntryAnalytics> _buildBySymbol(List<_CompletedRound> completed) {
    final symbols = completed.map((r) => r.symbol).toSet();
    final result = <String, QuickTradeEntryAnalytics>{};
    for (final sym in symbols) {
      final rounds = completed.where((r) => r.symbol == sym).toList();
      final w = rounds.where((r) => r.pnl > 0).toList();
      final l = rounds.where((r) => r.pnl <= 0).toList();
      result[sym] = QuickTradeEntryAnalytics(
        entryType: rounds.first.entryType,
        rounds: rounds.length,
        wins: w.length,
        losses: l.length,
        netPnl: rounds.fold(0.0, (s, r) => s + r.pnl),
        avgPnl: rounds.fold(0.0, (s, r) => s + r.pnl) / rounds.length,
        avgWin: w.isEmpty ? 0 : w.fold(0.0, (s, r) => s + r.pnl) / w.length,
        avgLoss: l.isEmpty ? 0 : l.fold(0.0, (s, r) => s + r.pnl) / l.length,
      );
    }
    return result;
  }

  static EntryType _inferEntryType(TradeLog buy) {
    final reasoning = buy.reasoning.toLowerCase();
    final signalReasoning = buy.signal.reasoning.toLowerCase();

    if (reasoning.startsWith('dip buy') || signalReasoning.contains('dip')) {
      return EntryType.dip;
    }
    if (reasoning.startsWith('breakout buy') ||
        signalReasoning.contains('breakout')) {
      return EntryType.breakout;
    }
    return EntryType.maCrossover;
  }

  static bool _isExecutionEligible(TradeLog log) {
    if (log.action == TradeAction.skip || log.price == null) return false;
    if (log.executionStatus == TradeExecutionStatus.submitted) return false;
    return true;
  }
}

// ---------------------------------------------------------------------------
// Per-symbol stats derived from trade history
// ---------------------------------------------------------------------------

class _SymbolStats {
  final int totalTrades;
  final int wins;
  final int losses;
  final double avgWinPercent;
  final double avgLossPercent;
  final double avgHoldSeconds;
  final double bestDipEntry;

  const _SymbolStats({
    this.totalTrades = 0,
    this.wins = 0,
    this.losses = 0,
    this.avgWinPercent = 0,
    this.avgLossPercent = 0,
    this.avgHoldSeconds = 0,
    this.bestDipEntry = 0,
  });

  double get winRate => totalTrades > 0 ? wins / totalTrades : 0.5;
}

// ---------------------------------------------------------------------------
// Quick Trade Engine — history-aware, adaptive strategy
// ---------------------------------------------------------------------------

class QuickTradeEngine {
  final AlpacaClient _client;
  final PriceStream _priceStream;
  final HiveStore _store;
  final OrderMonitor _orderMonitor;
  final RiskManager _riskManager;
  final TradingLock _tradingLock;
  final AccountLock _accountLock;
  final QuickTradeConfig config;

  final Map<String, QuickTradePosition> _openPositions = {};
  final Map<String, Queue<double>> _priceWindows = {};
  final Map<String, double> _rollingHighs = {};
  final Map<String, double> _rollingLows = {};
  final Map<String, DateTime> _cooldowns = {};
  final List<TradeLog> _logs = [];
  final Set<String> _watchedSymbols = {};
  final Map<String, _PendingQuickTradeBuy> _pendingBuys = {};
  final Map<String, _PendingQuickTradeSell> _pendingSells = {};
  final Set<String> _symbolsClosing = {};
  final Set<String> _symbolsUpdatingProtection = {};

  // History-derived intelligence
  Map<String, _SymbolStats> _symbolStats = {};
  Set<String> _blacklist = {};
  int _consecutiveLosses = 0;

  // Volume tracking for spike detection
  final Map<String, Queue<double>> _volumeWindows = {};

  // Symbols currently being submitted (to prevent TOCTOU race in _checkEntry)
  final Set<String> _submittingSymbols = {};

  // VWAP accumulators (reset each session)
  final Map<String, double> _vwapCumPriceVol = {};
  final Map<String, double> _vwapCumVol = {};

  // MA crossover: previous tick's MAs for crossover detection
  final Map<String, double> _prevShortMa = {};
  final Map<String, double> _prevLongMa = {};

  double _budgetLimit = 0;
  double _budgetUsed = 0;
  double _sessionPnL = 0;
  int _totalTrades = 0;
  double _accountEquity = 0;

  StreamSubscription? _priceSubscription;
  StreamSubscription? _orderSubscription;
  Timer? _expiryTimer;
  Timer? _accountRefreshTimer;
  Timer? _rotationTimer;

  // Full watchlist for rotation; only a window of 25 is active at a time
  List<String> _fullWatchlist = [];
  int _watchlistOffset = 0;

  QuickTradeStatus _status = const QuickTradeStatus();
  final _statusController = StreamController<QuickTradeStatus>.broadcast();

  Stream<QuickTradeStatus> get statusStream => _statusController.stream;
  QuickTradeStatus get status => _status;
  List<TradeLog> get logs => List.unmodifiable(_logs);

  QuickTradeEngine({
    required AlpacaClient client,
    required PriceStream priceStream,
    required HiveStore store,
    required OrderMonitor orderMonitor,
    required TradingLock tradingLock,
    required RiskManager riskManager,
    required AccountLock accountLock,
    this.config = const QuickTradeConfig(),
  }) : _client = client,
       _priceStream = priceStream,
       _store = store,
       _orderMonitor = orderMonitor,
       _tradingLock = tradingLock,
       _riskManager = riskManager,
       _accountLock = accountLock {
    _orderSubscription = _orderMonitor.stream.listen((update) {
      _handleOrderUpdate(update).catchError((e) {
        Log.e('QuickTradeEngine', 'Order update handling failed', e);
      });
    }, onError: (e) => Log.e('QuickTradeEngine', 'Order stream failed', e));
  }

  Future<void> start(List<String> watchlist, {double? budgetDollars}) async {
    if (_status.state == QuickTradeEngineState.running) return;

    try {
      final account = await _client.getAccount();
      _accountEquity = account.equity;
      _budgetLimit = budgetDollars != null
          ? budgetDollars.clamp(0.0, account.equity)
          : account.equity * config.budgetPercent;
      _budgetUsed = 0;
      _sessionPnL = 0;
      _totalTrades = 0;
      _consecutiveLosses = 0;
      _logs.clear();
      _openPositions.clear();
      _pendingBuys.clear();
      _pendingSells.clear();
      _symbolsClosing.clear();
      _priceWindows.clear();
      _rollingHighs.clear();
      _rollingLows.clear();
      _cooldowns.clear();
      _volumeWindows.clear();
      _vwapCumPriceVol.clear();
      _vwapCumVol.clear();
      _prevShortMa.clear();
      _prevLongMa.clear();

      final quickTradeHistory = _loadQuickTradeHistory(limit: 500);
      final recentHistory = quickTradeHistory.take(20).toList().reversed;
      _logs.addAll(recentHistory);

      // Load trade history and build per-symbol intelligence
      _buildSymbolStats(quickTradeHistory);

      // Filter out consistently losing symbols
      _blacklist = _symbolStats.entries
          .where((e) => e.value.totalTrades >= 5 && e.value.winRate < 0.30)
          .map((e) => e.key)
          .toSet();

      await _reconcileOpenExecutionState(watchlist, quickTradeHistory);
      await _reconcilePendingFills();

      _priceStream.start();
      _fullWatchlist = watchlist.toList();
      _watchlistOffset = 0;
      if (_watchedSymbols.isNotEmpty) {
        _priceStream.unwatchSymbols(_watchedSymbols.toList());
        _watchedSymbols.clear();
      }
      _applyWatchlistWindow();
      _priceSubscription = _priceStream.stream.listen(_onPriceTick);
      _expiryTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _checkExpiredPositions(),
      );
      _accountRefreshTimer = Timer.periodic(
        const Duration(minutes: 5),
        (_) => unawaited(_refreshAccountState()),
      );
      if (_fullWatchlist.length > PriceStream.maxSubscribableSymbols) {
        _rotationTimer = Timer.periodic(
          const Duration(minutes: 2),
          (_) => _rotateWatchlistWindow(),
        );
      }

      _updateStatus(
        _status.copyWith(
          state: QuickTradeEngineState.running,
          budgetLimit: _budgetLimit,
          budgetUsed: _budgetUsed,
          openPositions: _openPositions.length,
          totalTrades: _totalTrades,
          sessionPnL: _sessionPnL,
          recentLogs: _logs.reversed.take(20).toList(),
          lastError: null,
        ),
      );

      final blacklistNote = _blacklist.isNotEmpty
          ? ', blacklisted: ${_blacklist.join(', ')}'
          : '';
      Log.i(
        'QuickTradeEngine',
        'Started — budget \$${_budgetLimit.toStringAsFixed(2)}, '
            'watching ${watchlist.length} symbols$blacklistNote',
      );
    } catch (e) {
      _updateStatus(_status.copyWith(lastError: 'Failed to start: $e'));
    }
  }

  void stop() {
    _priceSubscription?.cancel();
    _priceSubscription = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _accountRefreshTimer?.cancel();
    _accountRefreshTimer = null;
    _rotationTimer?.cancel();
    _rotationTimer = null;
    if (_watchedSymbols.isNotEmpty) {
      _priceStream.unwatchSymbols(_watchedSymbols.toList());
      _watchedSymbols.clear();
    }

    for (final pending in _pendingBuys.values.toList()) {
      unawaited(_cancelPendingBuy(pending));
    }

    for (final pos in _openPositions.values.toList()) {
      unawaited(_requestClosePosition(pos, 'Engine stopped'));
    }

    _updateStatus(_status.copyWith(state: QuickTradeEngineState.stopped));
    Log.i(
      'QuickTradeEngine',
      'Stopped — session P&L: '
          '\$${_sessionPnL.toStringAsFixed(2)}, trades: $_totalTrades',
    );
  }

  /// Refresh account equity and recalculate budget limits (called every 5 minutes).
  void _applyWatchlistWindow() {
    final cap = PriceStream.maxSubscribableSymbols;
    final end = (_watchlistOffset + cap).clamp(0, _fullWatchlist.length);
    final window = _fullWatchlist.sublist(_watchlistOffset, end);
    // Wrap around if window is too small
    final wrapped = window.length < cap && _fullWatchlist.length > cap
        ? window + _fullWatchlist.sublist(0, cap - window.length)
        : window;
    final newSet = wrapped.toSet();
    final toRemove = _watchedSymbols.difference(newSet).toList();
    final toAdd = newSet.difference(_watchedSymbols).toList();
    if (toRemove.isNotEmpty) _priceStream.unwatchSymbols(toRemove);
    if (toAdd.isNotEmpty) _priceStream.watchSymbols(toAdd);
    _watchedSymbols
      ..removeAll(toRemove)
      ..addAll(toAdd);
  }

  void _rotateWatchlistWindow() {
    // Always keep symbols with open positions in the window
    final cap = PriceStream.maxSubscribableSymbols;
    _watchlistOffset = (_watchlistOffset + cap) % _fullWatchlist.length;
    _applyWatchlistWindow();
    Log.d('QuickTradeEngine', 'Watchlist rotated — offset $_watchlistOffset/${_fullWatchlist.length}');
  }

  Future<void> _refreshAccountState() async {
    try {
      final account = await _client.getAccount();
      final oldEquity = _accountEquity;
      _accountEquity = account.equity;

      final newBudgetLimit = account.equity * config.budgetPercent;
      if (newBudgetLimit != _budgetLimit) {
        Log.d(
          'QuickTradeEngine',
          'Account equity updated: \$${oldEquity.toStringAsFixed(2)} → \$${_accountEquity.toStringAsFixed(2)}, '
              'budget limit: \$${_budgetLimit.toStringAsFixed(2)} → \$${newBudgetLimit.toStringAsFixed(2)}',
        );
        _budgetLimit = newBudgetLimit;
      }

      if (_budgetUsed > _budgetLimit) {
        Log.w(
          'QuickTradeEngine',
          'Budget exceeded: used \$${_budgetUsed.toStringAsFixed(2)} / limit \$${_budgetLimit.toStringAsFixed(2)}',
        );
      }
    } catch (e) {
      Log.e('QuickTradeEngine', 'Failed to refresh account state', e);
      _updateStatus(_status.copyWith(lastError: 'Account refresh failed: $e'));
    }

    // Reconcile any fills missed while WebSocket was disconnected
    if (_pendingBuys.isNotEmpty || _pendingSells.isNotEmpty) {
      await _reconcilePendingFills();
    }

    // Release budget reserved by buy orders stuck in partial-fill for >10 min.
    // Alpaca keeps orders in partially_filled indefinitely until fully filled,
    // cancelled, or expired. Without this sweep, _budgetUsed grows permanently.
    await _sweepStuckPendingBuys();
  }

  /// Cancels and finalises buy orders that have been stuck in pending/partial-fill
  /// state for more than 10 minutes without receiving a terminal event.
  Future<void> _sweepStuckPendingBuys() async {
    const timeout = Duration(minutes: 10);
    final now = DateTime.now();
    final stuck = _pendingBuys.entries
        .where((e) => now.difference(e.value.submittedAt) > timeout)
        .toList();

    for (final entry in stuck) {
      final orderId = entry.key;
      final pending = entry.value;
      _pendingBuys.remove(orderId);

      if (pending.accountedQty > 0) {
        // There was a partial fill — treat it as the final fill, release
        // the difference between reserved and actual cost.
        _budgetUsed += pending.accountedCost - pending.reservedDollars;
        if (_budgetUsed < 0) _budgetUsed = 0;
        Log.w('QuickTradeEngine',
            'Stuck partial buy finalised for ${pending.symbol} '
            '(${pending.accountedQty} shares after ${timeout.inMinutes}min)');
      } else {
        // No fill received. Cancel on Alpaca BEFORE releasing budget.
        // If the cancel fails, the order may have already filled silently
        // (WebSocket gap) — restore it to _pendingBuys and reconcile so the
        // fill is picked up. Budget is only freed once cancel is confirmed.
        bool cancelled = false;
        try {
          await _client.cancelOrder(orderId);
          cancelled = true;
        } catch (e) {
          Log.w('QuickTradeEngine',
              'Cancel failed for stuck order $orderId — may have filled silently; '
              'restoring to pending and triggering reconciliation: $e');
          _pendingBuys[orderId] = pending;
          unawaited(_reconcilePendingFills());
        }
        if (cancelled) {
          _budgetUsed -= pending.reservedDollars;
          if (_budgetUsed < 0) _budgetUsed = 0;
          Log.w('QuickTradeEngine',
              'Stuck pending buy cancelled for ${pending.symbol} '
              '(no fill after ${timeout.inMinutes}min)');
          _logTrade(TradeLog(
            ticker: pending.symbol,
            action: TradeAction.skip,
            orderId: orderId,
            roundTripId: pending.roundTripId,
            executionStatus: TradeExecutionStatus.expired,
            executedAt: now,
            reasoning: 'Buy order timed out after ${timeout.inMinutes}min with no fill',
            signal: _buildSignal(pending.symbol, pending.signalDescription),
            createdAt: pending.submittedAt,
          ));
        }
      }
      _refreshStatus();
    }
  }

  // ---------------------------------------------------------------------------
  // History analysis
  // ---------------------------------------------------------------------------

  List<TradeLog> _loadQuickTradeHistory({int limit = 500}) {
    return _store
        .getTrades(limit: limit)
        .where((log) => log.roundTripId != null)
        .toList();
  }

  void _buildSymbolStats(List<TradeLog> history) {
    final Map<String, List<_TradeRound>> rounds = {};

    // Pair up buy/sell rounds per symbol
    final openBuys = <String, TradeLog>{};
    for (final log in history) {
      if (log.action == TradeAction.buy && log.price != null) {
        if (!_isHistoryEligible(log)) continue;
        openBuys[log.roundTripId ?? log.ticker] = log;
      } else if (_isHistoryEligible(log) && log.action != TradeAction.buy) {
        final buyLog = openBuys.remove(log.roundTripId ?? log.ticker);
        if (buyLog != null && buyLog.price != null && log.price != null) {
          rounds.putIfAbsent(log.ticker, () => []);
          rounds[log.ticker]!.add(
            _TradeRound(
              entryPrice: buyLog.price!,
              exitPrice: log.price!,
              holdSeconds: log.createdAt.difference(buyLog.createdAt).inSeconds,
            ),
          );
        }
      }
    }

    _symbolStats = rounds.map((symbol, tradeRounds) {
      final wins = tradeRounds.where((r) => r.pnlPercent > 0).toList();
      final losses = tradeRounds.where((r) => r.pnlPercent <= 0).toList();

      return MapEntry(
        symbol,
        _SymbolStats(
          totalTrades: tradeRounds.length,
          wins: wins.length,
          losses: losses.length,
          avgWinPercent: wins.isNotEmpty
              ? wins.map((r) => r.pnlPercent).reduce((a, b) => a + b) /
                    wins.length
              : 0,
          avgLossPercent: losses.isNotEmpty
              ? losses.map((r) => r.pnlPercent).reduce((a, b) => a + b) /
                    losses.length
              : 0,
          avgHoldSeconds: tradeRounds.isNotEmpty
              ? tradeRounds
                        .map((r) => r.holdSeconds.toDouble())
                        .reduce((a, b) => a + b) /
                    tradeRounds.length
              : 0,
          bestDipEntry: _findBestDipEntry(wins),
        ),
      );
    });
  }

  double _findBestDipEntry(List<_TradeRound> wins) {
    if (wins.isEmpty) return 0;
    // The average dip depth of winning trades = good entry threshold
    final avgDip =
        wins.map((r) => r.pnlPercent).reduce((a, b) => a + b) / wins.length;
    return avgDip;
  }

  Future<void> _reconcileOpenExecutionState(
    List<String> watchlist,
    List<TradeLog> quickTradeHistory,
  ) async {
    final protectedSymbols = _store
        .getManagedPositions()
        .map((pos) => pos.symbol)
        .toSet();
    final watchlistSet = watchlist.toSet();

    final positions = await _safeGetPositions();
    final openOrders = await _safeGetOpenOrders();
    final rounds = _buildRoundSnapshots(quickTradeHistory);
    final stopOrdersBySymbol = <String, String>{};

    for (final order in openOrders) {
      final symbol = '${order['symbol'] ?? ''}'.toUpperCase();
      final side = '${order['side'] ?? ''}'.toLowerCase();
      final type = '${order['type'] ?? ''}'.toLowerCase();
      final orderId = '${order['id'] ?? ''}';
      if (symbol.isEmpty || orderId.isEmpty) continue;
      if (side == 'sell' && (type == 'stop' || type == 'stop_limit')) {
        stopOrdersBySymbol[symbol] = orderId;
      }
    }

    _sessionPnL = _restoreSessionPnl(quickTradeHistory);
    _totalTrades = _restoreSessionTradeCount(quickTradeHistory);

    for (final position in positions) {
      if (position.side != 'long') continue;
      if (!watchlistSet.contains(position.symbol)) continue;
      if (protectedSymbols.contains(position.symbol)) continue;
      if (position.avgEntryPrice <= 0) {
        Log.w('QuickTradeEngine',
            'Skipping recovery for ${position.symbol}: invalid entry price ${position.avgEntryPrice}');
        continue;
      }

      final round =
          rounds[position.symbol] ??
          _RecoveredRound(
            roundTripId: '${position.symbol}_recovered_position',
            symbol: position.symbol,
            buyOrderId: null,
            entryPrice: position.avgEntryPrice,
            entryTime: DateTime.now(),
            entryType: EntryType.maCrossover,
            entryReasoning: 'Recovered broker position',
            signalReasoning: 'Recovered from broker position snapshot',
            isClosed: false,
          );

      _openPositions[position.symbol] = QuickTradePosition(
        symbol: position.symbol,
        entryPrice: position.avgEntryPrice,
        qty: position.qty,
        orderId: round.buyOrderId ?? round.roundTripId,
        roundTripId: round.roundTripId,
        entryTime: round.entryTime ?? DateTime.now(),
        entryType: round.entryType,
        stopPrice:
            position.avgEntryPrice * (1 - _stopLossPercent(position.symbol)),
        targetPrice:
            position.avgEntryPrice * (1 + _takeProfitPercent(position.symbol)),
        trailingHigh: max(position.avgEntryPrice, position.currentPrice),
        stopLossOrderId: stopOrdersBySymbol[position.symbol],
      );
      _budgetUsed += position.avgEntryPrice * position.qty;
      _rollingHighs[position.symbol] = position.currentPrice;
    }

    for (final order in openOrders) {
      final symbol = '${order['symbol'] ?? ''}'.toUpperCase();
      if (symbol.isEmpty) continue;
      if (!watchlistSet.contains(symbol)) continue;
      if (protectedSymbols.contains(symbol)) continue;

      final side = '${order['side'] ?? ''}'.toLowerCase();
      final orderId = '${order['id'] ?? ''}';
      if (orderId.isEmpty) continue;

      final round = rounds[symbol];
      final entryType = round?.entryType ?? EntryType.maCrossover;
      final timestamp =
          _parseOrderTimestamp(
            order['submitted_at'] ?? order['created_at'] ?? order['updated_at'],
          ) ??
          DateTime.now();
      final filledQty = _toDouble(order['filled_qty']) ?? 0;
      final filledAvgPrice = _toDouble(order['filled_avg_price']);
      final qty = _toDouble(order['qty']);
      final notional = _toDouble(order['notional']);
      final double inferredReserved;
      if (filledAvgPrice == null && (qty ?? 0) == 0) {
        Log.w('QuickTradeEngine', 'Recovered buy order for $symbol has no price or qty; inferredReserved=0');
        inferredReserved = 0;
      } else {
        inferredReserved = notional ??
            ((qty ?? filledQty) * (filledAvgPrice ?? round?.entryPrice ?? 0));
      }

      if (side == 'buy') {
        final pending = _PendingQuickTradeBuy(
          symbol: symbol,
          orderId: orderId,
          roundTripId: round?.roundTripId ?? '${symbol}_recovered_$orderId',
          reservedDollars: inferredReserved,
          submittedPrice: filledAvgPrice ?? round?.entryPrice ?? 0,
          entryType: entryType,
          submittedAt: timestamp,
          takeProfitPercent: _takeProfitPercent(symbol),
          stopLossPercent: _stopLossPercent(symbol),
          entryDescription: round?.entryReasoning ?? 'Recovered buy order',
          signalDescription:
              round?.signalReasoning ?? 'Recovered from broker open order',
          historyNote: ' | recovered',
        );
        if (filledAvgPrice != null && filledAvgPrice > 0) {
          pending.accountedQty = filledQty;
          pending.accountedCost = filledAvgPrice * filledQty;
        } else {
          Log.w('QuickTradeEngine', 'Recovered order $orderId for $symbol has no fill price — treating as unfilled');
        }
        _pendingBuys[orderId] = pending;
        final existingPos = _openPositions[symbol];
        final existingExposure = existingPos == null
            ? 0.0
            : existingPos.entryPrice * existingPos.qty;
        _budgetUsed += max(0, inferredReserved - existingExposure);

        if (filledQty > 0 && filledAvgPrice != null) {
          _openPositions[symbol] = QuickTradePosition(
            symbol: symbol,
            entryPrice: filledAvgPrice,
            qty: filledQty,
            orderId: orderId,
            roundTripId: pending.roundTripId,
            entryTime: round?.entryTime ?? timestamp,
            entryType: entryType,
            stopPrice: filledAvgPrice * (1 - pending.stopLossPercent),
            targetPrice: filledAvgPrice * (1 + pending.takeProfitPercent),
            trailingHigh: max(
              filledAvgPrice,
              _rollingHighs[symbol] ?? filledAvgPrice,
            ),
            stopLossOrderId: stopOrdersBySymbol[symbol],
          );
        }
        continue;
      }

      if (side == 'sell') {
        final type = '${order['type'] ?? ''}'.toLowerCase();
        if (type == 'stop' || type == 'stop_limit') {
          final existing = _openPositions[symbol];
          if (existing != null) {
            existing.stopLossOrderId = orderId;
          }
          continue;
        }
        final position = _openPositions[symbol];
        if (position == null) continue;
        final totalTrackedQty = position.qty + filledQty;
        final reconstructed = QuickTradePosition(
          symbol: position.symbol,
          entryPrice: position.entryPrice,
          qty: totalTrackedQty,
          orderId: position.orderId,
          roundTripId: position.roundTripId,
          entryTime: position.entryTime,
          entryType: position.entryType,
          stopPrice: position.stopPrice,
          targetPrice: position.targetPrice,
          trailingHigh: position.trailingHigh,
          stopLossOrderId: position.stopLossOrderId,
        );
        _openPositions[symbol] = reconstructed;
        final pending = _PendingQuickTradeSell(
          orderId: orderId,
          symbol: symbol,
          position: reconstructed,
          requestedAt: timestamp,
          reason: 'Recovered exit order',
        );
        pending.accountedQty = filledQty;
        pending.accountedAvgPrice = filledAvgPrice;
        _pendingSells[orderId] = pending;
        _symbolsClosing.add(symbol);
      }
    }

    for (final pos in _openPositions.values.toList()) {
      if (pos.isProtected || _symbolsClosing.contains(pos.symbol)) continue;
      await _ensureRecoveredPositionProtection(pos);
    }
  }

  Future<List<Position>> _safeGetPositions() async {
    try {
      return await _client.getPositions();
    } catch (e) {
      Log.e('QuickTradeEngine', 'Position reconciliation failed', e);
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _safeGetOpenOrders() async {
    try {
      return await _client.getOrders(status: 'open');
    } catch (e) {
      Log.e('QuickTradeEngine', 'Order reconciliation failed', e);
      return const [];
    }
  }

  /// Reconcile pending fills on startup: fetch all orders from Alpaca,
  /// match against submitted logs, and create filled logs for completed orders.
  Future<void> _reconcilePendingFills() async {
    try {
      final allOrders = await _client.getOrders(status: 'all');
      final submittedLogs = _logs
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
        final filledQty = (alpacaOrder['filled_qty'] as num?)?.toDouble();
        final filledPrice = (alpacaOrder['filled_avg_price'] as num?)
            ?.toDouble();

        if (status == 'filled' && filledQty != null && filledPrice != null) {
          // Guard: skip if a filled log for this order already exists in memory
          // (e.g. reconciliation was triggered twice in rapid succession).
          final alreadyReconciled = _logs.any((l) =>
              l.orderId == orderId &&
              l.executionStatus == TradeExecutionStatus.filled);
          if (alreadyReconciled) continue;

          final filledAt = DateTime.tryParse(alpacaOrder['filled_at'] ?? '') ??
              DateTime.tryParse(alpacaOrder['submitted_at'] ?? '');
          if (filledAt == null) {
            Log.w('QuickTradeEngine', 'No fill timestamp for ${log.ticker} (${log.orderId}); falling back to now()');
          }
          final filledLog = log.copyWith(
            qty: filledQty,
            price: filledPrice,
            executionStatus: TradeExecutionStatus.filled,
            executedAt: filledAt ?? DateTime.now(),
          );
          _logs.add(filledLog);
          await _store.saveTrade(filledLog);
          Log.i(
            'QuickTradeEngine',
            'Reconciled: ${log.ticker} filled retroactively (${filledQty}@\$${filledPrice})',
          );
        } else if (status == 'open' || status == 'pending_new') {
          // Order still pending on Alpaca — re-add to pending buys to wait for fill
          final symbol = log.ticker;
          _PendingQuickTradeBuy? existingPending;
          try {
            existingPending = _pendingBuys.values.firstWhere(
              (p) => p.orderId == orderId,
            );
          } catch (_) {
            // Not found
          }
          if (existingPending == null) {
            final qty = filledQty ?? 0; // Use partial fill qty if available
            final price = filledPrice ?? log.price ?? 0;
            final reservedDollars = qty > 0
                ? qty * price
                : (log.price ?? 0) * (log.qty ?? 1);
            final newPending = _PendingQuickTradeBuy(
              symbol: symbol,
              orderId: orderId,
              roundTripId: log.roundTripId ?? '',
              reservedDollars: reservedDollars,
              submittedPrice: log.price ?? 0,
              entryType: EntryType.dip, // Default; not critical for recovery
              submittedAt: log.createdAt,
              takeProfitPercent: config.baseTakeProfitPercent,
              stopLossPercent: config.baseStopLossPercent,
              entryDescription: 'Recovered from crash',
              signalDescription: log.signal.reasoning,
              historyNote: ' (recovered)',
            );
            if (filledQty != null && filledQty > 0) {
              newPending.accountedQty = filledQty;
              newPending.accountedCost = (filledPrice ?? 0) * filledQty;
            }
            _pendingBuys[orderId] = newPending;
            Log.i(
              'QuickTradeEngine',
              'Reconciled: Re-added pending buy ${symbol} (${log.orderId}) to await fill',
            );
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
          _logs.add(failedLog);
          await _store.saveTrade(failedLog);
          Log.w(
            'QuickTradeEngine',
            'Reconciled: ${log.ticker} order failed with status $status',
          );
        }
      }
    } catch (e) {
      Log.e('QuickTradeEngine', 'Fill reconciliation failed', e);
    }
  }

  Map<String, _RecoveredRound> _buildRoundSnapshots(List<TradeLog> history) {
    final ordered = List<TradeLog>.from(history)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final rounds = <String, _RecoveredRound>{};

    for (final log in ordered) {
      final roundTripId = log.roundTripId;
      if (roundTripId == null) continue;

      final existing = rounds[log.ticker];
      if (log.action == TradeAction.buy &&
          log.qty != null &&
          log.price != null) {
        rounds[log.ticker] = _RecoveredRound(
          roundTripId: roundTripId,
          symbol: log.ticker,
          buyOrderId: log.orderId,
          entryPrice: log.price!,
          entryTime: log.executedAt ?? log.createdAt,
          entryType: QuickTradeAnalytics._inferEntryType(log),
          entryReasoning: log.reasoning,
          signalReasoning: log.signal.reasoning,
          isClosed: existing?.isClosed ?? false,
        );
        continue;
      }

      if (existing != null &&
          log.roundTripId == existing.roundTripId &&
          log.action != TradeAction.skip &&
          log.executionStatus == TradeExecutionStatus.filled &&
          log.action != TradeAction.buy) {
        rounds[log.ticker] = existing.copyWith(isClosed: true);
      }
    }

    rounds.removeWhere((_, round) => round.isClosed);
    return rounds;
  }

  double _restoreSessionPnl(List<TradeLog> history) {
    final today = DateTime.now();
    final todaysLogs = history.where((log) {
      final dt = log.executedAt ?? log.createdAt;
      return dt.year == today.year &&
          dt.month == today.month &&
          dt.day == today.day;
    }).toList();
    return QuickTradeAnalytics.fromTradeLogs(todaysLogs).netPnl;
  }

  int _restoreSessionTradeCount(List<TradeLog> history) {
    final today = DateTime.now();
    return history.where((log) {
      final dt = log.executedAt ?? log.createdAt;
      return log.action == TradeAction.buy &&
          _isHistoryEligible(log) &&
          dt.year == today.year &&
          dt.month == today.month &&
          dt.day == today.day;
    }).length;
  }

  double? _toDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse('$value');
  }

  DateTime? _parseOrderTimestamp(Object? value) {
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  bool _isHistoryEligible(TradeLog log) {
    if (log.action == TradeAction.skip || log.price == null) return false;
    return log.executionStatus != TradeExecutionStatus.submitted;
  }

  // ---------------------------------------------------------------------------
  // Adaptive parameters per symbol
  // ---------------------------------------------------------------------------

  double _dipThreshold(String symbol) {
    final stats = _symbolStats[symbol];
    if (stats == null || stats.totalTrades < 3) return config.baseDipThreshold;

    // If we're winning often, be more aggressive (smaller dip to enter)
    // If we're losing, require bigger dips (more confirmation)
    if (stats.winRate > 0.6) {
      return config.baseDipThreshold * 0.8;
    } else if (stats.winRate < 0.4) {
      return config.baseDipThreshold * 1.5;
    }
    return config.baseDipThreshold;
  }

  double _takeProfitPercent(String symbol) {
    final stats = _symbolStats[symbol];
    if (stats == null || stats.totalTrades < 3)
      return config.baseTakeProfitPercent;

    // Use historical average win to set realistic target
    if (stats.avgWinPercent > 0) {
      // Target 80% of average historical win (leave room to actually hit it)
      return max(config.baseTakeProfitPercent, stats.avgWinPercent * 0.8);
    }
    return config.baseTakeProfitPercent;
  }

  double _stopLossPercent(String symbol) {
    final stats = _symbolStats[symbol];
    if (stats == null || stats.totalTrades < 3)
      return config.baseStopLossPercent;

    // Tighten stops on symbols with high loss rate
    if (stats.winRate < 0.4) {
      return config.baseStopLossPercent * 0.7;
    }
    // Widen stops slightly on proven winners to avoid getting shaken out
    if (stats.winRate > 0.6) {
      return config.baseStopLossPercent * 1.3;
    }
    return config.baseStopLossPercent;
  }

  int _maxHoldSeconds(String symbol) {
    final stats = _symbolStats[symbol];
    if (stats == null || stats.totalTrades < 3)
      return config.baseMaxHoldSeconds;

    // Adapt hold time based on how long winning trades historically took
    if (stats.avgHoldSeconds > 0) {
      return max(
        config.baseMaxHoldSeconds,
        (stats.avgHoldSeconds * 1.2).round(),
      );
    }
    return config.baseMaxHoldSeconds;
  }

  double _positionSizeMultiplier(String symbol) {
    final stats = _symbolStats[symbol];
    if (stats == null || stats.totalTrades < 3) return 1.0;

    // Scale position size by win rate: proven winners get more capital
    if (stats.winRate > 0.65 && stats.totalTrades >= 5) return 1.4;
    if (stats.winRate > 0.55) return 1.15;
    if (stats.winRate < 0.40) return 0.6;
    return 1.0;
  }

  // ---------------------------------------------------------------------------
  // Price tick processing
  // ---------------------------------------------------------------------------

  void _onPriceTick(PriceUpdate update) {
    final symbol = update.symbol;
    final price = update.price;

    // Update rolling price window
    _priceWindows.putIfAbsent(symbol, () => Queue<double>());
    final window = _priceWindows[symbol]!;
    window.addLast(price);
    if (window.length > config.priceWindowSize) window.removeFirst();

    // Track rolling high and low
    final currentHigh = _rollingHighs[symbol] ?? price;
    if (price > currentHigh) _rollingHighs[symbol] = price;
    final currentLow = _rollingLows[symbol] ?? price;
    if (price < currentLow) _rollingLows[symbol] = price;

    // Update volume window + VWAP accumulators
    if (update.size != null) {
      final vol = update.size!.toDouble();
      _volumeWindows.putIfAbsent(symbol, () => Queue<double>());
      final vWindow = _volumeWindows[symbol]!;
      vWindow.addLast(vol);
      if (vWindow.length > config.momentumWindow) vWindow.removeFirst();

      _vwapCumPriceVol[symbol] = (_vwapCumPriceVol[symbol] ?? 0) + price * vol;
      _vwapCumVol[symbol] = (_vwapCumVol[symbol] ?? 0) + vol;
    }

    // Snapshot MAs before this tick is used for entry (crossover needs prev vs current)
    final windowSnap = _priceWindows[symbol];
    if (windowSnap != null && windowSnap.length >= config.maLongPeriod) {
      final snapPrices = windowSnap.toList();
      final shortMa = _ma(snapPrices, config.maShortPeriod);
      final longMa = _ma(snapPrices, config.maLongPeriod);
      if (shortMa != null && longMa != null) {
        _prevShortMa[symbol] = shortMa;
        _prevLongMa[symbol] = longMa;
      }
    }

    // Check open position first
    final openPos = _openPositions[symbol];
    if (openPos != null) {
      if (_pendingBuys.values.any((pending) => pending.symbol == symbol))
        return;
      if (_symbolsClosing.contains(symbol)) return;
      _checkExitConditions(openPos, price);
      return;
    }

    _checkEntry(symbol, price);
  }

  // ---------------------------------------------------------------------------
  // Entry logic — dip bounce + breakout momentum + MA crossover
  // ---------------------------------------------------------------------------

  void _checkEntry(String symbol, double currentPrice) {
    // Session risk circuit breakers
    if (_openPositions.length >= config.maxOpenPositions) {
      Log.d('QuickTradeEngine', '$symbol: skip — max open positions (${config.maxOpenPositions})');
      return;
    }
    if (_consecutiveLosses >= config.maxConsecutiveLosses) {
      Log.d('QuickTradeEngine', '$symbol: skip — consecutive losses ($_consecutiveLosses)');
      return;
    }
    if (_accountEquity > 0 &&
        _sessionPnL / _accountEquity < -config.maxSessionLossPercent) {
      Log.d('QuickTradeEngine', '$symbol: skip — session loss limit hit (${(_sessionPnL / _accountEquity * 100).toStringAsFixed(1)}%)');
      return;
    }
    if (_blacklist.contains(symbol)) {
      Log.d('QuickTradeEngine', '$symbol: skip — blacklisted');
      return;
    }

    final cooldownEnd = _cooldowns[symbol];
    if (cooldownEnd != null && DateTime.now().isBefore(cooldownEnd)) return;
    if (_submittingSymbols.contains(symbol)) return;
    if (_pendingBuys.values.any((pending) => pending.symbol == symbol)) return;

    final availableBudget = _budgetLimit - _budgetUsed;
    if (availableBudget <= 0) {
      Log.d('QuickTradeEngine', '$symbol: skip — no available budget');
      return;
    }

    final window = _priceWindows[symbol];
    if (window == null || window.length < config.maLongPeriod) return;

    final prices = window.toList();
    // Use windowed high/low so stale session extremes don't permanently block entries
    final rollingHigh = prices.reduce(max);
    final rollingLow = prices.reduce(min);
    final last5 = prices.sublist(max(0, prices.length - 5));
    final last5Avg = last5.reduce((a, b) => a + b) / last5.length;
    final last10Start = max(0, prices.length - 10);
    final prev5 = prices.sublist(
      last10Start,
      max(last10Start, prices.length - 5),
    );
    final prev5Avg = prev5.isNotEmpty
        ? prev5.reduce((a, b) => a + b) / prev5.length
        : last5Avg;

    final vWindow = _volumeWindows[symbol];
    final double? avgVol =
        (vWindow != null && vWindow.length >= config.momentumWindow)
        ? vWindow.toList().reduce((a, b) => a + b) / vWindow.length
        : null;
    final double? recentVol = vWindow?.isNotEmpty == true
        ? vWindow!.last
        : null;

    // Compute indicators
    final rsi = _rsi(prices, config.rsiPeriod);
    final vwap = _vwap(symbol);
    final shortMa = _ma(prices, config.maShortPeriod);
    final longMa = _ma(prices, config.maLongPeriod);

    // RSI gate: never enter when clearly overbought
    if (rsi != null && rsi > config.rsiOverbought) return;

    // Guard: skip if price window has zero/corrupt values
    if (rollingHigh <= 0 || rollingLow <= 0) return;

    // --- Strategy A: Dip bounce ---
    // Price fallen from rolling high, stabilizing, below VWAP, RSI not stretched
    final dropPercent = (rollingHigh - currentPrice) / rollingHigh;
    if (dropPercent >= _dipThreshold(symbol)) {
      final stabilizing = last5Avg >= prev5Avg * 0.998;
      final hasVolume =
          avgVol == null || recentVol == null || recentVol >= avgVol * 0.5;
      final belowVwap = vwap == null || currentPrice <= vwap;
      final rsiOk = rsi == null || rsi < config.rsiOversold;
      if (stabilizing && hasVolume && belowVwap && rsiOk) {
        _executeBuy(
          symbol,
          currentPrice,
          _orderSize(availableBudget, symbol),
          EntryType.dip,
        );
        return;
      }
    }

    // --- Strategy B: Breakout momentum ---
    // Price surged from low, at new session high, above VWAP, volume spike
    final risePercent = (currentPrice - rollingLow) / rollingLow;
    if (risePercent >= _breakoutThreshold(symbol) &&
        currentPrice >= rollingHigh * 0.999) {
      final accelerating = last5Avg > prev5Avg * 1.001;
      // Treat missing volume data as permissive (same pattern as dip hasVolume)
      final volumeSpike =
          avgVol == null ||
          recentVol == null ||
          recentVol >= avgVol * config.volumeSpikeMultiplier;
      final aboveVwap = vwap == null || currentPrice >= vwap;
      if (accelerating && volumeSpike && aboveVwap) {
        _executeBuy(
          symbol,
          currentPrice,
          _orderSize(availableBudget, symbol),
          EntryType.breakout,
        );
        return;
      }
    }

    // --- Strategy C: MA golden cross ---
    // Short MA just crossed above long MA — trend is turning bullish
    // Needs enough history, RSI not overbought, and price above VWAP for confirmation
    if (shortMa != null && longMa != null) {
      final prevShort = _prevShortMa[symbol];
      final prevLong = _prevLongMa[symbol];
      final crossedAbove =
          prevShort != null &&
          prevLong != null &&
          prevShort <= prevLong &&
          shortMa > longMa;
      if (crossedAbove) {
        final aboveVwap = vwap == null || currentPrice >= vwap;
        final rsiHealthy =
            rsi == null || rsi > 40; // not deeply oversold/broken
        if (aboveVwap && rsiHealthy) {
          _executeBuy(
            symbol,
            currentPrice,
            _orderSize(availableBudget, symbol),
            EntryType.maCrossover,
          );
        }
      }
    }
  }

  double _breakoutThreshold(String symbol) {
    final stats = _symbolStats[symbol];
    if (stats == null || stats.totalTrades < 3)
      return config.baseBreakoutThreshold;
    if (stats.winRate > 0.6) return config.baseBreakoutThreshold * 0.8;
    if (stats.winRate < 0.4) return config.baseBreakoutThreshold * 1.5;
    return config.baseBreakoutThreshold;
  }

  double _orderSize(double availableBudget, String symbol) {
    final sizeMultiplier = _positionSizeMultiplier(symbol);
    final volScalar = _volatilityScalar(symbol);
    return (availableBudget.clamp(0.0, config.maxOrderDollars) * sizeMultiplier * volScalar)
        .clamp(0.0, availableBudget);
  }

  /// Returns a scalar in [0.5, 1.0] that reduces position size for high-volatility symbols.
  /// Computed from the standard deviation of recent price returns.
  double _volatilityScalar(String symbol) {
    final window = _priceWindows[symbol];
    if (window == null || window.length < 10) return 1.0;
    final prices = window.toList();
    final returns = <double>[];
    for (int i = 1; i < prices.length; i++) {
      if (prices[i - 1] > 0) returns.add((prices[i] - prices[i - 1]) / prices[i - 1]);
    }
    if (returns.isEmpty) return 1.0;
    final mean = returns.reduce((a, b) => a + b) / returns.length;
    final variance = returns.map((r) => (r - mean) * (r - mean)).reduce((a, b) => a + b) / returns.length;
    final stdDev = sqrt(variance);
    // 1% intraday stdDev → full size; 3%+ → half size (linear interpolation)
    return ((0.03 - stdDev) / 0.02).clamp(0.5, 1.0);
  }

  // ---------------------------------------------------------------------------
  // Indicators
  // ---------------------------------------------------------------------------

  /// RSI — Relative Strength Index over [period] ticks.
  /// Returns null if not enough data.
  double? _rsi(List<double> prices, int period) {
    if (prices.length < period + 1) return null;
    final recent = prices.sublist(prices.length - period - 1);
    double gains = 0, losses = 0;
    for (var i = 1; i < recent.length; i++) {
      final change = recent[i] - recent[i - 1];
      if (change > 0) {
        gains += change;
      } else {
        losses += change.abs();
      }
    }
    if (losses == 0) return 100;
    final rs = (gains / period) / (losses / period);
    return 100 - (100 / (1 + rs));
  }

  /// VWAP — Volume Weighted Average Price since session start.
  /// Returns null if no volume data available.
  double? _vwap(String symbol) {
    final cumVol = _vwapCumVol[symbol];
    final cumPV = _vwapCumPriceVol[symbol];
    if (cumVol == null || cumVol == 0 || cumPV == null) return null;
    return cumPV / cumVol;
  }

  /// Simple moving average of last [period] prices.
  /// Returns null if not enough data.
  double? _ma(List<double> prices, int period) {
    if (prices.length < period) return null;
    final slice = prices.sublist(prices.length - period);
    return slice.reduce((a, b) => a + b) / period;
  }

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  Future<void> _executeBuy(
    String symbol,
    double currentPrice,
    double dollars,
    EntryType entryType,
  ) async {
    // Acquire symbol-level lock to prevent simultaneous orders from multiple engines
    if (!_tradingLock.tryAcquire(symbol)) {
      Log.w(
        'QuickTradeEngine',
        'Skipping $symbol buy: lock held by another engine',
      );
      return;
    }

    // Mark symbol as being submitted to prevent TOCTOU race in _checkEntry
    _submittingSymbols.add(symbol);
    try {
      // Check if market is open
      try {
        await _client.assertMarketOpen();
      } on MarketClosedException catch (e) {
        Log.w('QuickTradeEngine', 'Skipping $symbol buy: ${e.message}');
        return;
      } catch (e) {
        Log.e('QuickTradeEngine', 'Market clock check failed, skipping buy to be safe', e);
        return;
      }

      // Check account-level risk limits if RiskManager is available
      // Acquire account lock to prevent concurrent exposure limit violations
      await _accountLock.acquire();
      try {
        try {
          final account = await _client.getAccount();
          final positions = await _client.getPositions();

          // Check total account exposure
          final totalExposure = positions.fold<double>(
            0.0,
            (sum, pos) => sum + pos.marketValue,
          );
          final nextTotalExposure = totalExposure + dollars;
          final nextTotalPercent = account.equity > 0
              ? nextTotalExposure / account.equity
              : 0;

          if (nextTotalPercent > _riskManager.config.maxTotalExposurePercent) {
            Log.w(
              'QuickTradeEngine',
              'Skipping $symbol buy: would exceed max exposure (${(nextTotalPercent * 100).toStringAsFixed(1)}% > ${(_riskManager.config.maxTotalExposurePercent * 100).toStringAsFixed(1)}%)',
            );
            return;
          }

          // Check single-symbol exposure
          final symbolExposure = positions
              .where((p) => p.symbol == symbol)
              .fold<double>(0.0, (sum, pos) => sum + pos.marketValue);
          final nextSymbolExposure = symbolExposure + dollars;
          final nextSymbolPercent = account.equity > 0
              ? nextSymbolExposure / account.equity
              : 0;

          if (nextSymbolPercent > _riskManager.config.maxPositionPercent) {
            Log.w(
              'QuickTradeEngine',
              'Skipping $symbol buy: would exceed max position size (${(nextSymbolPercent * 100).toStringAsFixed(1)}% > ${(_riskManager.config.maxPositionPercent * 100).toStringAsFixed(1)}%)',
            );
            return;
          }
        } catch (e) {
          Log.e(
            'QuickTradeEngine',
            'Risk check failed',
            e,
          );
          return;
        }

        final clientOrderId =
            '${symbol}_qt_${DateTime.now().microsecondsSinceEpoch}';

        // Limit-order vs market-order branch.
        // Limit: whole-share qty at currentPrice + slippage buffer.
        //        Slightly worse fills than market in calm markets but no
        //        surprise slippage in fast moves; produces only whole shares
        //        so broker stops always work.
        // Market: notional buy, fractional possible. In-process exits manage
        //        risk; broker stop is skipped for fractional positions.
        final useLimit = config.useLimitEntries;
        double? limitPrice;
        double? wholeQty;
        if (useLimit) {
          if (currentPrice <= 0) {
            Log.w('QuickTradeEngine',
                'Skipping $symbol limit buy: invalid currentPrice $currentPrice');
            return;
          }
          wholeQty = (dollars / currentPrice).floorToDouble();
          if (wholeQty < 1) {
            Log.w('QuickTradeEngine',
                'Skipping $symbol limit buy: budget \$${dollars.toStringAsFixed(2)} '
                '< price \$${currentPrice.toStringAsFixed(2)} (need ≥1 whole share)');
            return;
          }
          limitPrice = currentPrice * (1 + config.limitSlippageBuffer);
          // Reserve the actual notional we'll spend (qty × limitPrice), not
          // the requested budget — keeps budget-used accurate.
          dollars = wholeQty * limitPrice;
        }

        _budgetUsed += dollars;
        late final Map<String, dynamic> result;
        try {
          result = await _client.placeOrder(
            symbol: symbol,
            qty: useLimit ? wholeQty : null,
            notional: useLimit ? null : dollars,
            side: 'buy',
            type: useLimit ? 'limit' : 'market',
            timeInForce: 'day',
            limitPrice: limitPrice,
            clientOrderId: clientOrderId,
          );
        } catch (e) {
          _budgetUsed -= dollars;
          if (_budgetUsed < 0) _budgetUsed = 0;
          rethrow;
        }

        final orderId = result['id'] as String? ?? '';
        if (orderId.isEmpty) {
          _budgetUsed -= dollars;
          if (_budgetUsed < 0) _budgetUsed = 0;
          Log.e('QuickTradeEngine', 'Order response missing id for $symbol — budget released');
          return;
        }
        final roundTripId =
            '${symbol}_${DateTime.now().microsecondsSinceEpoch}_$orderId';

        // Persist a submitted log IMMEDIATELY — before _pendingBuys is populated.
        // If the app crashes between here and the fill event, _reconcilePendingFills
        // will find this log on restart and re-attach it to the broker order.
        _logTrade(TradeLog(
          ticker: symbol,
          action: TradeAction.buy,
          price: currentPrice,
          orderId: orderId,
          roundTripId: roundTripId,
          executionStatus: TradeExecutionStatus.submitted,
          reasoning: 'Buy submitted — awaiting fill',
          signal: _buildSignal(symbol, 'QuickTrade entry at \$$currentPrice'),
          createdAt: DateTime.now(),
        ));
        final tp = _takeProfitPercent(symbol);
        final sl = _stopLossPercent(symbol);
        _rollingHighs[symbol] = currentPrice;

        final stats = _symbolStats[symbol];
        final historyNote = stats != null && stats.totalTrades >= 3
            ? ' | history: ${stats.totalTrades} trades, ${(stats.winRate * 100).toStringAsFixed(0)}% WR'
            : ' | no history';

        final String entryDesc;
        final String signalDesc;
        if (entryType == EntryType.dip) {
          final drop =
              (_rollingHighs[symbol]! - currentPrice) /
              _rollingHighs[symbol]! *
              100;
          entryDesc = 'Dip buy: -${drop.toStringAsFixed(1)}% from high';
          signalDesc = 'Dip + RSI + VWAP confirmed';
        } else if (entryType == EntryType.breakout) {
          final rise =
              (currentPrice - (_rollingLows[symbol] ?? currentPrice)) /
              (_rollingLows[symbol] ?? currentPrice) *
              100;
          entryDesc = 'Breakout buy: +${rise.toStringAsFixed(1)}% from low';
          signalDesc = 'Breakout + volume spike + VWAP confirmed';
        } else {
          entryDesc =
              'MA golden cross (${config.maShortPeriod}/${config.maLongPeriod})';
          signalDesc = 'MA crossover + RSI + VWAP confirmed';
        }

        _pendingBuys[orderId] = _PendingQuickTradeBuy(
          symbol: symbol,
          orderId: orderId,
          roundTripId: roundTripId,
          reservedDollars: dollars,
          submittedPrice: currentPrice,
          entryType: entryType,
          submittedAt: DateTime.now(),
          takeProfitPercent: tp,
          stopLossPercent: sl,
          entryDescription: entryDesc,
          signalDescription: signalDesc,
          historyNote: historyNote,
        );

        Log.i(
          'QuickTradeEngine',
          'BUY submitted $symbol near \$${currentPrice.toStringAsFixed(2)} '
              '[$entryDesc] (\$${dollars.toStringAsFixed(0)})$historyNote',
        );
        _refreshStatus();
      } catch (e) {
        Log.e('QuickTradeEngine', 'Account lock or order submission failed for $symbol', e);
        _updateStatus(_status.copyWith(lastError: 'Order submission failed for $symbol: $e'));
      } finally {
        _accountLock.release();
      }
    } catch (e) {
      Log.e('QuickTradeEngine', 'Buy failed for $symbol', e);
      _updateStatus(_status.copyWith(lastError: 'Buy failed for $symbol: $e'));
    } finally {
      _submittingSymbols.remove(symbol);
      _tradingLock.release(symbol);
    }
  }

  // ---------------------------------------------------------------------------
  // Exit logic — trailing stop + adaptive targets
  // ---------------------------------------------------------------------------

  void _checkExitConditions(QuickTradePosition pos, double currentPrice) {
    // Take profit
    if (currentPrice >= pos.targetPrice) {
      unawaited(
        _requestClosePosition(
          pos,
          'Take profit at quote \$${currentPrice.toStringAsFixed(2)}',
        ),
      );
      return;
    }

    // Trailing stop: ratchet up the stop as price climbs
    if (currentPrice > pos.trailingHigh) {
      pos.trailingHigh = currentPrice;
      final trailingStop = currentPrice * (1 - _stopLossPercent(pos.symbol));
      if (trailingStop > pos.stopPrice) {
        pos.stopPrice = trailingStop;
        unawaited(_syncProtectionStop(pos, reason: 'Trailing stop update')
            .catchError((Object e) { Log.w('QuickTradeEngine', 'Trailing stop sync failed for ${pos.symbol}: $e'); return false; }));
      }
    }

    // Stop loss (now trailing)
    if (currentPrice <= pos.stopPrice) {
      unawaited(
        _requestClosePosition(
          pos,
          'Stop loss at quote \$${currentPrice.toStringAsFixed(2)}',
        ),
      );
      return;
    }

    // Break-even stop: once we're up >50% of target, move stop to entry
    final halfwayToTarget =
        pos.entryPrice + (pos.targetPrice - pos.entryPrice) * 0.5;
    if (currentPrice >= halfwayToTarget && pos.stopPrice < pos.entryPrice) {
      pos.stopPrice = pos.entryPrice;
      unawaited(_syncProtectionStop(pos, reason: 'Break-even stop update')
          .catchError((Object e) { Log.w('QuickTradeEngine', 'Break-even stop sync failed for ${pos.symbol}: $e'); return false; }));
    }
  }

  void _checkExpiredPositions() {
    final now = DateTime.now();

    // Cancel stuck pending buys (market orders that haven't filled in 5 min)
    for (final pending in _pendingBuys.values.toList()) {
      if (now.difference(pending.submittedAt).inMinutes >= 5) {
        Log.w('QuickTradeEngine', 'Pending buy for ${pending.symbol} stuck >5min — cancelling');
        unawaited(_cancelPendingBuy(pending));
        _budgetUsed = (_budgetUsed - pending.reservedDollars).clamp(0, _budgetLimit);
        _pendingBuys.remove(pending.orderId);
      }
    }

    for (final pos in _openPositions.values.toList()) {
      final maxHold = _maxHoldSeconds(pos.symbol);
      if (pos.holdSeconds >= maxHold) {
        if (_symbolsClosing.contains(pos.symbol)) continue;
        if (_pendingSells.values.any((s) => s.symbol == pos.symbol)) continue;
        unawaited(
          _requestClosePosition(pos, 'Max hold time (${maxHold}s) exceeded'),
        );
      }
    }
  }

  Future<void> _requestClosePosition(
    QuickTradePosition pos,
    String reason,
  ) async {
    if (_symbolsClosing.contains(pos.symbol)) return;
    _symbolsClosing.add(pos.symbol);

    // Acquire symbol-level lock to prevent simultaneous orders from multiple engines
    if (!_tradingLock.tryAcquire(pos.symbol)) {
      _symbolsClosing.remove(pos.symbol);
      Log.w(
        'QuickTradeEngine',
        'Skipping ${pos.symbol} close: lock held by another engine',
      );
      return;
    }

    try {
      if (pos.stopLossOrderId != null) {
        try {
          await _client.cancelOrder(pos.stopLossOrderId!);
        } catch (e) {
          Log.w('QuickTradeEngine', 'Cancel stop failed for ${pos.symbol}: $e');
        }
      }
      final result = await _client.closePosition(pos.symbol);
      final orderId = result['id'] as String? ?? '';
      _pendingSells[orderId] = _PendingQuickTradeSell(
        orderId: orderId,
        symbol: pos.symbol,
        position: pos,
        requestedAt: DateTime.now(),
        reason: reason,
      );
      Log.i('QuickTradeEngine', 'SELL submitted ${pos.symbol} — $reason');
    } catch (e) {
      _symbolsClosing.remove(pos.symbol);
      Log.e('QuickTradeEngine', 'Close failed for ${pos.symbol}', e);
      _updateStatus(
        _status.copyWith(lastError: 'Failed to close ${pos.symbol}: $e'),
      );
    } finally {
      _tradingLock.release(pos.symbol);
    }
  }

  Future<void> _cancelPendingBuy(_PendingQuickTradeBuy pending) async {
    try {
      await _client.cancelOrder(pending.orderId);
    } catch (e) {
      Log.e('QuickTradeEngine', 'Cancel buy failed for ${pending.symbol}', e);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _logTrade(TradeLog log) {
    _logs.add(log);
    unawaited(
      _store.saveTrade(log).catchError((e) {
        Log.e(
          'QuickTradeEngine',
          'Failed to persist trade log for ${log.ticker}',
          e,
        );
      }),
    );
  }

  void _refreshStatus() {
    _updateStatus(
      _status.copyWith(
        budgetUsed: _budgetUsed,
        budgetLimit: _budgetLimit,
        openPositions: _openPositions.length,
        totalTrades: _totalTrades,
        sessionPnL: _sessionPnL,
        recentLogs: _logs.reversed.take(20).toList(),
      ),
    );
  }

  /// Called when the app returns to foreground. Re-runs fill reconciliation so
  /// any fills that arrived while the WebSocket was disconnected are recovered.
  Future<void> reconcileOnForeground() async {
    if (_status.state != QuickTradeEngineState.running) return;
    Log.i('QuickTradeEngine', 'Foreground reconciliation triggered');
    await _reconcilePendingFills();
  }

  void _updateStatus(QuickTradeStatus newStatus) {
    _status = newStatus.copyWith(updatedAt: DateTime.now());
    if (!_statusController.isClosed) {
      _statusController.add(_status);
    }
  }

  Signal _buildSignal(String ticker, String reason) => Signal(
    ticker: ticker,
    sentiment: Sentiment.neutral,
    confidence: 0.0,
    timeframe: Timeframe.short,
    reasoning: reason,
    sourceHeadlines: [],
    createdAt: DateTime.now(),
  );

  void dispose() {
    stop();
    _orderSubscription?.cancel();
    _statusController.close();
  }

  Future<void> _handleOrderUpdate(OrderUpdate update) async {
    final pendingBuy = _pendingBuys[update.orderId];
    if (pendingBuy != null) {
      if (update.isFilled || update.event == OrderEvent.partialFill) {
        await _handleBuyProgress(pendingBuy, update);
        if (update.isFilled && _pendingBuys.containsKey(update.orderId)) {
          _finalizeBuyLog(pendingBuy, update, TradeExecutionStatus.filled);
        }
      } else if (update.isFailed) {
        _handleBuyFailure(pendingBuy, update);
      }
      return;
    }

    var pendingSell = _pendingSells[update.orderId];
    pendingSell ??= _pendingStopLossOrder(update);
    if (pendingSell != null) {
      if (update.isFilled || update.event == OrderEvent.partialFill) {
        _handleSellProgress(pendingSell, update);
        if (update.isFilled) {
          _finalizeSellLog(pendingSell, update, TradeExecutionStatus.filled);
        }
      } else if (update.isFailed) {
        _handleSellFailure(pendingSell, update);
      }
    }
  }

  Future<void> _handleBuyProgress(
    _PendingQuickTradeBuy pending,
    OrderUpdate update,
  ) async {
    final fillPrice = update.filledAvgPrice;
    final fillQty = update.filledQty;
    if (fillPrice == null || fillQty == null || fillQty <= 0) return;
    if (fillQty <= pending.accountedQty) return;

    final firstFill = pending.accountedQty == 0;
    pending.accountedCost = (pending.accountedCost) + (fillPrice * (fillQty - pending.accountedQty));
    pending.accountedQty = fillQty;
    if (firstFill) _totalTrades++;

    final pos =
        _openPositions[pending.symbol] ??
        QuickTradePosition(
          symbol: pending.symbol,
          entryPrice: fillPrice,
          qty: fillQty,
          orderId: update.orderId,
          roundTripId: pending.roundTripId,
          entryTime: update.timestamp,
          entryType: pending.entryType,
          stopPrice: fillPrice * (1 - pending.stopLossPercent),
          targetPrice: fillPrice * (1 + pending.takeProfitPercent),
          trailingHigh: fillPrice,
          stopLossOrderId: null,
        );
    pos.entryPrice = fillPrice;
    pos.qty = fillQty;
    pos.stopPrice = fillPrice * (1 - pending.stopLossPercent);
    pos.targetPrice = fillPrice * (1 + pending.takeProfitPercent);
    pos.trailingHigh = max(pos.trailingHigh, fillPrice);
    _openPositions[pending.symbol] = pos;
    _rollingHighs[pending.symbol] = fillPrice;
    pos.stopPrice = fillPrice * (1 - pending.stopLossPercent);

    Log.i(
      'QuickTradeEngine',
      '${update.event == OrderEvent.partialFill ? 'BUY partial' : 'BUY filled'} ${pending.symbol} '
          '${fillQty.toStringAsFixed(4)}x @ \$${fillPrice.toStringAsFixed(2)}',
    );
    _refreshStatus();

    final protected = await _syncProtectionStop(
      pos,
      qty: fillQty,
      reason: update.event == OrderEvent.partialFill
          ? 'Partial fill protection'
          : 'Filled position protection',
    );
    if (!protected) {
      await _failClosedOnProtectionError(
        pending,
        pos,
        'Unable to establish broker stop-loss protection',
      );
      return;
    }

    if (_status.state != QuickTradeEngineState.running &&
        !_symbolsClosing.contains(pending.symbol)) {
      unawaited(
        _requestClosePosition(pos, 'Engine stopped before fill settled'),
      );
    }
  }

  void _finalizeBuyLog(
    _PendingQuickTradeBuy pending,
    OrderUpdate update,
    TradeExecutionStatus executionStatus,
  ) {
    final fillPrice = update.filledAvgPrice;
    final fillQty = update.filledQty;
    if (fillPrice == null || fillQty == null || fillQty <= 0) {
      // Remove stuck order and log as failed trade
      _pendingBuys.remove(update.orderId);
      Log.w(
        'QuickTradeEngine',
        'Buy order filled but missing fill data: '
            '${pending.symbol} (qty=$fillQty, price=$fillPrice)',
      );
      _logTrade(
        TradeLog(
          ticker: pending.symbol,
          action: TradeAction.skip,
          orderId: update.orderId,
          roundTripId: pending.roundTripId,
          executionStatus: TradeExecutionStatus.partialFill,
          executedAt: update.timestamp,
          reasoning:
              'Buy filled but incomplete data (qty=$fillQty, price=$fillPrice)',
          signal: _buildSignal(pending.symbol, ''),
          createdAt: pending.submittedAt,
        ),
      );
      return;
    }

    _pendingBuys.remove(update.orderId);
    _budgetUsed += (fillPrice * fillQty) - pending.reservedDollars;
    if (_budgetUsed < 0) _budgetUsed = 0;

    final pos = _openPositions[pending.symbol];
    if (pos != null) {
      pos.stopPrice = fillPrice * (1 - pending.stopLossPercent);
    }

    final tpStr = pos != null ? '\$${pos.targetPrice.toStringAsFixed(2)}' : 'n/a';
    final slStr = pos != null ? '\$${(fillPrice * (1 - pending.stopLossPercent)).toStringAsFixed(2)}' : 'n/a';

    _logTrade(
      TradeLog(
        ticker: pending.symbol,
        action: TradeAction.buy,
        qty: fillQty,
        price: fillPrice,
        orderId: update.orderId,
        roundTripId: pending.roundTripId,
        executionStatus: executionStatus,
        executedAt: update.timestamp,
        reasoning:
            '${pending.entryDescription} → TP $tpStr, SL $slStr${pending.historyNote}'
            '${pos == null ? ' [position closed before log written]' : ''}',
        signal: _buildSignal(pending.symbol, pending.signalDescription),
        createdAt: pending.submittedAt,
      ),
    );

    _refreshStatus();
  }

  void _handleBuyFailure(_PendingQuickTradeBuy pending, OrderUpdate update) {
    _pendingBuys.remove(update.orderId);
    final executionStatus = switch (update.event) {
      OrderEvent.canceled => TradeExecutionStatus.canceled,
      OrderEvent.rejected => TradeExecutionStatus.rejected,
      OrderEvent.expired => TradeExecutionStatus.expired,
      _ => null,
    };

    if (pending.accountedQty > 0) {
      _budgetUsed += pending.accountedCost - pending.reservedDollars;
      if (_budgetUsed < 0) _budgetUsed = 0;
      final pos = _openPositions[pending.symbol];
      if (pos != null) {
        _logTrade(
          TradeLog(
            ticker: pending.symbol,
            action: TradeAction.buy,
            qty: pending.accountedQty,
            price: pos.entryPrice,
            orderId: update.orderId,
            roundTripId: pending.roundTripId,
            executionStatus: executionStatus,
            executedAt: update.timestamp,
            reasoning:
                '${pending.entryDescription} | buy order ${update.event.name} after partial execution',
            signal: _buildSignal(pending.symbol, pending.signalDescription),
            createdAt: pending.submittedAt,
          ),
        );
      }
    } else {
      _budgetUsed -= pending.reservedDollars;
      if (_budgetUsed < 0) _budgetUsed = 0;
      _logTrade(
        TradeLog(
          ticker: pending.symbol,
          action: TradeAction.skip,
          orderId: update.orderId,
          roundTripId: pending.roundTripId,
          executionStatus: executionStatus,
          executedAt: update.timestamp,
          reasoning:
              'Buy order ${update.event.name}: ${pending.entryDescription}',
          signal: _buildSignal(pending.symbol, pending.signalDescription),
          createdAt: pending.submittedAt,
        ),
      );
    }

    _refreshStatus();
  }

  _PendingQuickTradeSell? _pendingStopLossOrder(OrderUpdate update) {
    if (update.side != 'sell') return null;
    final pos = _openPositions[update.symbol];
    if (pos == null || pos.stopLossOrderId != update.orderId) return null;
    final pending = _PendingQuickTradeSell(
      orderId: update.orderId,
      symbol: update.symbol,
      position: pos,
      requestedAt: DateTime.now(),
      reason: 'Broker stop-loss exit',
    );
    _pendingSells[update.orderId] = pending;
    return pending;
  }

  void _handleSellProgress(_PendingQuickTradeSell pending, OrderUpdate update) {
    final fillPrice = update.filledAvgPrice;
    final fillQty = update.filledQty;
    if (fillPrice == null || fillQty == null || fillQty <= 0) return;
    if (fillQty <= pending.accountedQty) return;

    if (pending.position.entryPrice <= 0) {
      Log.w('QuickTradeEngine', 'Sell progress for ${pending.symbol} has zero entry price — skipping P&L update');
      return;
    }
    final deltaQty = fillQty - pending.accountedQty;
    pending.accountedQty = fillQty;
    pending.accountedAvgPrice = fillPrice;

    final pnlDelta = (fillPrice - pending.position.entryPrice) * deltaQty;
    _sessionPnL += pnlDelta;
    _budgetUsed -= pending.position.entryPrice * deltaQty;
    if (_budgetUsed < 0) _budgetUsed = 0;
    pending.position.qty = max(0, pending.position.qty - deltaQty);

    if (update.isFilled || pending.position.qty <= 0) {
      _openPositions.remove(pending.symbol);
    } else {
      _openPositions[pending.symbol] = pending.position;
    }
    _refreshStatus();
  }

  void _finalizeSellLog(
    _PendingQuickTradeSell pending,
    OrderUpdate update,
    TradeExecutionStatus executionStatus,
  ) {
    final fillPrice = update.filledAvgPrice;
    final fillQty = update.filledQty;
    if (fillPrice == null || fillQty == null || fillQty <= 0) {
      // Remove stuck order and log as failed trade
      _pendingSells.remove(update.orderId);
      _symbolsClosing.remove(pending.symbol);
      Log.w(
        'QuickTradeEngine',
        'Sell order filled but missing fill data: '
            '${pending.symbol} (qty=$fillQty, price=$fillPrice)',
      );
      _logTrade(
        TradeLog(
          ticker: pending.symbol,
          action: TradeAction.skip,
          orderId: update.orderId,
          executionStatus: TradeExecutionStatus.partialFill,
          executedAt: update.timestamp,
          reasoning:
              'Sell filled but incomplete data (qty=$fillQty, price=$fillPrice)',
          signal: _buildSignal(pending.symbol, ''),
          createdAt: pending.requestedAt,
        ),
      );
      return;
    }

    _pendingSells.remove(update.orderId);
    _symbolsClosing.remove(pending.symbol);

    if (pending.position.entryPrice <= 0) {
      Log.w('QuickTradeEngine', 'Final sell for ${pending.symbol} has zero entry price — P&L unreliable');
    }
    final pnl = (fillPrice - pending.position.entryPrice) * fillQty;
    if (pnl < 0) {
      _consecutiveLosses++;
    } else {
      _consecutiveLosses = 0;
    }

    final cooldownMultiplier = pnl < 0 ? 2.0 : 0.5;
    _cooldowns[pending.symbol] = update.timestamp.add(
      Duration(seconds: (config.cooldownSeconds * cooldownMultiplier).round()),
    );

    final action = pnl >= 0 ? TradeAction.takeProfitSell : TradeAction.sell;
    final pnlStr = pnl >= 0
        ? '+\$${pnl.toStringAsFixed(2)}'
        : '-\$${pnl.abs().toStringAsFixed(2)}';

    _logTrade(
      TradeLog(
        ticker: pending.symbol,
        action: action,
        qty: fillQty,
        price: fillPrice,
        orderId: update.orderId,
        roundTripId: pending.position.roundTripId,
        executionStatus: executionStatus,
        executedAt: update.timestamp,
        reasoning:
            '${pending.reason} | Fill @ \$${fillPrice.toStringAsFixed(2)} | '
            'P&L: $pnlStr (${pending.position.holdSeconds}s hold) | '
            'session: \$${_sessionPnL.toStringAsFixed(2)}',
        signal: _buildSignal(pending.symbol, pending.reason),
        createdAt: pending.requestedAt,
      ),
    );

    Log.i('QuickTradeEngine', 'SELL filled ${pending.symbol} — $pnlStr');
    _refreshStatus();
  }

  void _handleSellFailure(_PendingQuickTradeSell pending, OrderUpdate update) {
    _pendingSells.remove(update.orderId);
    _symbolsClosing.remove(pending.symbol);
    final executionStatus = switch (update.event) {
      OrderEvent.canceled => TradeExecutionStatus.canceled,
      OrderEvent.rejected => TradeExecutionStatus.rejected,
      OrderEvent.expired => TradeExecutionStatus.expired,
      _ => null,
    };
    if (pending.accountedQty > 0 && pending.accountedAvgPrice != null) {
      final pnl =
          (pending.accountedAvgPrice! - pending.position.entryPrice) *
          pending.accountedQty;
      final action = pnl >= 0 ? TradeAction.takeProfitSell : TradeAction.sell;
      final pnlStr = pnl >= 0
          ? '+\$${pnl.toStringAsFixed(2)}'
          : '-\$${pnl.abs().toStringAsFixed(2)}';
      _logTrade(
        TradeLog(
          ticker: pending.symbol,
          action: action,
          qty: pending.accountedQty,
          price: pending.accountedAvgPrice,
          orderId: update.orderId,
          roundTripId: pending.position.roundTripId,
          executionStatus: executionStatus,
          executedAt: update.timestamp,
          reasoning:
              '${pending.reason} | sell order ${update.event.name} after partial execution | '
              'P&L: $pnlStr | session: \$${_sessionPnL.toStringAsFixed(2)}',
          signal: _buildSignal(pending.symbol, pending.reason),
          createdAt: pending.requestedAt,
        ),
      );
    }
    Log.e(
      'QuickTradeEngine',
      'Sell order ${update.event.name} for ${pending.symbol}',
      null,
    );
    _updateStatus(
      _status.copyWith(
        lastError: 'Sell order ${update.event.name} for ${pending.symbol}',
      ),
    );
    _refreshStatus();
  }

  Future<void> _ensureRecoveredPositionProtection(
    QuickTradePosition pos,
  ) async {
    bool protected;
    try {
      protected = await _syncProtectionStop(
        pos,
        qty: pos.qty,
        reason: 'Recovered position protection',
      );
    } catch (e) {
      Log.e('QuickTradeEngine', 'CRITICAL: Stop-loss placement failed for ${pos.symbol}, forcing close', e);
      protected = false;
    }
    if (!protected) {
      try {
        await _forceCloseUnprotectedPosition(
          pos,
          'Recovered position missing broker stop-loss protection',
        );
      } catch (e) {
        Log.e('QuickTradeEngine', 'CRITICAL: Fallback close also failed for ${pos.symbol}, attempting market close', e);
        await _requestClosePosition(pos, 'Emergency close: stop-loss and fallback both failed');
      }
    }
  }

  Future<bool> _syncProtectionStop(
    QuickTradePosition pos, {
    double? qty,
    required String reason,
  }) async {
    if (_symbolsClosing.contains(pos.symbol)) return false;
    if (_symbolsUpdatingProtection.contains(pos.symbol)) return pos.isProtected;

    _symbolsUpdatingProtection.add(pos.symbol);
    try {
      final requestedQty = qty ?? pos.qty;
      if (requestedQty <= 0) return false;

      // Alpaca rejects stop orders on fractional shares in live accounts.
      // For fractional positions, rely entirely on the in-process exit
      // engine (_checkExitConditions on each price tick). Treat as
      // "protected" so callers don't force-close — the price-stream-driven
      // close is the safety net. Trade-off: if the app/background service
      // dies, fractional positions are exposed to gap risk.
      if (_isFractionalQty(requestedQty)) {
        if (pos.stopLossOrderId != null) {
          // Stale broker stop from a previous (whole-qty) state — clean up.
          try {
            await _client.cancelOrder(pos.stopLossOrderId!);
          } catch (e) {
            Log.d('QuickTradeEngine',
                'Fractional cleanup: cancel stop ${pos.stopLossOrderId} failed for ${pos.symbol}: $e');
          }
          pos.stopLossOrderId = null;
        }
        Log.i(
          'QuickTradeEngine',
          'Fractional qty ${requestedQty.toStringAsFixed(4)} for ${pos.symbol} — '
          'broker stop skipped (rejected on live), in-process exit only',
        );
        return true;
      }

      final stopOrderId = await _upsertStopLossOrder(
        symbol: pos.symbol,
        qty: requestedQty,
        stopPrice: pos.stopPrice,
        existingOrderId: pos.stopLossOrderId,
      );
      if (stopOrderId == null) {
        Log.e(
          'QuickTradeEngine',
          'Stop protection failed for ${pos.symbol}',
          reason,
        );
        return false;
      }
      pos.stopLossOrderId = stopOrderId;
      return true;
    } finally {
      _symbolsUpdatingProtection.remove(pos.symbol);
    }
  }

  /// True when qty is not a whole share (within float tolerance). Alpaca
  /// rejects stop orders for fractional qty on live accounts.
  static bool _isFractionalQty(double qty) {
    return (qty - qty.roundToDouble()).abs() > 1e-6;
  }

  Future<String?> _upsertStopLossOrder({
    required String symbol,
    required double qty,
    required double stopPrice,
    required String? existingOrderId,
  }) async {
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        if (existingOrderId != null) {
          final replaced = await _client.replaceOrder(
            existingOrderId,
            qty: qty,
            stopPrice: stopPrice,
          );
          return replaced['id'] as String?;
        }
        final created = await _client.placeOrder(
          symbol: symbol,
          qty: qty,
          side: 'sell',
          type: 'stop',
          timeInForce: 'gtc',
          stopPrice: stopPrice,
        );
        return created['id'] as String?;
      } catch (e) {
        Log.w(
          'QuickTradeEngine',
          'Stop protection attempt $attempt failed for $symbol: $e',
        );
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(milliseconds: 250 * attempt));
        }
      }
    }
    return null;
  }

  Future<void> _failClosedOnProtectionError(
    _PendingQuickTradeBuy pending,
    QuickTradePosition pos,
    String reason,
  ) async {
    _pendingBuys.remove(pending.orderId);
    try {
      await _client.cancelOrder(pending.orderId);
    } catch (e) {
      Log.w(
        'QuickTradeEngine',
        'Cancel pending buy failed for ${pending.symbol}: $e',
      );
    }
    try {
      await _forceCloseUnprotectedPosition(pos, reason);
    } catch (e) {
      Log.e('QuickTradeEngine', 'CRITICAL: Fallback close failed for ${pos.symbol}, attempting market close', e);
      await _requestClosePosition(pos, 'Emergency close: stop-loss and fallback both failed');
    }
  }

  Future<void> _forceCloseUnprotectedPosition(
    QuickTradePosition pos,
    String reason,
  ) async {
    _logTrade(
      TradeLog(
        ticker: pos.symbol,
        action: TradeAction.skip,
        orderId: pos.orderId,
        roundTripId: pos.roundTripId,
        reasoning: reason,
        signal: _buildSignal(pos.symbol, reason),
        createdAt: DateTime.now(),
      ),
    );
    await _requestClosePosition(pos, reason);
  }
}

class _TradeRound {
  final double entryPrice;
  final double exitPrice;
  final int holdSeconds;

  const _TradeRound({
    required this.entryPrice,
    required this.exitPrice,
    required this.holdSeconds,
  });

  double get pnlPercent => entryPrice == 0 ? 0 : (exitPrice - entryPrice) / entryPrice;
}

class _CompletedRound {
  final EntryType entryType;
  final double pnl;
  final String symbol;

  const _CompletedRound({required this.entryType, required this.pnl, required this.symbol});
}

class _RecoveredRound {
  final String roundTripId;
  final String symbol;
  final String? buyOrderId;
  final double entryPrice;
  final DateTime? entryTime;
  final EntryType entryType;
  final String entryReasoning;
  final String signalReasoning;
  final bool isClosed;

  const _RecoveredRound({
    required this.roundTripId,
    required this.symbol,
    required this.buyOrderId,
    required this.entryPrice,
    required this.entryTime,
    required this.entryType,
    required this.entryReasoning,
    required this.signalReasoning,
    required this.isClosed,
  });

  _RecoveredRound copyWith({bool? isClosed}) {
    return _RecoveredRound(
      roundTripId: roundTripId,
      symbol: symbol,
      buyOrderId: buyOrderId,
      entryPrice: entryPrice,
      entryTime: entryTime,
      entryType: entryType,
      entryReasoning: entryReasoning,
      signalReasoning: signalReasoning,
      isClosed: isClosed ?? this.isClosed,
    );
  }
}

class _PendingQuickTradeBuy {
  final String symbol;
  final String orderId;
  final String roundTripId;
  final double reservedDollars;
  final double submittedPrice;
  final EntryType entryType;
  final DateTime submittedAt;
  final double takeProfitPercent;
  final double stopLossPercent;
  final String entryDescription;
  final String signalDescription;
  final String historyNote;
  double accountedQty;
  double accountedCost;

  _PendingQuickTradeBuy({
    required this.symbol,
    required this.orderId,
    required this.roundTripId,
    required this.reservedDollars,
    required this.submittedPrice,
    required this.entryType,
    required this.submittedAt,
    required this.takeProfitPercent,
    required this.stopLossPercent,
    required this.entryDescription,
    required this.signalDescription,
    required this.historyNote,
  }) : accountedQty = 0,
       accountedCost = 0;
}

class _PendingQuickTradeSell {
  final String orderId;
  final String symbol;
  final QuickTradePosition position;
  final DateTime requestedAt;
  final String reason;
  double accountedQty;
  double? accountedAvgPrice;

  _PendingQuickTradeSell({
    required this.orderId,
    required this.symbol,
    required this.position,
    required this.requestedAt,
    required this.reason,
  }) : accountedQty = 0;
}
