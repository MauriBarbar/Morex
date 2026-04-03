import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/api/claude_client.dart';
import 'package:morex/core/api/news_client.dart';
import 'package:morex/engine/sentiment_analyzer.dart';

final newsClientProvider = Provider<NewsClient>((ref) => NewsClient());

final claudeClientProvider = Provider<ClaudeClient>((ref) => ClaudeClient());

final sentimentAnalyzerProvider = Provider<SentimentAnalyzer>((ref) {
  return SentimentAnalyzer(
    newsClient: ref.watch(newsClientProvider),
    claudeClient: ref.watch(claudeClientProvider),
  );
});

final scanResultProvider = StateProvider<ScanResult?>((ref) => null);
final isScanningProvider = StateProvider<bool>((ref) => false);
