import 'package:morex/core/models/signal.dart';

enum TradeAction { buy, sell, skip, takeProfitSell, trailingStopSell, timeExit, reEvalSell }

enum TradeExecutionStatus { submitted, partialFill, filled, rejected, canceled, expired }

class TradeLog {
  final String ticker;
  final TradeAction action;
  final double? qty;
  final double? price;
  final double? expectedPrice;
  final String? orderId;
  final String? roundTripId;
  final TradeExecutionStatus? executionStatus;
  final DateTime? executedAt;
  final String reasoning;
  final Signal signal;
  final DateTime createdAt;

  const TradeLog({
    required this.ticker,
    required this.action,
    this.qty,
    this.price,
    this.expectedPrice,
    this.orderId,
    this.roundTripId,
    this.executionStatus,
    this.executedAt,
    required this.reasoning,
    required this.signal,
    required this.createdAt,
  });

  bool get wasExecuted => action != TradeAction.skip;

  TradeLog copyWith({
    String? ticker,
    TradeAction? action,
    double? qty,
    double? price,
    double? expectedPrice,
    String? orderId,
    String? roundTripId,
    TradeExecutionStatus? executionStatus,
    DateTime? executedAt,
    String? reasoning,
    Signal? signal,
    DateTime? createdAt,
  }) {
    return TradeLog(
      ticker: ticker ?? this.ticker,
      action: action ?? this.action,
      qty: qty ?? this.qty,
      price: price ?? this.price,
      expectedPrice: expectedPrice ?? this.expectedPrice,
      orderId: orderId ?? this.orderId,
      roundTripId: roundTripId ?? this.roundTripId,
      executionStatus: executionStatus ?? this.executionStatus,
      executedAt: executedAt ?? this.executedAt,
      reasoning: reasoning ?? this.reasoning,
      signal: signal ?? this.signal,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
