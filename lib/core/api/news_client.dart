import 'package:dio/dio.dart';
import 'package:xml/xml.dart';
import 'package:morex/core/models/news_item.dart';

class NewsClient {
  final Dio _dio = Dio();

  static const _rssFeeds = {
    'Reuters': 'https://news.google.com/rss/topics/CAAqJggKIiBDQkFTRWdvSUwyMHZNRGx6TVdZU0FtVnVHZ0pWVXlnQVAB',
    'CNBC': 'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114',
    'MarketWatch': 'https://feeds.marketwatch.com/marketwatch/topstories/',
  };

  Future<List<NewsItem>> fetchNews() async {
    final allItems = <NewsItem>[];

    for (final entry in _rssFeeds.entries) {
      try {
        final items = await _fetchRssFeed(entry.key, entry.value);
        allItems.addAll(items);
      } catch (_) {
        // Skip failing feeds silently
      }
    }

    // Sort by date, newest first
    allItems.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
    return allItems;
  }

  Future<List<NewsItem>> _fetchRssFeed(String source, String url) async {
    final response = await _dio.get(
      url,
      options: Options(responseType: ResponseType.plain),
    );

    final document = XmlDocument.parse(response.data);
    final items = document.findAllElements('item');

    return items.take(10).map((item) {
      final title = item.getElement('title')?.innerText ?? '';
      final description = item.getElement('description')?.innerText ?? '';
      final link = item.getElement('link')?.innerText ?? '';
      final pubDate = item.getElement('pubDate')?.innerText ?? '';

      return NewsItem(
        title: title,
        summary: _cleanHtml(description),
        source: source,
        url: link,
        publishedAt: _parseDate(pubDate),
      );
    }).toList();
  }

  String _cleanHtml(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  DateTime _parseDate(String dateStr) {
    try {
      return DateTime.parse(dateStr);
    } catch (_) {
      try {
        // RFC 822 format common in RSS
        return _parseRfc822(dateStr);
      } catch (_) {
        return DateTime.now();
      }
    }
  }

  DateTime _parseRfc822(String dateStr) {
    // Handle "Mon, 03 Apr 2026 10:00:00 GMT" format
    final months = {
      'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
      'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
    };
    final parts = dateStr.replaceAll(',', '').split(RegExp(r'\s+'));
    if (parts.length >= 5) {
      final day = int.parse(parts[1]);
      final month = months[parts[2]] ?? 1;
      final year = int.parse(parts[3]);
      final timeParts = parts[4].split(':');
      return DateTime(
        year,
        month,
        day,
        int.parse(timeParts[0]),
        timeParts.length > 1 ? int.parse(timeParts[1]) : 0,
      );
    }
    throw const FormatException('Cannot parse date');
  }
}
