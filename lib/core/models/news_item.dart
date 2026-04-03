class NewsItem {
  final String title;
  final String summary;
  final String source;
  final String url;
  final DateTime publishedAt;

  const NewsItem({
    required this.title,
    required this.summary,
    required this.source,
    required this.url,
    required this.publishedAt,
  });
}
