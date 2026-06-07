import 'package:flutter_test/flutter_test.dart';
import 'package:morex/backtest/backtest_simulator.dart';
import 'package:morex/backtest/backtest_strategy.dart';
import 'package:morex/core/models/historical_bar.dart';

BarsFetcher _fakeFetcher(Map<String, List<HistoricalBar>> bars) {
  return (
    List<String> symbols, {
    String timeframe = '1Day',
    int limit = 10000,
    DateTime? start,
    DateTime? end,
  }) async =>
      {for (final s in symbols) if (bars.containsKey(s)) s: bars[s]!};
}

HistoricalBar _bar(int day, double open, double close,
        {double? high, double? low}) =>
    HistoricalBar(
      timestamp: DateTime(2026, 1, day),
      open: open,
      high: high ?? (open > close ? open : close),
      low: low ?? (open < close ? open : close),
      close: close,
      volume: 1_000_000,
    );

void main() {
  group('BacktestSimulator', () {
    test('produces no trades when not enough history', () async {
      final sim = BacktestSimulator(
        barsFetcher: _fakeFetcher({
          'AAPL': List.generate(5, (i) => _bar(i + 1, 100, 100)),
        }),
      );
      final report = await sim.run(BacktestConfig(
        symbols: ['AAPL'],
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 31),
        strategy: DipBuyStrategy(),
        initialCapital: 10000,
        slippage: 0,
      ));
      expect(report.totalTrades, 0);
    });

    test('round-trip: dip → entry next bar → take-profit exit', () async {
      // 25 flat bars at $100 → rolling high = $100.
      // Bar 26: closes at $98 (-2%, exceeds 1.5% dip threshold) → entry signal.
      // Bar 27: opens at $98, fills entry. TP target = $98 × 1.015 = $99.47.
      //         Bar 27 high = $100 → TP fires. Exit at $99.47.
      final bars = <HistoricalBar>[
        ...List.generate(25, (i) => _bar(i + 1, 100, 100)),
        _bar(26, 100, 98, high: 100, low: 98),
        _bar(27, 98, 99.5, high: 100, low: 98),
      ];
      final sim = BacktestSimulator(
        barsFetcher: _fakeFetcher({'AAPL': bars}),
      );
      final report = await sim.run(BacktestConfig(
        symbols: ['AAPL'],
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 31),
        strategy: DipBuyStrategy(
            dipThreshold: 0.015,
            takeProfitPercent: 0.015,
            stopLossPercent: 0.01,
            rollingHighWindow: 20,
            minBarsBeforeEntry: 20,
            maxHoldDays: 5),
        initialCapital: 10000,
        slippage: 0, // simplify arithmetic
        secFeeRate: 0,
        finraTafPerShare: 0,
        dollarsPerTrade: 980,
      ));

      expect(report.totalTrades, 1);
      final t = report.trades.single;
      expect(t.entryPrice, 98);
      expect(t.exitPrice, closeTo(99.47, 0.01));
      expect(t.qty, 10); // floor(980 / 98) = 10
      expect(t.exitReason, 'Take profit');
      expect(t.isWin, isTrue);
    });

    test('round-trip: stop loss takes worst-case fill at stop price',
        () async {
      // Bar 26 dip → bar 27 entry @ open 98 → next bar smashes through stop
      // (98 × 0.99 = $97.02). Bar 28 low = $96 → SL fires at $97.02, not $96.
      final bars = <HistoricalBar>[
        ...List.generate(25, (i) => _bar(i + 1, 100, 100)),
        _bar(26, 100, 98, high: 100, low: 98),
        _bar(27, 98, 97.5, high: 98.5, low: 97.3),
        _bar(28, 97.3, 96, high: 97.3, low: 95),
      ];
      final sim = BacktestSimulator(
        barsFetcher: _fakeFetcher({'AAPL': bars}),
      );
      final report = await sim.run(BacktestConfig(
        symbols: ['AAPL'],
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 31),
        strategy: DipBuyStrategy(),
        initialCapital: 10000,
        slippage: 0,
        secFeeRate: 0,
        finraTafPerShare: 0,
        dollarsPerTrade: 980,
      ));

      expect(report.totalTrades, 1);
      final t = report.trades.single;
      expect(t.exitPrice, closeTo(97.02, 0.01));
      expect(t.exitReason, 'Stop loss');
      expect(t.isWin, isFalse);
    });

    test('aggregate stats reflect all trades correctly', () async {
      // Symbol that wins, symbol that loses → check report aggregation.
      final winBars = <HistoricalBar>[
        ...List.generate(25, (i) => _bar(i + 1, 100, 100)),
        _bar(26, 100, 98, high: 100, low: 98),
        _bar(27, 98, 99.5, high: 100, low: 98),
      ];
      final loseBars = <HistoricalBar>[
        ...List.generate(25, (i) => _bar(i + 1, 100, 100)),
        _bar(26, 100, 98, high: 100, low: 98),
        _bar(27, 98, 96, high: 98, low: 95),
      ];
      final sim = BacktestSimulator(
        barsFetcher: _fakeFetcher({'WIN': winBars, 'LOSE': loseBars}),
      );
      final report = await sim.run(BacktestConfig(
        symbols: ['WIN', 'LOSE'],
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 31),
        strategy: DipBuyStrategy(),
        initialCapital: 10000,
        slippage: 0,
        secFeeRate: 0,
        finraTafPerShare: 0,
        dollarsPerTrade: 980,
      ));
      expect(report.totalTrades, 2);
      expect(report.wins, 1);
      expect(report.losses, 1);
      expect(report.winRate, 0.5);
      expect(report.bySymbol['WIN']!.netPnl, greaterThan(0));
      expect(report.bySymbol['LOSE']!.netPnl, lessThan(0));
    });

    test('open position at end of range is force-closed', () async {
      // Dip on the last bar → entry signal but no next bar to fill.
      // Should produce zero trades.
      final bars = <HistoricalBar>[
        ...List.generate(25, (i) => _bar(i + 1, 100, 100)),
        _bar(26, 100, 98, high: 100, low: 98),
      ];
      final sim = BacktestSimulator(
        barsFetcher: _fakeFetcher({'AAPL': bars}),
      );
      final report = await sim.run(BacktestConfig(
        symbols: ['AAPL'],
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 31),
        strategy: DipBuyStrategy(),
        initialCapital: 10000,
        slippage: 0,
        dollarsPerTrade: 980,
      ));
      expect(report.totalTrades, 0);
    });

    test('skips when budget is below price-per-share', () async {
      // $50 budget on $100 stock → floor(50/100) = 0 → no entry.
      final bars = <HistoricalBar>[
        ...List.generate(25, (i) => _bar(i + 1, 100, 100)),
        _bar(26, 100, 98, high: 100, low: 98),
        _bar(27, 98, 99, high: 100, low: 98),
      ];
      final sim = BacktestSimulator(
        barsFetcher: _fakeFetcher({'AAPL': bars}),
      );
      final report = await sim.run(BacktestConfig(
        symbols: ['AAPL'],
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 31),
        strategy: DipBuyStrategy(),
        initialCapital: 100,
        slippage: 0,
        dollarsPerTrade: 50,
      ));
      expect(report.totalTrades, 0);
    });
  });
}
