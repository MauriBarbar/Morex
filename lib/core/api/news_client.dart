import 'package:dio/dio.dart';
import 'package:xml/xml.dart';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/logger.dart';
import 'package:morex/core/models/news_item.dart';

class NewsClient {
  final Dio _dio = Dio();
  final AlpacaClient? _alpacaClient;

  // ── RSS feeds (RSS 2.0 — <item> based) ──────────────────────────────────────
  // All URLs verified working as of 2026-04-27. Each fetched in parallel;
  // failures silently skipped so one dead feed never blocks the scan.
  static const _rssFeeds = <String, _Feed>{
    'CNBC': _Feed(
      url: 'https://www.cnbc.com/id/100003114/device/rss/rss.html',
      reliability: 0.75,
    ),
    'WSJ Markets': _Feed(
      url: 'https://feeds.a.dj.com/rss/RSSMarketsMain.xml',
      reliability: 0.85,
    ),
    'Benzinga': _Feed(
      url: 'https://www.benzinga.com/feed',
      reliability: 0.78,
    ),
    'Forbes Business': _Feed(
      url: 'https://www.forbes.com/business/feed/',
      reliability: 0.68,
    ),
    'Fortune': _Feed(
      url: 'https://fortune.com/feed/',
      reliability: 0.65,
    ),
    'Business Insider Markets': _Feed(
      url: 'https://markets.businessinsider.com/rss/news',
      reliability: 0.65,
    ),
    'Yahoo Finance': _Feed(
      url: 'https://finance.yahoo.com/rss/2.0/headline?s=^GSPC,^DJI,^IXIC&region=US&lang=en-US',
      reliability: 0.65,
    ),
  };

  // ── SEC EDGAR 8-K feed (Atom) ────────────────────────────────────────────────
  // Real-time material event filings: earnings surprises, M&A, FDA decisions,
  // leadership changes, and other SEC-reportable catalysts. Free, no auth.
  static const _edgarUrl =
      'https://www.sec.gov/cgi-bin/browse-edgar'
      '?action=getcurrent&type=8-K&dateb=&owner=include&count=40&search_text=&output=atom';

  NewsClient({AlpacaClient? alpacaClient}) : _alpacaClient = alpacaClient;

  /// Fetches and merges news from all sources:
  ///   1. Alpaca News API  — ticker-tagged, highest quality
  ///   2. SEC EDGAR 8-K    — real material events (earnings, M&A, FDA, etc.)
  ///   3. RSS feeds        — general financial news from major outlets
  ///
  /// All sources run in parallel; individual failures are silently skipped.
  Future<List<NewsItem>> fetchNews() async {
    final allItems = <NewsItem>[];
    final seenTitles = <String>{};
    int alpacaCount = 0;
    int edgarCount = 0;
    int rssCount = 0;
    int failCount = 0;

    // ── 1. Alpaca News API ────────────────────────────────────────────────────
    final alpacaFuture = _fetchAlpacaNews().then((items) {
      for (final item in items) {
        if (seenTitles.add(_normalizeTitle(item.title))) {
          allItems.add(item);
          alpacaCount++;
        }
      }
    }).catchError((e) {
      failCount++;
      Log.w('NewsClient', 'Alpaca news failed: $e');
    });

    // ── 2. SEC EDGAR 8-K (Atom) ───────────────────────────────────────────────
    final edgarFuture = _fetchEdgarFeed().then((items) {
      for (final item in items) {
        if (seenTitles.add(_normalizeTitle(item.title))) {
          allItems.add(item);
          edgarCount++;
        }
      }
    }).catchError((e) {
      failCount++;
      Log.w('NewsClient', 'SEC EDGAR feed failed: $e');
    });

    // ── 3. RSS feeds (parallel) ────────────────────────────────────────────────
    final rssFutures = _rssFeeds.entries.map((entry) async {
      try {
        final items = await _fetchRssFeed(
            entry.key, entry.value.url, entry.value.reliability);
        for (final item in items) {
          if (seenTitles.add(_normalizeTitle(item.title))) {
            allItems.add(item);
            rssCount++;
          }
        }
      } catch (e) {
        failCount++;
        Log.w('NewsClient', 'Feed ${entry.key} failed: $e');
      }
    });

    await Future.wait([alpacaFuture, edgarFuture, ...rssFutures]);

    Log.i('NewsClient',
        'Fetched ${allItems.length} articles — '
        '$alpacaCount Alpaca, $edgarCount EDGAR, $rssCount RSS '
        '($failCount sources failed)');

    if (allItems.isEmpty) {
      throw Exception(
          'No news available — all sources failed. Check connectivity.');
    }

    // Newest first, cap at 100 (Claude sees 75 of these)
    allItems.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
    return allItems.take(100).toList();
  }

  // ── Alpaca ───────────────────────────────────────────────────────────────────

  Future<List<NewsItem>> _fetchAlpacaNews() async {
    if (_alpacaClient == null) return [];
    final raw = await _alpacaClient.getNews(limit: 50);
    return raw.map((article) {
      final symbols = (article['symbols'] as List?)
              ?.map((s) => s.toString())
              .toList() ??
          [];
      return NewsItem(
        title: article['headline'] as String? ?? '',
        summary: article['summary'] as String? ?? '',
        source: article['source'] as String? ?? 'Alpaca',
        url: article['url'] as String? ?? '',
        publishedAt:
            DateTime.tryParse(article['created_at'] as String? ?? '') ??
                DateTime.now(),
        sourceReliability: 0.90,
        relatedTickers: symbols,
      );
    }).where((n) => n.title.isNotEmpty).toList();
  }

  // ── SEC EDGAR 8-K (Atom) ─────────────────────────────────────────────────────

  Future<List<NewsItem>> _fetchEdgarFeed() async {
    final response = await _dio.get(
      _edgarUrl,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 12),
        headers: {'User-Agent': 'Morex-App/1.0 research@morex.app'},
      ),
    );
    final document = XmlDocument.parse(response.data as String);
    // Atom uses <entry> not <item>
    final entries = document.findAllElements('entry');

    return entries.take(30).map((entry) {
      final rawTitle = entry.getElement('title')?.innerText ?? '';
      final company = _extractEdgarCompany(rawTitle);
      // Atom <link> uses href attribute, not text content
      final link = entry.findElements('link').firstOrNull
              ?.getAttribute('href') ??
          '';
      final updated = entry.getElement('updated')?.innerText ?? '';
      final summary = _cleanHtml(
          entry.getElement('summary')?.innerText ?? '8-K filing');

      return NewsItem(
        title: '8-K: $company',
        summary: summary,
        source: 'SEC EDGAR',
        url: link,
        publishedAt: DateTime.tryParse(updated) ?? DateTime.now(),
        sourceReliability: 0.95,
        relatedTickers: const [],
      );
    }).toList();
  }

  /// Extracts company name from EDGAR title format:
  /// "8-K - APPLE INC (0000320193) (Filer)" → "APPLE INC"
  String _extractEdgarCompany(String title) {
    var name = title;
    if (name.startsWith('8-K - ')) name = name.substring(6);
    name = name.replaceAll(RegExp(r'\s*\(\d+\)\s*\(Filer\)\s*$'), '').trim();
    return name;
  }

  // ── RSS (RSS 2.0) ────────────────────────────────────────────────────────────

  Future<List<NewsItem>> _fetchRssFeed(
      String source, String url, double reliability) async {
    final response = await _dio.get(
      url,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    final document = XmlDocument.parse(response.data as String);
    final items = document.findAllElements('item');

    return items.take(15).map((item) {
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
        sourceReliability: reliability,
      );
    }).where((n) => n.title.isNotEmpty).toList();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  String _normalizeTitle(String title) {
    return title
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cleanHtml(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  DateTime _parseDate(String dateStr) {
    try {
      return DateTime.parse(dateStr);
    } catch (_) {
      try {
        return _parseRfc822(dateStr);
      } catch (_) {
        return DateTime.now();
      }
    }
  }

  DateTime _parseRfc822(String dateStr) {
    const months = {
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

class _Feed {
  final String url;
  final double reliability;
  const _Feed({required this.url, required this.reliability});
}
