import 'package:morex/core/models/signal.dart';

enum TradeAction { buy, sell, skip }

class TradeLog {
  final String ticker;
  final TradeAction action;
  final double? qty;
  final double? price;
  final String? orderId;
  final String reasoning;
  final Signal signal;
  final DateTime createdAt;

  const TradeLog({
    required this.ticker,
    required this.action,
    this.qty,
    this.price,
    this.orderId,
    required this.reasoning,
    required this.signal,
    required this.createdAt,
  });

  bool get wasExecuted => action != TradeAction.skip;
}
