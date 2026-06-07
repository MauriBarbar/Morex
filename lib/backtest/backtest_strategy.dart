import 'package:morex/core/models/historical_bar.dart';

/// State of an open backtest position passed to the strategy on each bar.
class BacktestPosition {
  final DateTime entryTime;
  final double entryPrice;
  final double qty;
  final double stopPrice;
  final double targetPrice;

  const BacktestPosition({
    required this.entryTime,
    required this.entryPrice,
    required this.qty,
    required this.stopPrice,
    required this.targetPrice,
  });

  int holdBarsAt(DateTime now) =>
      now.difference(entryTime).inDays;
}

/// What the strategy wants to do on the current bar.
sealed class StrategyDecision {
  const StrategyDecision();
}

class HoldDecision extends StrategyDecision {
  const HoldDecision();
}

class EntryDecision extends StrategyDecision {
  /// TP/SL relative to entry, expressed as fractions (0.015 = 1.5%).
  final double takeProfitPercent;
  final double stopLossPercent;
  final int maxHoldDays;
  final String reason;

  const EntryDecision({
    required this.takeProfitPercent,
    required this.stopLossPercent,
    required this.maxHoldDays,
    required this.reason,
  });
}

class ExitDecision extends StrategyDecision {
  /// Price at which the simulator should record the exit. The strategy
  /// is responsible for honest pricing — e.g. for stop-out, return
  /// stopPrice (worst-case fill), not the bar's close.
  final double exitPrice;
  final String reason;

  const ExitDecision({
    required this.exitPrice,
    required this.reason,
  });
}

/// Strategy interface — pure function from market state to decision.
/// Implementations should be deterministic given the same inputs so
/// backtests are reproducible.
abstract class BacktestStrategy {
  /// Called once per bar per symbol. [history] contains all bars up to
  /// and including the current one (most recent last). [openPosition] is
  /// non-null when a position is open in this symbol.
  StrategyDecision evaluate({
    required String symbol,
    required List<HistoricalBar> history,
    required BacktestPosition? openPosition,
  });
}

/// Mean-reversion dip-buy strategy mirroring `quick_trade_engine`'s core
/// idea on daily bars: buy when price has dropped N% from a rolling high,
/// exit at TP/SL or after maxHoldDays. Designed to answer the basic
/// question "does dip-buying liquid mega-caps have edge?" — if this is
/// negative, fancier intraday variants likely are too.
class DipBuyStrategy extends BacktestStrategy {
  final double dipThreshold;
  final double takeProfitPercent;
  final double stopLossPercent;
  final int rollingHighWindow;
  final int maxHoldDays;
  final int minBarsBeforeEntry;

  DipBuyStrategy({
    this.dipThreshold = 0.015,
    this.takeProfitPercent = 0.015,
    this.stopLossPercent = 0.01,
    this.rollingHighWindow = 20,
    this.maxHoldDays = 5,
    this.minBarsBeforeEntry = 20,
  });

  @override
  StrategyDecision evaluate({
    required String symbol,
    required List<HistoricalBar> history,
    required BacktestPosition? openPosition,
  }) {
    if (history.isEmpty) return const HoldDecision();
    final current = history.last;

    // ----- Exit logic (priority: SL → TP → time) -----
    if (openPosition != null) {
      // Worst-case ordering within the bar: if both SL and TP could fire,
      // assume SL fires first (conservative).
      if (current.low <= openPosition.stopPrice) {
        return ExitDecision(
          exitPrice: openPosition.stopPrice,
          reason: 'Stop loss',
        );
      }
      if (current.high >= openPosition.targetPrice) {
        return ExitDecision(
          exitPrice: openPosition.targetPrice,
          reason: 'Take profit',
        );
      }
      if (openPosition.holdBarsAt(current.timestamp) >= maxHoldDays) {
        return ExitDecision(
          exitPrice: current.close,
          reason: 'Max hold reached',
        );
      }
      return const HoldDecision();
    }

    // ----- Entry logic -----
    if (history.length < minBarsBeforeEntry) return const HoldDecision();

    // Rolling high over the lookback window (excluding the current bar
    // would be more conservative; including it matches the live engine's
    // _rollingHighs which is updated live).
    final lookback = history
        .skip(history.length - rollingHighWindow)
        .map((b) => b.high)
        .reduce((a, b) => a > b ? a : b);

    final dropFromHigh = (lookback - current.close) / lookback;
    if (dropFromHigh >= dipThreshold) {
      return EntryDecision(
        takeProfitPercent: takeProfitPercent,
        stopLossPercent: stopLossPercent,
        maxHoldDays: maxHoldDays,
        reason: 'Dip ${(dropFromHigh * 100).toStringAsFixed(2)}% from $rollingHighWindow-bar high',
      );
    }

    return const HoldDecision();
  }
}

/// Breakout / trend-following strategy. The opposite of dip-buying: enter
/// when price closes at-or-near a rolling high *and* recent closes are
/// rising (momentum filter). The thesis: in trending markets (most equity
/// markets, most years), prices that break above recent highs continue
/// rising for at least a few days.
///
/// Wider TP and SL than the dip-buy variant, plus longer max-hold, because
/// trend continuations need room to develop — small TP/SL bands get
/// stopped out before the trend has time to show up.
class BreakoutStrategy extends BacktestStrategy {
  final double takeProfitPercent;
  final double stopLossPercent;
  final int rollingHighWindow;
  final int momentumWindow;
  final int maxHoldDays;
  final int minBarsBeforeEntry;

  /// How close to the rolling high counts as "breaking out". 0 = exactly
  /// at the high or above; 0.005 = within 0.5% below.
  final double proximityToHigh;

  BreakoutStrategy({
    this.takeProfitPercent = 0.05,
    this.stopLossPercent = 0.02,
    this.rollingHighWindow = 20,
    this.momentumWindow = 5,
    this.maxHoldDays = 10,
    this.minBarsBeforeEntry = 25,
    this.proximityToHigh = 0.001,
  });

  @override
  StrategyDecision evaluate({
    required String symbol,
    required List<HistoricalBar> history,
    required BacktestPosition? openPosition,
  }) {
    if (history.isEmpty) return const HoldDecision();
    final current = history.last;

    // Same exit logic as DipBuy — TP/SL/time. SL fires first if both could
    // fire in the same bar (worst-case).
    if (openPosition != null) {
      if (current.low <= openPosition.stopPrice) {
        return ExitDecision(
          exitPrice: openPosition.stopPrice,
          reason: 'Stop loss',
        );
      }
      if (current.high >= openPosition.targetPrice) {
        return ExitDecision(
          exitPrice: openPosition.targetPrice,
          reason: 'Take profit',
        );
      }
      if (openPosition.holdBarsAt(current.timestamp) >= maxHoldDays) {
        return ExitDecision(
          exitPrice: current.close,
          reason: 'Max hold reached',
        );
      }
      return const HoldDecision();
    }

    if (history.length < minBarsBeforeEntry) return const HoldDecision();

    // Rolling high over the lookback window, EXCLUDING the current bar —
    // we want to see whether today is breaking yesterday's high, not its
    // own high (which would always be true for an up-day).
    final priorBars = history.sublist(
      history.length - rollingHighWindow - 1,
      history.length - 1,
    );
    final priorHigh =
        priorBars.map((b) => b.high).reduce((a, b) => a > b ? a : b);

    final breakoutLevel = priorHigh * (1 - proximityToHigh);
    if (current.close < breakoutLevel) return const HoldDecision();

    // Momentum filter — last `momentumWindow` closes are rising. Compare
    // average of recent closes to the average of the prior block of equal
    // size; require at least a 0.5% improvement.
    final n = momentumWindow;
    if (history.length < 2 * n) return const HoldDecision();
    final recent = history.sublist(history.length - n).map((b) => b.close);
    final prior =
        history.sublist(history.length - 2 * n, history.length - n).map(
              (b) => b.close,
            );
    final recentAvg = recent.reduce((a, b) => a + b) / n;
    final priorAvg = prior.reduce((a, b) => a + b) / n;
    if (recentAvg <= priorAvg * 1.005) return const HoldDecision();

    // Today should also be a bullish day — close > open.
    if (current.close <= current.open) return const HoldDecision();

    return EntryDecision(
      takeProfitPercent: takeProfitPercent,
      stopLossPercent: stopLossPercent,
      maxHoldDays: maxHoldDays,
      reason: 'Breakout above $rollingHighWindow-bar high with momentum '
          '+${(((recentAvg - priorAvg) / priorAvg) * 100).toStringAsFixed(2)}%',
    );
  }
}
