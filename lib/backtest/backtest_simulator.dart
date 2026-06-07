import 'package:morex/backtest/backtest_report.dart';
import 'package:morex/backtest/backtest_strategy.dart';
import 'package:morex/core/models/historical_bar.dart';

/// Function signature compatible with `AlpacaClient.getBars`. Decoupling
/// the simulator from `AlpacaClient` keeps the backtest package free of
/// Flutter transitive deps — the CLI runner can pass its own pure-Dart
/// implementation.
typedef BarsFetcher = Future<Map<String, List<HistoricalBar>>> Function(
  List<String> symbols, {
  String timeframe,
  int limit,
  DateTime? start,
  DateTime? end,
});

class BacktestConfig {
  final List<String> symbols;
  final DateTime start;
  final DateTime end;
  final double initialCapital;

  /// Per-side slippage as a fraction (0.001 = 10 bps). Applied as a
  /// pessimistic adjustment to fill prices: entries pay slippage, exits
  /// receive less. Realistic for liquid mega-caps; small caps are worse.
  final double slippage;

  /// SEC fee on sells (fraction of notional). Tiny per trade but
  /// compounds across hundreds of round-trips. As of 2024-25, ~0.0000278.
  final double secFeeRate;

  /// FINRA TAF on sells, $ per share, capped per-trade.
  final double finraTafPerShare;
  final double finraTafCap;

  /// Notional dollars per trade. v1 keeps this fixed for simplicity —
  /// matches the live engine's behaviour where `_orderSize` clamps to
  /// `maxOrderDollars` regardless of accumulated capital.
  final double dollarsPerTrade;

  /// Bar timeframe — passed to Alpaca's bars endpoint. Daily ('1Day')
  /// is the v1 default; 5-min ('5Min') would be needed for an honest
  /// intraday simulation but quintuples API calls.
  final String timeframe;

  /// Bars-per-fetch cap from Alpaca (10000). The simulator pages.
  static const int _alpacaBarLimit = 10000;

  final BacktestStrategy strategy;

  const BacktestConfig({
    required this.symbols,
    required this.start,
    required this.end,
    required this.strategy,
    this.initialCapital = 10000,
    this.slippage = 0.001,
    this.secFeeRate = 0.0000278,
    this.finraTafPerShare = 0.000166,
    this.finraTafCap = 9.27,
    this.dollarsPerTrade = 500,
    this.timeframe = '1Day',
  });
}

/// Replays historical bars symbol-by-symbol through the strategy, fills
/// orders at the next bar's open with slippage, and records every
/// completed round-trip. Each symbol is simulated independently — no
/// portfolio-level concurrency, so per-symbol stats are clean.
class BacktestSimulator {
  final BarsFetcher _fetchBars;

  BacktestSimulator({required BarsFetcher barsFetcher}) : _fetchBars = barsFetcher;

  Future<BacktestReport> run(BacktestConfig config) async {
    final allTrades = <BacktestTrade>[];

    // Fetch bars for all symbols in one call (Alpaca supports multi-symbol).
    final bars = await _fetchBars(
      config.symbols,
      timeframe: config.timeframe,
      limit: BacktestConfig._alpacaBarLimit,
      start: config.start,
      end: config.end,
    );

    for (final symbol in config.symbols) {
      final symBars = bars[symbol] ?? const <HistoricalBar>[];
      if (symBars.length < 2) continue; // need at least 2 bars to fill anything
      allTrades.addAll(_simulateSymbol(symbol, symBars, config));
    }

    return BacktestReport(
      trades: allTrades,
      initialCapital: config.initialCapital,
      rangeStart: config.start,
      rangeEnd: config.end,
    );
  }

  /// Walks a single symbol's bars. Fills entries on bar i+1's open
  /// (next-bar-open execution to avoid lookahead bias). Exits within
  /// the same bar that triggers them, at the strategy's stated exit
  /// price (worst-case for SL, target-price for TP, close for time).
  List<BacktestTrade> _simulateSymbol(
    String symbol,
    List<HistoricalBar> bars,
    BacktestConfig config,
  ) {
    final trades = <BacktestTrade>[];
    BacktestPosition? open;
    EntryDecision? pendingEntry;

    for (var i = 0; i < bars.length; i++) {
      final history = bars.sublist(0, i + 1);
      final current = bars[i];

      // 1. Fill any entry that was queued on the previous bar.
      if (pendingEntry != null && open == null) {
        final fillPrice = current.open * (1 + config.slippage);
        final qty = (config.dollarsPerTrade / fillPrice).floorToDouble();
        if (qty >= 1) {
          open = BacktestPosition(
            entryTime: current.timestamp,
            entryPrice: fillPrice,
            qty: qty,
            stopPrice: fillPrice * (1 - pendingEntry.stopLossPercent),
            targetPrice: fillPrice * (1 + pendingEntry.takeProfitPercent),
          );
        }
        pendingEntry = null;
      }

      // 2. Ask the strategy what to do with current state.
      final decision = config.strategy.evaluate(
        symbol: symbol,
        history: history,
        openPosition: open,
      );

      switch (decision) {
        case ExitDecision(:final exitPrice, :final reason):
          if (open != null) {
            final fillExit = exitPrice * (1 - config.slippage);
            trades.add(_buildTrade(
              symbol: symbol,
              pos: open,
              exitTime: current.timestamp,
              exitPrice: fillExit,
              reason: reason,
              config: config,
            ));
            open = null;
          }
        case EntryDecision():
          // Queue for next bar's open — never fill on the bar that
          // generated the signal (avoids lookahead bias).
          if (open == null) pendingEntry = decision;
        case HoldDecision():
          break;
      }
    }

    // Force-close any position still open at the end of the range, at
    // the final bar's close. Otherwise stats lie.
    if (open != null) {
      final finalBar = bars.last;
      trades.add(_buildTrade(
        symbol: symbol,
        pos: open,
        exitTime: finalBar.timestamp,
        exitPrice: finalBar.close * (1 - config.slippage),
        reason: 'End of range',
        config: config,
      ));
    }

    return trades;
  }

  BacktestTrade _buildTrade({
    required String symbol,
    required BacktestPosition pos,
    required DateTime exitTime,
    required double exitPrice,
    required String reason,
    required BacktestConfig config,
  }) {
    final grossPnl = (exitPrice - pos.entryPrice) * pos.qty;
    final secFee = exitPrice * pos.qty * config.secFeeRate;
    final taf = (pos.qty * config.finraTafPerShare).clamp(0, config.finraTafCap);
    final fees = secFee + taf;
    return BacktestTrade(
      symbol: symbol,
      entryTime: pos.entryTime,
      exitTime: exitTime,
      entryPrice: pos.entryPrice,
      exitPrice: exitPrice,
      qty: pos.qty,
      grossPnl: grossPnl,
      feesPaid: fees,
      exitReason: reason,
    );
  }
}
