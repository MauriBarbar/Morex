import 'package:flutter_test/flutter_test.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/core/models/trade_log.dart';

void main() {
  group('TradeLog', () {
    late Signal signal;
    late TradeLog tradeLog;

    setUp(() {
      signal = Signal(
        ticker: 'AAPL',
        sentiment: Sentiment.bullish,
        confidence: 0.85,
        timeframe: Timeframe.medium,
        reasoning: 'Strong uptrend',
        sourceHeadlines: ['AAPL Rises'],
        createdAt: DateTime(2026, 4, 3),
      );

      tradeLog = TradeLog(
        ticker: 'AAPL',
        action: TradeAction.buy,
        qty: 10,
        price: 150.0,
        orderId: 'order123',
        reasoning: 'Bought 10 shares at \$150',
        signal: signal,
        createdAt: DateTime(2026, 4, 3),
      );
    });

    test('wasExecuted returns true for buy action', () {
      expect(tradeLog.wasExecuted, true);
    });

    test('wasExecuted returns true for sell action', () {
      final sellLog = TradeLog(
        ticker: 'AAPL',
        action: TradeAction.sell,
        reasoning: 'Sold position',
        signal: signal,
        createdAt: DateTime(2026, 4, 3),
      );
      expect(sellLog.wasExecuted, true);
    });

    test('wasExecuted returns false for skip action', () {
      final skipLog = TradeLog(
        ticker: 'AAPL',
        action: TradeAction.skip,
        reasoning: 'Risk too high',
        signal: signal,
        createdAt: DateTime(2026, 4, 3),
      );
      expect(skipLog.wasExecuted, false);
    });

    test('TradeLog with null qty and price is valid', () {
      final partialLog = TradeLog(
        ticker: 'TSLA',
        action: TradeAction.buy,
        reasoning: 'Order placed',
        signal: signal,
        createdAt: DateTime(2026, 4, 3),
      );

      expect(partialLog.qty, isNull);
      expect(partialLog.price, isNull);
      expect(partialLog.wasExecuted, true);
    });

    test('TradeLog with optional orderId', () {
      final withOrderId = TradeLog(
        ticker: 'MSFT',
        action: TradeAction.buy,
        orderId: 'order456',
        reasoning: 'Order submitted',
        signal: signal,
        createdAt: DateTime(2026, 4, 3),
      );

      expect(withOrderId.orderId, 'order456');
    });

    test('TradeLog without orderId is valid', () {
      final withoutOrderId = TradeLog(
        ticker: 'GOOGL',
        action: TradeAction.skip,
        reasoning: 'No order placed',
        signal: signal,
        createdAt: DateTime(2026, 4, 3),
      );

      expect(withoutOrderId.orderId, isNull);
    });

    test('TradeLog properties are accessible', () {
      expect(tradeLog.ticker, 'AAPL');
      expect(tradeLog.action, TradeAction.buy);
      expect(tradeLog.qty, 10);
      expect(tradeLog.price, 150.0);
      expect(tradeLog.orderId, 'order123');
      expect(tradeLog.reasoning, 'Bought 10 shares at \$150');
      expect(tradeLog.signal, signal);
    });

    test('Multiple TradeActions are distinct', () {
      expect(TradeAction.buy != TradeAction.sell, true);
      expect(TradeAction.sell != TradeAction.skip, true);
      expect(TradeAction.buy != TradeAction.skip, true);
    });
  });
}

