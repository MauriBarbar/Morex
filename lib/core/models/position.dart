class Position {
  final String assetId;
  final String symbol;
  final double qty;
  final double avgEntryPrice;
  final double currentPrice;
  final double marketValue;
  final double unrealizedPnL;
  final double unrealizedPnLPercent;
  final String side;

  const Position({
    required this.assetId,
    required this.symbol,
    required this.qty,
    required this.avgEntryPrice,
    required this.currentPrice,
    required this.marketValue,
    required this.unrealizedPnL,
    required this.unrealizedPnLPercent,
    required this.side,
  });

  bool get isProfit => unrealizedPnL >= 0;

  factory Position.fromJson(Map<String, dynamic> json) {
    return Position(
      assetId: json['asset_id'] ?? '',
      symbol: json['symbol'] ?? '',
      qty: double.tryParse(json['qty'] ?? '0') ?? 0,
      avgEntryPrice: double.tryParse(json['avg_entry_price'] ?? '0') ?? 0,
      currentPrice: double.tryParse(json['current_price'] ?? '0') ?? 0,
      marketValue: double.tryParse(json['market_value'] ?? '0') ?? 0,
      unrealizedPnL: double.tryParse(json['unrealized_pl'] ?? '0') ?? 0,
      unrealizedPnLPercent:
          double.tryParse(json['unrealized_plpc'] ?? '0') ?? 0,
      side: json['side'] ?? 'long',
    );
  }
}
