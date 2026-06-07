import 'package:morex/core/api/claude_client.dart';
import 'package:morex/core/api/news_client.dart';
import 'package:morex/core/logger.dart';
import 'package:morex/core/models/news_item.dart';
import 'package:morex/core/models/signal.dart';

class SentimentAnalyzer {
  final NewsClient _newsClient;
  final ClaudeClient _claudeClient;

  /// Track seen headline fingerprints to avoid re-analyzing identical news.
  final Set<String> _seenHeadlines = {};

  /// Keep last scan result so callers can check if anything changed.
  ScanResult? _lastResult;

  SentimentAnalyzer({
    required NewsClient newsClient,
    required ClaudeClient claudeClient,
  })  : _newsClient = newsClient,
        _claudeClient = claudeClient;

  /// Scan for signals. Pass [force] = true to bypass headline deduplication
  /// (used for manual scans so the user always gets a fresh Claude analysis).
  Future<ScanResult> scan({double? accountEquity, bool force = false}) async {
    final allNews = await _newsClient.fetchNews();

    // Force mode: reset seen headlines so all current news is re-analyzed.
    if (force) _seenHeadlines.clear();

    // Filter to only headlines we haven't analyzed before
    final newNews = <NewsItem>[];
    for (final item in allNews) {
      final fingerprint = _fingerprint(item.title);
      if (_seenHeadlines.add(fingerprint)) {
        newNews.add(item);
      }
    }

    // Cap memory — keep only last 500 fingerprints
    if (_seenHeadlines.length > 500) {
      final excess = _seenHeadlines.length - 500;
      final toRemove = _seenHeadlines.take(excess).toList();
      _seenHeadlines.removeAll(toRemove);
    }

    if (newNews.isEmpty) {
      Log.i('SentimentAnalyzer',
          'No new headlines since last scan (${allNews.length} total, all seen)');
      return ScanResult(
        news: allNews,
        signals: _lastResult?.signals ?? [],
        scannedAt: DateTime.now(),
        skippedDueToDedup: true,
      );
    }

    Log.i('SentimentAnalyzer',
        '${newNews.length} new headlines out of ${allNews.length} total');

    final signals = await _claudeClient.analyzeNews(newNews, accountEquity: accountEquity);
    final result = ScanResult(
      news: allNews,
      signals: signals,
      scannedAt: DateTime.now(),
    );
    _lastResult = result;
    return result;
  }

  /// Normalize title for dedup — lowercase, strip non-alphanumeric.
  String _fingerprint(String title) {
    return title
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w]'), '')
        .trim();
  }
}

class ScanResult {
  final List<NewsItem> news;
  final List<Signal> signals;
  final DateTime scannedAt;

  /// True if no new headlines were found and Claude was not called.
  final bool skippedDueToDedup;

  const ScanResult({
    required this.news,
    required this.signals,
    required this.scannedAt,
    this.skippedDueToDedup = false,
  });

  List<Signal> get actionableSignals =>
      signals.where((s) => s.isActionable).toList();
}
