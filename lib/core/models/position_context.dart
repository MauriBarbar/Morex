class PositionContext {
  final String symbol;
  final double entryPrice;
  final double currentPrice;
  final double pnlPercent;
  final int holdDays;
  final int maxHoldDays;

  const PositionContext({
    required this.symbol,
    required this.entryPrice,
    required this.currentPrice,
    required this.pnlPercent,
    required this.holdDays,
    required this.maxHoldDays,
  });
}
