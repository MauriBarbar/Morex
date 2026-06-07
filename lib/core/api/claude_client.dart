import 'package:morex/core/models/news_item.dart';
import 'package:morex/core/models/position_context.dart';
import 'package:morex/core/models/position_evaluation.dart';
import 'package:morex/core/models/signal.dart';

/// Rule-based signal analyzer — no external API required.
/// Replaces the previous Claude-powered implementation with keyword
/// sentiment scoring (news → signals) and quantitative exit logic
/// (positions → hold/sell recommendations).
class ClaudeClient {
  ClaudeClient();

  // ---------------------------------------------------------------------------
  // Bullish / bearish keyword tables
  // Each entry: (keyword, score)  — score in [-1.0, 1.0]
  // ---------------------------------------------------------------------------
  static const _bullishKeywords = <(String, double)>[
    // Strong catalysts
    ('beats estimates', 0.22),
    ('beats expectations', 0.22),
    ('earnings beat', 0.22),
    ('revenue beat', 0.20),
    ('record high', 0.18),
    ('record profit', 0.18),
    ('record revenue', 0.18),
    ('fda approves', 0.22),
    ('fda approved', 0.22),
    ('merger agreement', 0.18),
    ('acquisition complete', 0.16),
    ('exceeds expectations', 0.20),
    ('better than expected', 0.18),
    ('raises guidance', 0.18),
    ('raised guidance', 0.18),
    ('share buyback', 0.14),
    ('dividend increase', 0.14),
    // Medium signals
    ('upgraded', 0.12),
    ('upgrade', 0.10),
    ('strong results', 0.12),
    ('profit rises', 0.12),
    ('revenue rises', 0.10),
    ('deal signed', 0.12),
    ('contract win', 0.12),
    ('positive outlook', 0.10),
    ('outperforms', 0.12),
    // Weaker signals
    ('growth', 0.06),
    ('gains', 0.06),
    ('rises', 0.05),
    ('expands', 0.06),
    ('partnership', 0.07),
    ('strong demand', 0.08),
    ('positive', 0.04),
  ];

  static const _bearishKeywords = <(String, double)>[
    // Strong catalysts
    ('misses estimates', -0.22),
    ('misses expectations', -0.22),
    ('earnings miss', -0.22),
    ('revenue miss', -0.20),
    ('below expectations', -0.20),
    ('bankruptcy', -0.25),
    ('bankrupt', -0.25),
    ('fda rejects', -0.22),
    ('fda rejection', -0.22),
    ('recall', -0.20),
    ('securities fraud', -0.22),
    ('accounting fraud', -0.22),
    ('lowers guidance', -0.18),
    ('lowered guidance', -0.18),
    ('guidance cut', -0.18),
    // Medium signals
    ('downgraded', -0.12),
    ('downgrade', -0.10),
    ('investigation', -0.12),
    ('probe', -0.10),
    ('layoffs', -0.12),
    ('job cuts', -0.12),
    ('disappoints', -0.14),
    ('disappointing', -0.12),
    ('warns', -0.12),
    ('warning', -0.10),
    ('shortfall', -0.14),
    ('misses', -0.10),
    // Weaker signals
    ('loss', -0.06),
    ('drops', -0.06),
    ('declines', -0.05),
    ('struggles', -0.06),
    ('concern', -0.04),
    ('uncertainty', -0.04),
    ('slows', -0.05),
  ];

  // ---------------------------------------------------------------------------
  // analyzeNews — keyword scoring
  // ---------------------------------------------------------------------------

  Future<List<Signal>> analyzeNews(
    List<NewsItem> news, {
    double? accountEquity,
  }) async {
    if (news.isEmpty) return [];

    // Accumulate scores per ticker
    final Map<String, _TickerAgg> agg = {};

    for (final item in news) {
      if (item.relatedTickers.isEmpty) continue;

      final text = '${item.title} ${item.summary}'.toLowerCase();
      double score = _scoreText(text);
      if (score == 0.0) continue;

      // Weight by source reliability and recency
      final recencyBonus =
          item.ageMinutes < 60 ? 0.05 : (item.ageMinutes < 180 ? 0.02 : 0.0);
      score = score * item.sourceReliability + recencyBonus * score.sign;

      for (final ticker in item.relatedTickers) {
        agg.putIfAbsent(ticker, _TickerAgg.new).add(score, item.title);
      }
    }

    final signals = <Signal>[];

    for (final entry in agg.entries) {
      final t = entry.value;
      final avg = t.totalScore / t.count;
      final absAvg = avg.abs();

      // Ignore very weak or conflicting aggregate signals
      if (absAvg < 0.04) continue;

      // Confidence: base 0.50, scaled by strength, capped at 0.84
      final confidence = (0.50 + absAvg * 1.5).clamp(0.40, 0.84);
      final sentiment = avg > 0 ? Sentiment.bullish : Sentiment.bearish;

      // Prefer medium timeframe for news-driven signals
      final timeframe =
          absAvg > 0.18 ? Timeframe.short : Timeframe.medium;

      signals.add(Signal(
        ticker: entry.key,
        sentiment: sentiment,
        confidence: confidence,
        timeframe: timeframe,
        reasoning: _buildReasoning(sentiment, t.headlines),
        sourceHeadlines: t.headlines.take(3).toList(),
        createdAt: DateTime.now(),
      ));
    }

    // Sort strongest first, cap at 25
    signals.sort((a, b) => b.confidence.compareTo(a.confidence));
    return signals.take(25).toList();
  }

  double _scoreText(String text) {
    double score = 0.0;
    for (final (kw, s) in _bullishKeywords) {
      if (text.contains(kw)) score += s;
    }
    for (final (kw, s) in _bearishKeywords) {
      if (text.contains(kw)) score += s; // s is already negative
    }
    return score.clamp(-1.0, 1.0);
  }

  String _buildReasoning(Sentiment sentiment, List<String> headlines) {
    final direction = sentiment == Sentiment.bullish ? 'Bullish' : 'Bearish';
    final sample = headlines.take(2).join('; ');
    return '$direction signal from news: $sample';
  }

  // ---------------------------------------------------------------------------
  // evaluatePositions — quantitative rules
  // ---------------------------------------------------------------------------

  Future<List<PositionEvaluation>> evaluatePositions(
    List<PositionContext> contexts,
  ) async {
    return contexts.map(_evalOne).toList();
  }

  PositionEvaluation _evalOne(PositionContext c) {
    // Time overdue
    if (c.holdDays >= c.maxHoldDays) {
      return PositionEvaluation(
        ticker: c.symbol,
        action: EvalAction.sell,
        confidence: 0.82,
        reasoning:
            'Hold period reached: ${c.holdDays}d / ${c.maxHoldDays}d limit',
      );
    }

    // Deep loss
    if (c.pnlPercent <= -8.0) {
      return PositionEvaluation(
        ticker: c.symbol,
        action: EvalAction.sell,
        confidence: 0.88,
        reasoning:
            'Loss exceeds threshold: ${c.pnlPercent.toStringAsFixed(1)}%',
      );
    }

    // Moderate loss
    if (c.pnlPercent <= -5.0) {
      return PositionEvaluation(
        ticker: c.symbol,
        action: EvalAction.sell,
        confidence: 0.72,
        reasoning:
            'Approaching stop loss: ${c.pnlPercent.toStringAsFixed(1)}%',
      );
    }

    // Approaching time limit
    if (c.holdDays >= (c.maxHoldDays * 0.8).round()) {
      return PositionEvaluation(
        ticker: c.symbol,
        action: EvalAction.hold,
        confidence: 0.65,
        reasoning:
            'Near time limit (${c.holdDays}d / ${c.maxHoldDays}d) — monitor closely',
      );
    }

    // Healthy position
    return PositionEvaluation(
      ticker: c.symbol,
      action: EvalAction.hold,
      confidence: 0.70,
      reasoning:
          'Within parameters: ${c.pnlPercent.toStringAsFixed(1)}% P&L, '
          '${c.holdDays}d held',
    );
  }
}

// ---------------------------------------------------------------------------
// Internal aggregation helper
// ---------------------------------------------------------------------------

class _TickerAgg {
  double totalScore = 0.0;
  int count = 0;
  final List<String> headlines = [];

  void add(double score, String headline) {
    totalScore += score;
    count++;
    if (headlines.length < 5) headlines.add(headline);
  }
}
