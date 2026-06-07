import 'dart:async';

import 'package:morex/core/api/alpaca_websocket.dart';
import 'package:morex/core/logger.dart';

class PriceUpdate {
  final String symbol;
  final double price;
  final double? bidPrice;
  final double? askPrice;
  final int? size;
  final DateTime timestamp;

  const PriceUpdate({
    required this.symbol,
    required this.price,
    this.bidPrice,
    this.askPrice,
    this.size,
    required this.timestamp,
  });
}

class PriceStream {
  final AlpacaWebSocket _ws;
  StreamSubscription? _subscription;

  final _priceController = StreamController<PriceUpdate>.broadcast();
  final Map<String, PriceUpdate> _latestPrices = {};
  final Set<String> _watchedSymbols = {};

  // Alpaca IEX free tier: 30 symbol hard limit per WebSocket connection.
  // We subscribe quotes-only (no trades) and cap at 25 to stay safely under.
  static const maxSubscribableSymbols = 25;

  PriceStream({required AlpacaWebSocket dataWebSocket}) : _ws = dataWebSocket;

  Stream<PriceUpdate> get stream => _priceController.stream;
  Map<String, PriceUpdate> get latestPrices =>
      Map.unmodifiable(_latestPrices);
  bool get isStarted => _subscription != null;

  void start() {
    if (_subscription != null) return;
    _ws.connect();
    _subscription = _ws.messageStream.listen(_onMessage);
  }

  void stop() {
    if (_watchedSymbols.isNotEmpty) {
      _ws.unsubscribeQuotes(_watchedSymbols.toList());
      _watchedSymbols.clear();
    }
    _subscription?.cancel();
    _subscription = null;
  }

  void watchSymbols(List<String> symbols) {
    // Enforce global cap across all calls — _watchedSymbols tracks the running
    // total, so the IEX "symbol limit exceeded" error can never be triggered
    // even when watchSymbols() is called multiple times with separate batches.
    final availableSlots = maxSubscribableSymbols - _watchedSymbols.length;
    if (availableSlots <= 0) {
      Log.w('PriceStream',
          'Symbol cap reached ($maxSubscribableSymbols). Cannot subscribe more symbols.');
      return;
    }
    final newSymbols = symbols
        .where((s) => !_watchedSymbols.contains(s))
        .take(availableSlots)
        .toList();
    if (newSymbols.isEmpty) return;
    final totalNew = symbols.where((s) => !_watchedSymbols.contains(s)).length;
    if (newSymbols.length < totalNew) {
      Log.w('PriceStream',
          'Watchlist trimmed: capacity for ${newSymbols.length}/$totalNew new symbols '
          '(global cap: $maxSubscribableSymbols). Rotate watchlist to cover more symbols.');
    }
    _ws.subscribeQuotes(newSymbols);
    _watchedSymbols.addAll(newSymbols);
  }

  void unwatchSymbols(List<String> symbols) {
    _ws.unsubscribeQuotes(symbols);
    for (final s in symbols) {
      _latestPrices.remove(s);
      _watchedSymbols.remove(s);
    }
  }

  void _onMessage(Map<String, dynamic> msg) {
    final type = msg['T'];
    if (type == 't') {
      _handleTrade(msg);
    } else if (type == 'q') {
      _handleQuote(msg);
    }
  }

  void _handleTrade(Map<String, dynamic> msg) {
    try {
      final symbol = msg['S'] as String?;
      final price = msg['p'];
      if (symbol == null || price == null) {
        Log.w('PriceStream', 'Malformed trade message: missing S or p: $msg');
        return;
      }
      final priceDouble = (price as num).toDouble();
      final size = (msg['s'] as num?)?.toInt();
      final ts = DateTime.tryParse(msg['t'] ?? '') ?? DateTime.now();

      final update = PriceUpdate(
        symbol: symbol,
        price: priceDouble,
        bidPrice: _latestPrices[symbol]?.bidPrice,
        askPrice: _latestPrices[symbol]?.askPrice,
        size: size,
        timestamp: ts,
      );
      _latestPrices[symbol] = update;
      _priceController.add(update);
    } catch (e) {
      Log.e('PriceStream', 'Failed to parse trade: $e, msg: $msg');
    }
  }

  void _handleQuote(Map<String, dynamic> msg) {
    try {
      final symbol = msg['S'] as String?;
      final bid = msg['bp'];
      final ask = msg['ap'];
      if (symbol == null || bid == null || ask == null) {
        Log.w('PriceStream', 'Malformed quote message: missing S, bp, or ap: $msg');
        return;
      }
      final bidDouble = (bid as num).toDouble();
      final askDouble = (ask as num).toDouble();
      final ts = DateTime.tryParse(msg['t'] ?? '') ?? DateTime.now();
      final midPrice = (bidDouble + askDouble) / 2;

      final update = PriceUpdate(
        symbol: symbol,
        price: _latestPrices[symbol]?.price ?? midPrice,
        bidPrice: bidDouble,
        askPrice: askDouble,
        timestamp: ts,
      );
      _latestPrices[symbol] = update;
      _priceController.add(update);
    } catch (e) {
      Log.e('PriceStream', 'Failed to parse quote: $e, msg: $msg');
    }
  }

  void dispose() {
    stop();
    _priceController.close();
  }
}
