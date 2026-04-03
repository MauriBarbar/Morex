import 'package:flutter_test/flutter_test.dart';
import 'package:morex/core/models/signal.dart';

void main() {
  group('Signal', () {
    late Signal signal;

    setUp(() {
      signal = Signal(
        ticker: 'AAPL',
        sentiment: Sentiment.bullish,
        confidence: 0.85,
        timeframe: Timeframe.medium,
        reasoning: 'Strong uptrend detected',
        sourceHeadlines: ['Apple Stock Rises', 'AAPL Breaking Records'],
        createdAt: DateTime(2026, 4, 3),
      );
    });

    test('isActionable returns true when confidence >= 0.75', () {
      expect(signal.isActionable, true);
    });

    test('isActionable returns false when confidence < 0.75', () {
      final lowConfidenceSignal = Signal(
        ticker: 'AAPL',
        sentiment: Sentiment.bullish,
        confidence: 0.70,
        timeframe: Timeframe.short,
        reasoning: 'Weak signal',
        sourceHeadlines: [],
        createdAt: DateTime(2026, 4, 3),
      );
      expect(lowConfidenceSignal.isActionable, false);
    });

    test('fromJson creates Signal from JSON', () {
      final json = {
        'ticker': 'TSLA',
        'sentiment': 'bullish',
        'confidence': 0.92,
        'timeframe': 'short',
        'reasoning': 'Earnings beat',
        'source_headlines': ['TSLA Beats Expectations'],
      };

      final signalFromJson = Signal.fromJson(json);

      expect(signalFromJson.ticker, 'TSLA');
      expect(signalFromJson.sentiment, Sentiment.bullish);
      expect(signalFromJson.confidence, 0.92);
      expect(signalFromJson.timeframe, Timeframe.short);
      expect(signalFromJson.reasoning, 'Earnings beat');
      expect(signalFromJson.sourceHeadlines, ['TSLA Beats Expectations']);
    });

    test('fromJson handles missing sentiment with neutral default', () {
      final json = {'ticker': 'GOOGL', 'sentiment': null};
      final signalFromJson = Signal.fromJson(json);
      expect(signalFromJson.sentiment, Sentiment.neutral);
    });

    test('fromJson handles missing confidence with 0 default', () {
      final json = {'ticker': 'MSFT'};
      final signalFromJson = Signal.fromJson(json);
      expect(signalFromJson.confidence, 0);
    });

    test('Signal properties are immutable', () {
      expect(signal.ticker, 'AAPL');
      expect(signal.sentiment, Sentiment.bullish);
      expect(signal.confidence, 0.85);
    });

    test('Signal with empty source headlines is valid', () {
      final emptyHeadlinesSignal = Signal(
        ticker: 'MSFT',
        sentiment: Sentiment.neutral,
        confidence: 0.5,
        timeframe: Timeframe.long,
        reasoning: 'No strong signals',
        sourceHeadlines: [],
        createdAt: DateTime(2026, 4, 3),
      );
      expect(emptyHeadlinesSignal.sourceHeadlines, isEmpty);
    });
  });
}

