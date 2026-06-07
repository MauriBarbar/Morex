class MarketSnapshot {
  final String symbol;
  final double latestPrice;
  final double previousClose;
  final double dailyChangePercent;
  final int volume;
  final double? bid;
  final double? ask;

  const MarketSnapshot({
    required this.symbol,
    required this.latestPrice,
    required this.previousClose,
    required this.dailyChangePercent,
    required this.volume,
    this.bid,
    this.ask,
  });

  /// Spread as a fraction of mid price. Returns null if quote is unavailable
  /// (outside RTH, or zero/inverted prices).
  double? get spreadPercent {
    final b = bid;
    final a = ask;
    if (b == null || a == null || b <= 0 || a <= 0 || a < b) return null;
    final mid = (a + b) / 2;
    if (mid <= 0) return null;
    return (a - b) / mid;
  }

  factory MarketSnapshot.fromAlpacaJson(
      String symbol, Map<String, dynamic> json) {
    final dailyBar = json['dailyBar'] as Map<String, dynamic>? ?? {};
    final latestTrade = json['latestTrade'] as Map<String, dynamic>? ?? {};
    final latestQuote = json['latestQuote'] as Map<String, dynamic>? ?? {};
    final prevDailyBar =
        json['prevDailyBar'] as Map<String, dynamic>? ?? {};

    final price = (latestTrade['p'] as num?)?.toDouble() ??
        (dailyBar['c'] as num?)?.toDouble() ??
        0;
    final prevClose = (prevDailyBar['c'] as num?)?.toDouble() ?? price;
    final change =
        prevClose != 0 ? ((price - prevClose) / prevClose) * 100 : 0.0;
    final vol = (dailyBar['v'] as num?)?.toInt() ?? 0;
    final bidPrice = (latestQuote['bp'] as num?)?.toDouble();
    final askPrice = (latestQuote['ap'] as num?)?.toDouble();

    return MarketSnapshot(
      symbol: symbol,
      latestPrice: price,
      previousClose: prevClose,
      dailyChangePercent: change,
      volume: vol,
      bid: (bidPrice != null && bidPrice > 0) ? bidPrice : null,
      ask: (askPrice != null && askPrice > 0) ? askPrice : null,
    );
  }

  String get formattedVolume {
    if (volume >= 1000000) return '${(volume / 1000000).toStringAsFixed(1)}M';
    if (volume >= 1000) return '${(volume / 1000).toStringAsFixed(0)}K';
    return volume.toString();
  }
}
