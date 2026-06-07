class HistoricalBar {
  final DateTime timestamp;
  final double open;
  final double high;
  final double low;
  final double close;
  final int volume;
  final double? vwap;
  final int? tradeCount;

  const HistoricalBar({
    required this.timestamp,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    this.vwap,
    this.tradeCount,
  });

  factory HistoricalBar.fromJson(Map<String, dynamic> json) {
    return HistoricalBar(
      timestamp: DateTime.tryParse(json['t'] as String? ?? '') ?? DateTime.now(),
      open: (json['o'] as num?)?.toDouble() ?? 0,
      high: (json['h'] as num?)?.toDouble() ?? 0,
      low: (json['l'] as num?)?.toDouble() ?? 0,
      close: (json['c'] as num?)?.toDouble() ?? 0,
      volume: (json['v'] as num?)?.toInt() ?? 0,
      vwap: (json['vw'] as num?)?.toDouble(),
      tradeCount: (json['n'] as num?)?.toInt(),
    );
  }
}
