enum NewsCategory { markets, earnings, macro, analysis, tech, ticker }

class NewsItem {
  final String title;
  final String summary;
  final String source;
  final String url;
  final DateTime publishedAt;
  final NewsCategory category;
  final double sourceReliability;
  final List<String> relatedTickers;

  const NewsItem({
    required this.title,
    required this.summary,
    required this.source,
    required this.url,
    required this.publishedAt,
    this.category = NewsCategory.markets,
    this.sourceReliability = 0.5,
    this.relatedTickers = const [],
  });

  int get ageMinutes => DateTime.now().difference(publishedAt).inMinutes;

  /// Score combining freshness and source reliability. Used to rank news items.
  double get relevanceScore {
    final agePenalty = ageMinutes / 60.0; // 1.0 per hour
    return (sourceReliability * 2.0) - agePenalty.clamp(0.0, 2.0);
  }
}
