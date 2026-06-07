import 'package:flutter_test/flutter_test.dart';
import 'package:morex/engine/order_monitor.dart';

void main() {
  group('OrderUpdate', () {
    test('isFilled returns true for fill event', () {
      final update = OrderUpdate(
        orderId: 'order-1',
        symbol: 'AAPL',
        side: 'buy',
        event: OrderEvent.fill,
        filledQty: 10,
        filledAvgPrice: 195.50,
        timestamp: DateTime.now(),
      );

      expect(update.isFilled, isTrue);
      expect(update.isFailed, isFalse);
    });

    test('isFailed returns true for canceled event', () {
      final update = OrderUpdate(
        orderId: 'order-2',
        symbol: 'GOOG',
        side: 'sell',
        event: OrderEvent.canceled,
        timestamp: DateTime.now(),
      );

      expect(update.isFilled, isFalse);
      expect(update.isFailed, isTrue);
    });

    test('isFailed returns true for rejected event', () {
      final update = OrderUpdate(
        orderId: 'order-3',
        symbol: 'MSFT',
        side: 'buy',
        event: OrderEvent.rejected,
        timestamp: DateTime.now(),
      );

      expect(update.isFailed, isTrue);
    });

    test('isFailed returns true for expired event', () {
      final update = OrderUpdate(
        orderId: 'order-4',
        symbol: 'TSLA',
        side: 'buy',
        event: OrderEvent.expired,
        timestamp: DateTime.now(),
      );

      expect(update.isFailed, isTrue);
    });

    test('newOrder is neither filled nor failed', () {
      final update = OrderUpdate(
        orderId: 'order-5',
        symbol: 'NVDA',
        side: 'buy',
        event: OrderEvent.newOrder,
        timestamp: DateTime.now(),
      );

      expect(update.isFilled, isFalse);
      expect(update.isFailed, isFalse);
    });

    test('partialFill is neither filled nor failed', () {
      final update = OrderUpdate(
        orderId: 'order-6',
        symbol: 'AMZN',
        side: 'buy',
        event: OrderEvent.partialFill,
        filledQty: 5,
        filledAvgPrice: 180.0,
        timestamp: DateTime.now(),
      );

      expect(update.isFilled, isFalse);
      expect(update.isFailed, isFalse);
    });

    test('optional fields default to null', () {
      final update = OrderUpdate(
        orderId: 'order-7',
        symbol: 'META',
        side: 'sell',
        event: OrderEvent.newOrder,
        timestamp: DateTime.now(),
      );

      expect(update.filledQty, isNull);
      expect(update.filledAvgPrice, isNull);
    });
  });

  group('OrderEvent', () {
    test('has all expected values', () {
      expect(OrderEvent.values, hasLength(6));
      expect(OrderEvent.values, contains(OrderEvent.newOrder));
      expect(OrderEvent.values, contains(OrderEvent.fill));
      expect(OrderEvent.values, contains(OrderEvent.partialFill));
      expect(OrderEvent.values, contains(OrderEvent.canceled));
      expect(OrderEvent.values, contains(OrderEvent.rejected));
      expect(OrderEvent.values, contains(OrderEvent.expired));
    });
  });
}
