import 'package:morex/core/api/claude_client.dart';
import 'package:morex/core/api/news_client.dart';
import 'package:morex/core/models/news_item.dart';
import 'package:morex/core/models/signal.dart';

class SentimentAnalyzer {
  final NewsClient _newsClient;
  final ClaudeClient _claudeClient;

  SentimentAnalyzer({
    required NewsClient newsClient,
    required ClaudeClient claudeClient,
  })  : _newsClient = newsClient,
        _claudeClient = claudeClient;

  Future<ScanResult> scan() async {
    final news = await _newsClient.fetchNews();
    final signals = await _claudeClient.analyzeNews(news);
    return ScanResult(news: news, signals: signals, scannedAt: DateTime.now());
  }
}

class ScanResult {
  final List<NewsItem> news;
  final List<Signal> signals;
  final DateTime scannedAt;

  const ScanResult({
    required this.news,
    required this.signals,
    required this.scannedAt,
  });

  List<Signal> get actionableSignals =>
      signals.where((s) => s.isActionable).toList();
}
