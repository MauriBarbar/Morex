class Account {
  final String id;
  final String accountNumber;
  final String status;
  final String currency;
  final double equity;
  final double cash;
  final double buyingPower;
  final double portfolioValue;
  final double lastEquity;

  const Account({
    required this.id,
    required this.accountNumber,
    required this.status,
    required this.currency,
    required this.equity,
    required this.cash,
    required this.buyingPower,
    required this.portfolioValue,
    required this.lastEquity,
  });

  double get dailyPnL => equity - lastEquity;
  double get dailyPnLPercent =>
      lastEquity != 0 ? (dailyPnL / lastEquity) * 100 : 0;

  factory Account.fromJson(Map<String, dynamic> json) {
    return Account(
      id: json['id'] ?? '',
      accountNumber: json['account_number'] ?? '',
      status: json['status'] ?? '',
      currency: json['currency'] ?? 'USD',
      equity: double.tryParse(json['equity'] ?? '0') ?? 0,
      cash: double.tryParse(json['cash'] ?? '0') ?? 0,
      buyingPower: double.tryParse(json['buying_power'] ?? '0') ?? 0,
      portfolioValue:
          double.tryParse(json['portfolio_value'] ?? '0') ?? 0,
      lastEquity: double.tryParse(json['last_equity'] ?? '0') ?? 0,
    );
  }
}
