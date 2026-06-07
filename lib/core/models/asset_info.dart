class AssetInfo {
  final String id;
  final String symbol;
  final String name;
  final String exchange;
  final String assetClass;
  final String status;
  final bool tradable;
  final bool fractionable;

  const AssetInfo({
    required this.id,
    required this.symbol,
    required this.name,
    required this.exchange,
    required this.assetClass,
    required this.status,
    required this.tradable,
    required this.fractionable,
  });

  /// True if the asset is active and tradable.
  bool get isActive => status == 'active' && tradable;

  factory AssetInfo.fromJson(Map<String, dynamic> json) {
    return AssetInfo(
      id: json['id'] as String? ?? '',
      symbol: json['symbol'] as String? ?? '',
      name: json['name'] as String? ?? '',
      exchange: json['exchange'] as String? ?? '',
      assetClass: json['class'] as String? ?? '',
      status: json['status'] as String? ?? '',
      tradable: json['tradable'] as bool? ?? false,
      fractionable: json['fractionable'] as bool? ?? false,
    );
  }
}
