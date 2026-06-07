class MarketClock {
  final bool isOpen;
  final DateTime nextOpen;
  final DateTime nextClose;
  final DateTime timestamp;

  const MarketClock({
    required this.isOpen,
    required this.nextOpen,
    required this.nextClose,
    required this.timestamp,
  });

  factory MarketClock.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return MarketClock(
      isOpen: json['is_open'] as bool? ?? false,
      nextOpen: DateTime.tryParse(json['next_open'] as String? ?? '') ?? now,
      nextClose: DateTime.tryParse(json['next_close'] as String? ?? '') ?? now,
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? now,
    );
  }
}
