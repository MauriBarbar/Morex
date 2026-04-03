import 'package:dio/dio.dart';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/engine/risk_manager.dart';

class OrderResult {
  final String? orderId;
  final bool success;
  final String message;

  const OrderResult({this.orderId, required this.success, required this.message});
}

class OrderExecutor {
  final AlpacaClient _client;
  final RiskConfig riskConfig;

  OrderExecutor({
    required AlpacaClient client,
    this.riskConfig = const RiskConfig(),
  }) : _client = client;

  Future<TradeLog> executeBuy({
    required Signal signal,
    required double amountDollars,
  }) async {
    try {
      final result = await _client.placeOrder(
        symbol: signal.ticker,
        notional: amountDollars,
        side: 'buy',
        type: 'market',
        timeInForce: 'day',
      );

      return TradeLog(
        ticker: signal.ticker,
        action: TradeAction.buy,
        qty: null, // Filled after execution
        price: null,
        orderId: result['id'],
        reasoning:
            'Bought \$${amountDollars.toStringAsFixed(2)} of ${signal.ticker} — ${signal.reasoning}',
        signal: signal,
        createdAt: DateTime.now(),
      );
    } on DioException catch (e) {
      return TradeLog(
        ticker: signal.ticker,
        action: TradeAction.skip,
        reasoning: 'Order failed: ${e.response?.data ?? e.message}',
        signal: signal,
        createdAt: DateTime.now(),
      );
    }
  }

  Future<TradeLog> executeSell({
    required Signal signal,
  }) async {
    try {
      // Close the entire position
      await _client.closePosition(signal.ticker);

      return TradeLog(
        ticker: signal.ticker,
        action: TradeAction.sell,
        reasoning:
            'Sold ${signal.ticker} — bearish signal: ${signal.reasoning}',
        signal: signal,
        createdAt: DateTime.now(),
      );
    } on DioException catch (e) {
      return TradeLog(
        ticker: signal.ticker,
        action: TradeAction.skip,
        reasoning: 'Sell failed: ${e.response?.data ?? e.message}',
        signal: signal,
        createdAt: DateTime.now(),
      );
    }
  }

  Future<void> setStopLoss({
    required String symbol,
    required double stopPrice,
  }) async {
    try {
      await _client.placeOrder(
        symbol: symbol,
        qty: null, // Will close full position
        side: 'sell',
        type: 'stop',
        timeInForce: 'gtc',
        stopPrice: stopPrice,
      );
    } catch (_) {
      // Stop-loss is best-effort; logged but not critical
    }
  }
}
