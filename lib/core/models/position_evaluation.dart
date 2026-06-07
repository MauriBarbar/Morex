enum EvalAction { hold, sell }

class PositionEvaluation {
  final String ticker;
  final EvalAction action;
  final double confidence;
  final String reasoning;

  const PositionEvaluation({
    required this.ticker,
    required this.action,
    required this.confidence,
    required this.reasoning,
  });

  bool get shouldSell => action == EvalAction.sell;

  factory PositionEvaluation.fromJson(Map<String, dynamic> json) {
    return PositionEvaluation(
      ticker: json['ticker'] ?? '',
      action: (json['action'] ?? '') == 'sell' ? EvalAction.sell : EvalAction.hold,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      reasoning: json['reasoning'] ?? '',
    );
  }
}
