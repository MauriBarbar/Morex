/// A single completed round-trip from the backtester.
class BacktestTrade {
  final String symbol;
  final DateTime entryTime;
  final DateTime exitTime;
  final double entryPrice;
  final double exitPrice;
  final double qty;
  final double grossPnl;
  final double feesPaid;
  final String exitReason;

  const BacktestTrade({
    required this.symbol,
    required this.entryTime,
    required this.exitTime,
    required this.entryPrice,
    required this.exitPrice,
    required this.qty,
    required this.grossPnl,
    required this.feesPaid,
    required this.exitReason,
  });

  double get netPnl => grossPnl - feesPaid;
  double get holdDays => exitTime.difference(entryTime).inHours / 24.0;
  double get returnPercent =>
      entryPrice == 0 ? 0 : (exitPrice - entryPrice) / entryPrice * 100;
  bool get isWin => netPnl > 0;
}

/// Aggregate result of a backtest run. The headline stats are total return,
/// win rate, expectancy per trade, and max drawdown — these are the four
/// numbers that decide whether the strategy has any edge.
class BacktestReport {
  final List<BacktestTrade> trades;
  final double initialCapital;
  final DateTime? rangeStart;
  final DateTime? rangeEnd;

  const BacktestReport({
    required this.trades,
    required this.initialCapital,
    this.rangeStart,
    this.rangeEnd,
  });

  int get totalTrades => trades.length;
  int get wins => trades.where((t) => t.isWin).length;
  int get losses => totalTrades - wins;
  double get winRate => totalTrades == 0 ? 0 : wins / totalTrades;

  double get totalNetPnl =>
      trades.fold(0.0, (sum, t) => sum + t.netPnl);
  double get totalReturnPercent =>
      initialCapital == 0 ? 0 : totalNetPnl / initialCapital * 100;

  /// Average net P&L per trade — positive expectancy is the single number
  /// that matters most. Negative means you lose on average per round-trip.
  double get expectancy =>
      totalTrades == 0 ? 0 : totalNetPnl / totalTrades;

  double get avgWin {
    final w = trades.where((t) => t.isWin).toList();
    if (w.isEmpty) return 0;
    return w.fold(0.0, (s, t) => s + t.netPnl) / w.length;
  }

  double get avgLoss {
    final l = trades.where((t) => !t.isWin).toList();
    if (l.isEmpty) return 0;
    return l.fold(0.0, (s, t) => s + t.netPnl) / l.length;
  }

  /// Profit factor = sum(wins) / |sum(losses)|. > 1 is profitable.
  double get profitFactor {
    final winSum =
        trades.where((t) => t.isWin).fold(0.0, (s, t) => s + t.netPnl);
    final lossSum =
        trades.where((t) => !t.isWin).fold(0.0, (s, t) => s + t.netPnl);
    if (lossSum == 0) return winSum > 0 ? double.infinity : 0;
    return winSum / lossSum.abs();
  }

  /// Max peak-to-trough drawdown of the equity curve, as a percent of
  /// the running peak. The number that tells you what the worst stretch
  /// looked like — important if you'd actually want to live with it.
  double get maxDrawdownPercent {
    if (trades.isEmpty) return 0;
    final ordered = [...trades]
      ..sort((a, b) => a.exitTime.compareTo(b.exitTime));
    double equity = initialCapital;
    double peak = initialCapital;
    double maxDd = 0;
    for (final t in ordered) {
      equity += t.netPnl;
      if (equity > peak) peak = equity;
      final dd = peak == 0 ? 0.0 : (peak - equity) / peak;
      if (dd > maxDd) maxDd = dd;
    }
    return maxDd * 100;
  }

  /// Per-symbol stats for diagnosing which names actually generate edge
  /// vs which drag the aggregate down.
  Map<String, SymbolBreakdown> get bySymbol {
    final result = <String, SymbolBreakdown>{};
    for (final t in trades) {
      result.putIfAbsent(t.symbol, SymbolBreakdown.new).add(t);
    }
    return result;
  }

  String formatHuman() {
    final sb = StringBuffer();
    sb.writeln('═══════ Backtest Report ═══════');
    if (rangeStart != null && rangeEnd != null) {
      sb.writeln(
          'Range:        ${_fmtDate(rangeStart!)} → ${_fmtDate(rangeEnd!)}');
    }
    sb.writeln('Capital:      \$${initialCapital.toStringAsFixed(2)}');
    sb.writeln('Trades:       $totalTrades  ($wins W / $losses L)');
    sb.writeln(
        'Win rate:     ${(winRate * 100).toStringAsFixed(1)}%');
    sb.writeln('Net P&L:      \$${totalNetPnl.toStringAsFixed(2)}'
        '  (${totalReturnPercent >= 0 ? '+' : ''}${totalReturnPercent.toStringAsFixed(2)}%)');
    sb.writeln('Expectancy:   \$${expectancy.toStringAsFixed(2)} / trade');
    sb.writeln('Avg win:      \$${avgWin.toStringAsFixed(2)}');
    sb.writeln('Avg loss:     \$${avgLoss.toStringAsFixed(2)}');
    sb.writeln(
        'Profit factor: ${profitFactor.isInfinite ? '∞' : profitFactor.toStringAsFixed(2)}');
    sb.writeln(
        'Max drawdown: ${maxDrawdownPercent.toStringAsFixed(2)}%');
    sb.writeln('───── Per-symbol ─────');
    final symbols = bySymbol.entries.toList()
      ..sort((a, b) => b.value.netPnl.compareTo(a.value.netPnl));
    for (final entry in symbols) {
      final b = entry.value;
      sb.writeln(
          '  ${entry.key.padRight(6)} ${b.trades.toString().padLeft(3)} trades  '
          '${(b.winRate * 100).toStringAsFixed(0).padLeft(3)}% WR  '
          'P&L \$${b.netPnl.toStringAsFixed(2)}');
    }
    sb.writeln('═══════════════════════════════');
    return sb.toString();
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class SymbolBreakdown {
  int trades = 0;
  int wins = 0;
  double netPnl = 0;

  void add(BacktestTrade t) {
    trades++;
    if (t.isWin) wins++;
    netPnl += t.netPnl;
  }

  double get winRate => trades == 0 ? 0 : wins / trades;
}
