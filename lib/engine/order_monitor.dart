import 'dart:async';

import 'package:morex/core/api/alpaca_websocket.dart';
import 'package:morex/core/logger.dart';

enum OrderEvent { newOrder, fill, partialFill, canceled, rejected, expired }

class OrderUpdate {
  final String orderId;
  final String symbol;
  final String side;
  final OrderEvent event;
  final double? filledQty;
  final double? filledAvgPrice;
  final DateTime timestamp;

  const OrderUpdate({
    required this.orderId,
    required this.symbol,
    required this.side,
    required this.event,
    this.filledQty,
    this.filledAvgPrice,
    required this.timestamp,
  });

  bool get isFilled => event == OrderEvent.fill;
  bool get isFailed =>
      event == OrderEvent.canceled ||
      event == OrderEvent.rejected ||
      event == OrderEvent.expired;
}

class OrderMonitor {
  final AlpacaWebSocket _ws;
  StreamSubscription? _subscription;

  final _updateController = StreamController<OrderUpdate>.broadcast();
  final Map<String, OrderUpdate> _orderStates = {};

  OrderMonitor({required AlpacaWebSocket tradingWebSocket})
      : _ws = tradingWebSocket;

  Stream<OrderUpdate> get stream => _updateController.stream;
  Map<String, OrderUpdate> get orderStates =>
      Map.unmodifiable(_orderStates);
  bool get isStarted => _subscription != null;

  void start() {
    if (_subscription != null) return;
    _ws.connect();
    _subscription = _ws.messageStream.listen(_onMessage);
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  void _onMessage(Map<String, dynamic> msg) {
    // Log all incoming messages to diagnose fill event issues
    Log.d('OrderMonitor', 'Incoming raw msg: stream=${msg['stream']}, T=${msg['T']}, event=${msg['event']}');

    // Envelope format: { stream: "trade_updates", data: { event, order, ... } }
    final streamVal = msg['stream'];
    if (streamVal == 'trade_updates') {
      final data = msg['data'];
      if (data is Map<String, dynamic>) {
        _handleTradeUpdate(data);
      }
      return;
    }

    // Flat format: { T: "trade_updates", event: ..., order: ... }
    // or bare flat format with event + order at top level.
    final tVal = msg['T'];
    if (tVal == 'trade_updates' ||
        (msg.containsKey('event') && msg.containsKey('order'))) {
      _handleTradeUpdate(msg);
    }
  }

  void _handleTradeUpdate(Map<String, dynamic> data) {
    try {
      final eventStr = data['event'] as String? ?? '';
      final orderRaw = data['order'];
      final order = (orderRaw is Map)
          ? orderRaw.cast<String, dynamic>()
          : <String, dynamic>{};

      final event = _parseEvent(eventStr);
      if (event == null) {
        Log.w('OrderMonitor', 'Unknown event type: $eventStr');
        return;
      }

      // filled_qty / filled_avg_price may arrive as String or num
      final rawQty = order['filled_qty'];
      final rawPrice = order['filled_avg_price'];
      final filledQty = rawQty == null
          ? null
          : (rawQty is num ? rawQty.toDouble() : double.tryParse('$rawQty'));
      final filledAvgPrice = rawPrice == null
          ? null
          : (rawPrice is num ? rawPrice.toDouble() : double.tryParse('$rawPrice'));

      // timestamp may live in data or inside order; must be a String to parse
      final tsRaw = data['timestamp'] ?? order['updated_at'] ?? order['submitted_at'];
      DateTime? parsedTs = tsRaw is String ? DateTime.tryParse(tsRaw) : null;
      if (parsedTs == null) {
        final submittedRaw = order['submitted_at'];
        parsedTs = submittedRaw is String ? DateTime.tryParse(submittedRaw) : null;
        if (parsedTs == null) {
          Log.w('OrderMonitor', 'No parseable timestamp for order ${order['id']}; falling back to now()');
        }
      }
      final timestamp = parsedTs ?? DateTime.now();

      final orderId = order['id'] as String? ?? '';
      final symbol = order['symbol'] as String? ?? '';
      final side = order['side'] as String? ?? '';

      if (orderId.isEmpty) {
        Log.e('OrderMonitor', 'Dropping trade update with missing order id: $data');
        return;
      }

      final update = OrderUpdate(
        orderId: orderId,
        symbol: symbol,
        side: side,
        event: event,
        filledQty: filledQty,
        filledAvgPrice: filledAvgPrice,
        timestamp: timestamp,
      );

      Log.d('OrderMonitor', 'Order update: $symbol $side $event (ID: $orderId, Qty: $filledQty, Price: $filledAvgPrice)');

      _orderStates[update.orderId] = update;
      _updateController.add(update);
    } catch (e) {
      Log.e('OrderMonitor', 'Failed to parse trade update: $e, data: $data');
    }
  }

  OrderEvent? _parseEvent(String event) {
    return switch (event) {
      'new' => OrderEvent.newOrder,
      'pending_new' => OrderEvent.newOrder,
      'fill' => OrderEvent.fill,
      'partial_fill' => OrderEvent.partialFill,
      'canceled' => OrderEvent.canceled,
      'rejected' => OrderEvent.rejected,
      'expired' => OrderEvent.expired,
      _ => null,
    };
  }

  void dispose() {
    stop();
    _updateController.close();
  }
}
