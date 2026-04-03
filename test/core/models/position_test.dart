import 'package:flutter_test/flutter_test.dart';
import 'package:morex/core/models/position.dart';

void main() {
  group('Position', () {
    late Position position;

    setUp(() {
      position = const Position(
        assetId: 'asset123',
        symbol: 'AAPL',
        qty: 100,
        avgEntryPrice: 150.0,
        currentPrice: 160.0,
        marketValue: 16000.0,
        unrealizedPnL: 1000.0,
        unrealizedPnLPercent: 6.67,
        side: 'long',
      );
    });

    test('isProfit returns true when unrealizedPnL >= 0', () {
      expect(position.isProfit, true);
    });

    test('isProfit returns false when unrealizedPnL < 0', () {
      final lossPosition = const Position(
        assetId: 'asset456',
        symbol: 'TSLA',
        qty: 50,
        avgEntryPrice: 200.0,
        currentPrice: 180.0,
        marketValue: 9000.0,
        unrealizedPnL: -1000.0,
        unrealizedPnLPercent: -10.0,
        side: 'long',
      );
      expect(lossPosition.isProfit, false);
    });

    test('isProfit returns true when unrealizedPnL is exactly 0', () {
      final breakEvenPosition = const Position(
        assetId: 'asset789',
        symbol: 'GOOGL',
        qty: 10,
        avgEntryPrice: 120.0,
        currentPrice: 120.0,
        marketValue: 1200.0,
        unrealizedPnL: 0.0,
        unrealizedPnLPercent: 0.0,
        side: 'long',
      );
      expect(breakEvenPosition.isProfit, true);
    });

    test('fromJson creates Position from JSON', () {
      final json = {
        'asset_id': 'asset999',
        'symbol': 'MSFT',
        'qty': '75',
        'avg_entry_price': '300',
        'current_price': '310',
        'market_value': '23250',
        'unrealized_pl': '750',
        'unrealized_plpc': '3.33',
        'side': 'long',
      };

      final positionFromJson = Position.fromJson(json);

      expect(positionFromJson.assetId, 'asset999');
      expect(positionFromJson.symbol, 'MSFT');
      expect(positionFromJson.qty, 75);
      expect(positionFromJson.avgEntryPrice, 300);
      expect(positionFromJson.currentPrice, 310);
      expect(positionFromJson.marketValue, 23250);
      expect(positionFromJson.unrealizedPnL, 750);
      expect(positionFromJson.unrealizedPnLPercent, closeTo(3.33, 0.01));
      expect(positionFromJson.side, 'long');
    });

    test('fromJson uses defaults for missing fields', () {
      final minimalJson = {'symbol': 'NFLX'};
      final positionFromJson = Position.fromJson(minimalJson);

      expect(positionFromJson.symbol, 'NFLX');
      expect(positionFromJson.assetId, '');
      expect(positionFromJson.qty, 0);
      expect(positionFromJson.avgEntryPrice, 0);
      expect(positionFromJson.side, 'long');
    });

    test('Position with short side is valid', () {
      final shortPosition = const Position(
        assetId: 'short123',
        symbol: 'XYZ',
        qty: -50,
        avgEntryPrice: 100.0,
        currentPrice: 95.0,
        marketValue: -4750.0,
        unrealizedPnL: 250.0,
        unrealizedPnLPercent: 5.26,
        side: 'short',
      );

      expect(shortPosition.side, 'short');
      expect(shortPosition.qty, -50);
      expect(shortPosition.isProfit, true);
    });

    test('Position properties are immutable', () {
      expect(position.symbol, 'AAPL');
      expect(position.qty, 100);
      expect(position.avgEntryPrice, 150.0);
    });
  });
}

