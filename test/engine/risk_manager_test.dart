import 'package:flutter_test/flutter_test.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/engine/risk_manager.dart';

void main() {
  group('RiskConfig', () {
    test('default values are sensible', () {
      const config = RiskConfig();
      expect(config.maxPositionPercent, 0.10);
      expect(config.maxTotalExposurePercent, 0.80);
      expect(config.stopLossPercent, 0.08);
      expect(config.minConfidence, 0.60);
      expect(config.dailyLossLimitPercent, 0.03);
      expect(config.maxOrderDollars, 1000);
      expect(config.maxHoldDays, 14);
    });

    test('custom values override defaults', () {
      const config = RiskConfig(
        maxPositionPercent: 0.05,
        minConfidence: 0.80,
        maxOrderDollars: 500,
      );
      expect(config.maxPositionPercent, 0.05);
      expect(config.minConfidence, 0.80);
      expect(config.maxOrderDollars, 500);
      // Unchanged defaults
      expect(config.stopLossPercent, 0.08);
    });
  });

  group('RiskCheck', () {
    test('approved check carries signal and reason', () {
      final signal = _makeSignal('AAPL', Sentiment.bullish, 0.85);
      final check = RiskCheck(
        signal: signal,
        approved: true,
        reason: 'All checks passed',
      );
      expect(check.approved, true);
      expect(check.signal.ticker, 'AAPL');
      expect(check.reason, contains('passed'));
    });

    test('rejected check carries rejection reason', () {
      final signal = _makeSignal('TSLA', Sentiment.bullish, 0.40);
      final check = RiskCheck(
        signal: signal,
        approved: false,
        reason: 'Confidence 40% below threshold 60%',
      );
      expect(check.approved, false);
      expect(check.reason, contains('Confidence'));
    });
  });
}

Signal _makeSignal(String ticker, Sentiment sentiment, double confidence) {
  return Signal(
    ticker: ticker,
    sentiment: sentiment,
    confidence: confidence,
    timeframe: Timeframe.medium,
    reasoning: 'Test signal',
    sourceHeadlines: [],
    createdAt: DateTime.now(),
  );
}
