enum Sentiment { bullish, bearish, neutral }

enum Timeframe { short, medium, long }

class Signal {
  final String ticker;
  final Sentiment sentiment;
  final double confidence;
  final Timeframe timeframe;
  final String reasoning;
  final List<String> sourceHeadlines;
  final DateTime createdAt;

  const Signal({
    required this.ticker,
    required this.sentiment,
    required this.confidence,
    required this.timeframe,
    required this.reasoning,
    required this.sourceHeadlines,
    required this.createdAt,
  });

  /// Shown in UI and eligible for manual execution.
  bool get isActionable => confidence >= 0.60;

  /// Auto-execution threshold — higher bar to avoid low-confidence auto-trades.
  bool get isAutoExecutable => confidence >= 0.75;

  factory Signal.fromJson(Map<String, dynamic> json) {
    return Signal(
      ticker: json['ticker'] ?? '',
      sentiment: Sentiment.values.firstWhere(
        (s) => s.name == json['sentiment'],
        orElse: () => Sentiment.neutral,
      ),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      timeframe: Timeframe.values.firstWhere(
        (t) => t.name == (json['timeframe'] ?? 'medium'),
        orElse: () => Timeframe.medium,
      ),
      reasoning: json['reasoning'] ?? '',
      sourceHeadlines: List<String>.from(json['source_headlines'] ?? []),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
