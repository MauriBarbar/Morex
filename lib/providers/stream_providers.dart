import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/config/env.dart';
import 'package:morex/core/api/alpaca_websocket.dart';
import 'package:morex/engine/order_monitor.dart';
import 'package:morex/engine/price_stream.dart';

// --- WebSocket instances ---

final dataWebSocketProvider = Provider<AlpacaWebSocket>((ref) {
  final ws = AlpacaWebSocket(url: Env.alpacaDataStreamUrl);
  ref.onDispose(() => ws.dispose());
  return ws;
});

final tradingWebSocketProvider = Provider<AlpacaWebSocket>((ref) {
  final ws = AlpacaWebSocket(url: Env.alpacaTradingStreamUrl);
  ref.onDispose(() => ws.dispose());
  return ws;
});

// --- Price Stream ---

final priceStreamProvider = Provider<PriceStream>((ref) {
  final ws = ref.watch(dataWebSocketProvider);
  final ps = PriceStream(dataWebSocket: ws);
  ps.start();
  ref.onDispose(() => ps.dispose());
  return ps;
});

final priceUpdatesProvider = StreamProvider<PriceUpdate>((ref) {
  final ps = ref.watch(priceStreamProvider);
  return ps.stream;
});

final latestPricesProvider =
    StateProvider<Map<String, PriceUpdate>>((ref) => {});

// --- Connection State ---

final dataConnectionProvider = StreamProvider<WsConnectionState>((ref) {
  final ws = ref.watch(dataWebSocketProvider);
  return ws.stateStream;
});

final tradingConnectionProvider = StreamProvider<WsConnectionState>((ref) {
  final ws = ref.watch(tradingWebSocketProvider);
  return ws.stateStream;
});

// --- Order Monitor ---

final orderMonitorProvider = Provider<OrderMonitor>((ref) {
  final ws = ref.watch(tradingWebSocketProvider);
  final monitor = OrderMonitor(tradingWebSocket: ws);
  monitor.start();
  ref.onDispose(() => monitor.dispose());
  return monitor;
});

final orderUpdatesProvider = StreamProvider<OrderUpdate>((ref) {
  final monitor = ref.watch(orderMonitorProvider);
  return monitor.stream;
});
