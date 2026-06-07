import 'package:dio/dio.dart';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/api/trading_exception.dart';
import 'package:morex/core/logger.dart';
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

  Future<void> _assertMarketOpen() async {
    await _client.assertMarketOpen();
  }

  TradeExecutionStatus _resolveStatus(Map<String, dynamic> orderResponse) {
    final status = (orderResponse['status'] as String? ?? '').toLowerCase();
    return switch (status) {
      'new' || 'pending_new' || 'accepted' || 'held' => TradeExecutionStatus.submitted,
      'partially_filled' => TradeExecutionStatus.partialFill,
      'filled' => TradeExecutionStatus.filled,
      'rejected' || 'canceled' || 'expired' || 'done_for_day' => TradeExecutionStatus.rejected,
      _ => TradeExecutionStatus.submitted,
    };
  }

  String _getRejectReason(Map<String, dynamic> orderResponse) {
    final status = orderResponse['status'] as String? ?? '';
    final rejectReason = orderResponse['reject_reason'] as String?;
    if (rejectReason != null && rejectReason.isNotEmpty) return rejectReason;
    return 'Order $status';
  }

  /// Alpaca minimum notional for fractional orders.
  static const _minNotional = 1.0;

  Future<TradeLog> executeBuy({
    required Signal signal,
    required double amountDollars,
    double? expectedPrice,
  }) async {
    if (amountDollars <= 0) throw ArgumentError('amountDollars must be positive');
    if (amountDollars < _minNotional) {
      return TradeLog(
        ticker: signal.ticker,
        action: TradeAction.skip,
        reasoning: 'Order \$${amountDollars.toStringAsFixed(2)} below Alpaca minimum (\$$_minNotional)',
        signal: signal,
        createdAt: DateTime.now(),
      );
    }
    try {
      await _assertMarketOpen();
      final clientOrderId = '${signal.ticker}_buy_${DateTime.now().millisecondsSinceEpoch}';
      final result = await _client.placeOrder(
        symbol: signal.ticker,
        notional: amountDollars,
        side: 'buy',
        type: 'market',
        timeInForce: 'day',
        clientOrderId: clientOrderId,
      );

      final orderId = result['id'] as String?;
      if (orderId == null || orderId.isEmpty) {
        throw StateError('Order placed for ${signal.ticker} but response contained no order ID');
      }

      final executionStatus = _resolveStatus(result);
      final action = executionStatus == TradeExecutionStatus.rejected ? TradeAction.skip : TradeAction.buy;
      final reasoning = executionStatus == TradeExecutionStatus.rejected
          ? 'Order rejected: ${_getRejectReason(result)}'
          : 'Bought \$${amountDollars.toStringAsFixed(2)} of ${signal.ticker} — ${signal.reasoning}';

      return TradeLog(
        ticker: signal.ticker,
        action: action,
        qty: null,
        price: null,
        expectedPrice: expectedPrice,
        orderId: orderId,
        roundTripId: orderId,
        executionStatus: executionStatus,
        reasoning: reasoning,
        signal: signal,
        createdAt: DateTime.now(),
      );
    } on MarketClosedException catch (e) {
      return TradeLog(
        ticker: signal.ticker,
        action: TradeAction.skip,
        reasoning: e.message,
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
    double? expectedPrice,
  }) async {
    try {
      await _assertMarketOpen();
      final result = await _client.closePosition(signal.ticker);

      final executionStatus = _resolveStatus(result);
      final action = executionStatus == TradeExecutionStatus.rejected ? TradeAction.skip : TradeAction.sell;
      final reasoning = executionStatus == TradeExecutionStatus.rejected
          ? 'Order rejected: ${_getRejectReason(result)}'
          : 'Sold ${signal.ticker} — bearish signal: ${signal.reasoning}';

      return TradeLog(
        ticker: signal.ticker,
        action: action,
        expectedPrice: expectedPrice,
        orderId: result['id'] as String?,
        roundTripId: result['id'] as String?,
        executionStatus: executionStatus,
        reasoning: reasoning,
        signal: signal,
        createdAt: DateTime.now(),
      );
    } on MarketClosedException catch (e) {
      return TradeLog(
        ticker: signal.ticker,
        action: TradeAction.skip,
        reasoning: e.message,
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

  Future<TradeLog> executePartialSell({
    required String symbol,
    required double qty,
    required String reason,
    required Signal signal,
    TradeAction action = TradeAction.takeProfitSell,
    double? expectedPrice,
  }) async {
    try {
      await _assertMarketOpen();
      final clientOrderId = '${symbol}_sell_${DateTime.now().millisecondsSinceEpoch}';
      final result = await _client.placeOrder(
        symbol: symbol,
        qty: qty,
        side: 'sell',
        type: 'market',
        timeInForce: 'day',
        clientOrderId: clientOrderId,
      );

      final executionStatus = _resolveStatus(result);
      final finalAction = executionStatus == TradeExecutionStatus.rejected ? TradeAction.skip : action;
      final finalReason = executionStatus == TradeExecutionStatus.rejected
          ? 'Order rejected: ${_getRejectReason(result)}'
          : reason;

      return TradeLog(
        ticker: symbol,
        action: finalAction,
        qty: qty,
        expectedPrice: expectedPrice,
        orderId: result['id'] as String?,
        roundTripId: result['id'] as String?,
        executionStatus: executionStatus,
        reasoning: finalReason,
        signal: signal,
        createdAt: DateTime.now(),
      );
    } on MarketClosedException catch (e) {
      return TradeLog(
        ticker: symbol,
        action: TradeAction.skip,
        reasoning: e.message,
        signal: signal,
        createdAt: DateTime.now(),
      );
    } on DioException catch (e) {
      return TradeLog(
        ticker: symbol,
        action: TradeAction.skip,
        reasoning: 'Partial sell failed: ${e.response?.data ?? e.message}',
        signal: signal,
        createdAt: DateTime.now(),
      );
    }
  }

  /// Places a stop-loss order. Throws [StopLossException] on failure — the
  /// position will be live and unprotected, so callers must catch and handle.
  Future<String> setStopLoss({
    required String symbol,
    required double stopPrice,
    required double qty,
  }) async {
    try {
      final result = await _client.placeOrder(
        symbol: symbol,
        qty: qty,
        side: 'sell',
        type: 'stop',
        timeInForce: 'gtc',
        stopPrice: stopPrice,
      );
      final orderId = result['id'] as String?;
      if (orderId == null || orderId.isEmpty) {
        throw StopLossException(symbol, 'API returned no order ID');
      }
      return orderId;
    } catch (e) {
      if (e is StopLossException) rethrow;
      throw StopLossException(symbol, e.toString());
    }
  }

  /// Replaces an existing stop-loss order atomically, or places a new one if
  /// the old order no longer exists. Throws [StopLossException] if both fail.
  Future<String> replaceStopLoss({
    required String? oldOrderId,
    required String symbol,
    required double qty,
    required double newStopPrice,
  }) async {
    if (oldOrderId != null) {
      try {
        final result = await _client.replaceOrder(
          oldOrderId,
          qty: qty,
          stopPrice: newStopPrice,
        );
        final orderId = result['id'] as String?;
        if (orderId != null && orderId.isNotEmpty) return orderId;
      } catch (e) {
        Log.i('OrderExecutor', 'Atomic replace failed for $oldOrderId ($e), placing new stop');
      }
    }
    return setStopLoss(symbol: symbol, stopPrice: newStopPrice, qty: qty);
  }
}
