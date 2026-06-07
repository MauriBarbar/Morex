import 'package:flutter_test/flutter_test.dart';
import 'package:morex/core/models/news_item.dart';

void main() {
  group('NewsItem', () {
    test('default category and reliability', () {
      final item = NewsItem(
        title: 'Test',
        summary: 'Summary',
        source: 'Test Source',
        url: 'https://example.com',
        publishedAt: DateTime.now(),
      );
      expect(item.category, NewsCategory.markets);
      expect(item.sourceReliability, 0.5);
      expect(item.relatedTickers, isEmpty);
    });

    test('ageMinutes reflects time since publish', () {
      final item = NewsItem(
        title: 'Old news',
        summary: '',
        source: 'Test',
        url: '',
        publishedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );
      expect(item.ageMinutes, greaterThanOrEqualTo(119));
      expect(item.ageMinutes, lessThanOrEqualTo(121));
    });

    test('relevanceScore is higher for fresh high-reliability items', () {
      final fresh = NewsItem(
        title: 'Breaking',
        summary: '',
        source: 'WSJ',
        url: '',
        publishedAt: DateTime.now(),
        sourceReliability: 0.95,
      );
      final stale = NewsItem(
        title: 'Old',
        summary: '',
        source: 'Blog',
        url: '',
        publishedAt: DateTime.now().subtract(const Duration(hours: 24)),
        sourceReliability: 0.3,
      );
      expect(fresh.relevanceScore, greaterThan(stale.relevanceScore));
    });

    test('relevanceScore decreases with age', () {
      final now = NewsItem(
        title: 'Now',
        summary: '',
        source: 'Test',
        url: '',
        publishedAt: DateTime.now(),
        sourceReliability: 0.8,
      );
      final hourAgo = NewsItem(
        title: 'Hour ago',
        summary: '',
        source: 'Test',
        url: '',
        publishedAt: DateTime.now().subtract(const Duration(hours: 1)),
        sourceReliability: 0.8,
      );
      expect(now.relevanceScore, greaterThan(hourAgo.relevanceScore));
    });

    test('relatedTickers are preserved', () {
      final item = NewsItem(
        title: 'NVDA soars',
        summary: 'AI spending',
        source: 'CNBC',
        url: '',
        publishedAt: DateTime.now(),
        relatedTickers: ['NVDA', 'AMD'],
      );
      expect(item.relatedTickers, ['NVDA', 'AMD']);
    });
  });

  group('NewsCategory', () {
    test('all categories exist', () {
      expect(NewsCategory.values, containsAll([
        NewsCategory.markets,
        NewsCategory.earnings,
        NewsCategory.macro,
        NewsCategory.analysis,
        NewsCategory.tech,
        NewsCategory.ticker,
      ]));
    });
  });
}
