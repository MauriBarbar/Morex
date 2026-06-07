import 'package:flutter_test/flutter_test.dart';
import 'package:morex/backtest/backtest_strategy.dart';
import 'package:morex/core/models/historical_bar.dart';

HistoricalBar _bar(double open, double close,
        {double? high, double? low, DateTime? at}) =>
    HistoricalBar(
      timestamp: at ?? DateTime(2026, 1, 1),
      open: open,
      high: high ?? (open > close ? open : close),
      low: low ?? (open < close ? open : close),
      close: close,
      volume: 1000000,
    );

List<HistoricalBar> _flatBars(int n, double price) {
  return List.generate(
    n,
    (i) => _bar(price, price,
        at: DateTime(2026, 1, 1).add(Duration(days: i))),
  );
}

void main() {
  group('DipBuyStrategy — entries', () {
    test('does not enter without enough history', () {
      final strategy = DipBuyStrategy(rollingHighWindow: 20, minBarsBeforeEntry: 20);
      final history = _flatBars(5, 100);
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: history,
        openPosition: null,
      );
      expect(decision, isA<HoldDecision>());
    });

    test('does not enter when price is at or above rolling high', () {
      final strategy = DipBuyStrategy();
      final history = _flatBars(25, 100); // flat at 100
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: history,
        openPosition: null,
      );
      expect(decision, isA<HoldDecision>());
    });

    test('enters on a 1.5%+ drop from rolling high', () {
      final strategy = DipBuyStrategy(dipThreshold: 0.015);
      final history = [
        ..._flatBars(25, 100), // 25 days flat at 100 (rolling high = 100)
        _bar(100, 98, at: DateTime(2026, 2, 1)), // -2% drop
      ];
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: history,
        openPosition: null,
      );
      expect(decision, isA<EntryDecision>());
      final entry = decision as EntryDecision;
      expect(entry.takeProfitPercent, 0.015);
      expect(entry.stopLossPercent, 0.01);
    });

    test('does not enter on a tiny dip below threshold', () {
      final strategy = DipBuyStrategy(dipThreshold: 0.015);
      final history = [
        ..._flatBars(25, 100),
        _bar(100, 99.5, at: DateTime(2026, 2, 1)), // -0.5% drop
      ];
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: history,
        openPosition: null,
      );
      expect(decision, isA<HoldDecision>());
    });
  });

  group('DipBuyStrategy — exits', () {
    BacktestPosition makePos({
      double entry = 100,
      DateTime? entryTime,
    }) =>
        BacktestPosition(
          entryTime: entryTime ?? DateTime(2026, 1, 1),
          entryPrice: entry,
          qty: 5,
          stopPrice: entry * 0.99, // 99
          targetPrice: entry * 1.015, // 101.5
        );

    test('exits at stop loss when bar low pierces it', () {
      final strategy = DipBuyStrategy();
      final pos = makePos(entry: 100);
      final bar = _bar(100, 98, low: 98.5, at: DateTime(2026, 1, 2));
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: [bar],
        openPosition: pos,
      );
      expect(decision, isA<ExitDecision>());
      final exit = decision as ExitDecision;
      expect(exit.exitPrice, 99); // stop price, not bar.low
      expect(exit.reason, 'Stop loss');
    });

    test('exits at take profit when bar high reaches it', () {
      final strategy = DipBuyStrategy();
      final pos = makePos(entry: 100);
      final bar = _bar(100, 101, high: 101.6, at: DateTime(2026, 1, 2));
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: [bar],
        openPosition: pos,
      );
      expect(decision, isA<ExitDecision>());
      final exit = decision as ExitDecision;
      expect(exit.exitPrice, closeTo(101.5, 1e-9)); // target price, not bar.high
      expect(exit.reason, 'Take profit');
    });

    test('prefers stop loss over take profit when both fire in same bar', () {
      // Conservative ordering — assume worst case (SL fires first).
      final strategy = DipBuyStrategy();
      final pos = makePos(entry: 100);
      final bar = _bar(100, 100,
          high: 102, low: 98, at: DateTime(2026, 1, 2));
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: [bar],
        openPosition: pos,
      );
      expect(decision, isA<ExitDecision>());
      final exit = decision as ExitDecision;
      expect(exit.reason, 'Stop loss');
    });

    test('exits at close after maxHoldDays elapsed', () {
      final strategy = DipBuyStrategy(maxHoldDays: 5);
      final pos = makePos(entry: 100, entryTime: DateTime(2026, 1, 1));
      final bar = _bar(100.5, 100.7,
          high: 101, low: 100, at: DateTime(2026, 1, 7));
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: [bar],
        openPosition: pos,
      );
      expect(decision, isA<ExitDecision>());
      final exit = decision as ExitDecision;
      expect(exit.reason, 'Max hold reached');
      expect(exit.exitPrice, 100.7);
    });

    test('holds when no exit condition met', () {
      final strategy = DipBuyStrategy();
      final pos = makePos(entry: 100);
      final bar = _bar(100, 100.5,
          high: 100.8, low: 99.5, at: DateTime(2026, 1, 2));
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: [bar],
        openPosition: pos,
      );
      expect(decision, isA<HoldDecision>());
    });
  });

  group('BreakoutStrategy — entries', () {
    /// 30 bars rising from 90 → 100, then today closes at 101 (above prior
    /// 30-bar high of 100). With rising momentum and bullish day, should
    /// trigger entry.
    List<HistoricalBar> _risingBars({double endClose = 101}) {
      final bars = <HistoricalBar>[];
      for (var i = 0; i < 30; i++) {
        final price = 90.0 + i * (10.0 / 29);
        bars.add(_bar(price - 0.1, price,
            high: price + 0.1,
            low: price - 0.2,
            at: DateTime(2026, 1, 1).add(Duration(days: i))));
      }
      // Today: close above the prior 30-bar high (100).
      bars.add(_bar(100, endClose,
          high: endClose + 0.1,
          low: 99.9,
          at: DateTime(2026, 2, 1)));
      return bars;
    }

    test('enters on breakout with rising momentum and bullish day', () {
      final strategy = BreakoutStrategy();
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: _risingBars(endClose: 101),
        openPosition: null,
      );
      expect(decision, isA<EntryDecision>());
      final entry = decision as EntryDecision;
      expect(entry.takeProfitPercent, 0.05);
      expect(entry.stopLossPercent, 0.02);
    });

    test('does not enter when close is below the prior rolling high', () {
      final strategy = BreakoutStrategy();
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: _risingBars(endClose: 99), // below prior high 100
        openPosition: null,
      );
      expect(decision, isA<HoldDecision>());
    });

    test('does not enter on a bearish day even if at the high', () {
      // Build bars where today closes at the prior high but open > close.
      final bars = <HistoricalBar>[];
      for (var i = 0; i < 30; i++) {
        final price = 90.0 + i * (10.0 / 29);
        bars.add(_bar(price - 0.1, price,
            high: price + 0.1,
            low: price - 0.2,
            at: DateTime(2026, 1, 1).add(Duration(days: i))));
      }
      bars.add(_bar(102, 100.5,
          high: 102, low: 100.4, at: DateTime(2026, 2, 1))); // close < open
      final strategy = BreakoutStrategy();
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: bars,
        openPosition: null,
      );
      expect(decision, isA<HoldDecision>());
    });

    test('does not enter when momentum is flat (no rising trend)', () {
      // Build bars that hover flat at 100 — no rising momentum, even
      // though today might exceed the rolling high.
      final flat = List.generate(
        30,
        (i) => _bar(100, 100,
            high: 100.05, low: 99.95,
            at: DateTime(2026, 1, 1).add(Duration(days: i))),
      );
      flat.add(_bar(100, 100.2,
          high: 100.3, low: 100, at: DateTime(2026, 2, 1)));
      final strategy = BreakoutStrategy();
      final decision = strategy.evaluate(
        symbol: 'AAPL',
        history: flat,
        openPosition: null,
      );
      expect(decision, isA<HoldDecision>());
    });
  });
}
