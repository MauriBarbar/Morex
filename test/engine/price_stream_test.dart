import 'package:flutter_test/flutter_test.dart';
import 'package:morex/engine/price_stream.dart';

void main() {
  group('PriceUpdate', () {
    test('creates with required fields', () {
      final update = PriceUpdate(
        symbol: 'AAPL',
        price: 195.50,
        timestamp: DateTime(2026, 4, 4, 10, 30),
      );

      expect(update.symbol, 'AAPL');
      expect(update.price, 195.50);
      expect(update.bidPrice, isNull);
      expect(update.askPrice, isNull);
      expect(update.size, isNull);
    });

    test('creates with all fields', () {
      final update = PriceUpdate(
        symbol: 'GOOG',
        price: 175.00,
        bidPrice: 174.98,
        askPrice: 175.02,
        size: 100,
        timestamp: DateTime(2026, 4, 4, 10, 30),
      );

      expect(update.symbol, 'GOOG');
      expect(update.price, 175.00);
      expect(update.bidPrice, 174.98);
      expect(update.askPrice, 175.02);
      expect(update.size, 100);
    });

    test('timestamp is preserved', () {
      final ts = DateTime(2026, 4, 4, 14, 0, 0);
      final update = PriceUpdate(symbol: 'TSLA', price: 250.0, timestamp: ts);
      expect(update.timestamp, ts);
    });
  });
}
