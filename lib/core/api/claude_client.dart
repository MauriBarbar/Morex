import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:morex/config/env.dart';
import 'package:morex/core/models/news_item.dart';
import 'package:morex/core/models/signal.dart';

class ClaudeClient {
  late final Dio _dio;

  ClaudeClient() {
    _dio = Dio(
      BaseOptions(
        baseUrl: 'https://api.anthropic.com',
        headers: {
          'x-api-key': Env.claudeApiKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
      ),
    );
  }

  Future<List<Signal>> analyzeNews(List<NewsItem> news) async {
    if (news.isEmpty) return [];

    final newsText = news.take(20).map((n) {
      return '- [${n.source}] ${n.title}\n  ${n.summary}';
    }).join('\n\n');

    final prompt = '''You are a long-term value investment analyst. Analyze these financial news headlines and summaries. Identify stocks/ETFs that may be affected.

Focus on:
- Material events (earnings, mergers, regulation, macro shifts)
- Ignore noise (opinion pieces, speculation without substance)
- Think in terms of weeks/months, not minutes

News:
$newsText

Respond ONLY with valid JSON in this exact format, no other text:
{
  "signals": [
    {
      "ticker": "AAPL",
      "sentiment": "bullish",
      "confidence": 0.82,
      "timeframe": "medium",
      "reasoning": "Brief explanation",
      "source_headlines": ["Relevant headline 1"]
    }
  ]
}

Rules:
- ticker: US stock ticker symbol
- sentiment: "bullish", "bearish", or "neutral"
- confidence: 0.0 to 1.0 (be conservative, most should be below 0.7)
- timeframe: "short" (<1 week), "medium" (1-4 weeks), "long" (1+ months)
- Only include signals where you have genuine conviction
- If no clear signals, return {"signals": []}''';

    final response = await _dio.post(
      '/v1/messages',
      data: {
        'model': 'claude-sonnet-4-20250514',
        'max_tokens': 1024,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      },
    );

    return _parseResponse(response.data);
  }

  List<Signal> _parseResponse(Map<String, dynamic> responseData) {
    try {
      final content = responseData['content'] as List;
      final text = content.first['text'] as String;

      // Extract JSON from response (handle markdown code blocks)
      final jsonStr = text.contains('{')
          ? text.substring(text.indexOf('{'), text.lastIndexOf('}') + 1)
          : text;

      final parsed = json.decode(jsonStr) as Map<String, dynamic>;
      final signals = parsed['signals'] as List? ?? [];

      return signals
          .map((s) => Signal.fromJson(s as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }
}
