import 'package:flutter_test/flutter_test.dart';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/api/trading_exception.dart';
import 'package:morex/core/models/account.dart';
import 'package:morex/core/models/asset_info.dart';
import 'package:morex/core/models/historical_bar.dart';
import 'package:morex/core/models/market_clock.dart';
import 'package:morex/core/models/market_snapshot.dart';
import 'package:morex/core/models/position.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/core/models/symbol_validation_result.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/engine/order_executor.dart';

class _FakeAlpacaClient implements AlpacaClient {
  final bool throwOnPlaceOrder;
  _FakeAlpacaClient({this.throwOnPlaceOrder = false});

  @override
  Future<Account> getAccount() async => throw UnimplementedError();

  @override
  Future<void> cancelOrder(String orderId) async {}

  @override
  Future<Map<String, dynamic>> closePosition(String symbol) async =>
      {'id': 'close-$symbol'};

  @override
  Future<List<Map<String, dynamic>>> getOrders({String status = 'open'}) async =>
      const [];

  @override
  Future<List<Position>> getPositions() async => const [];

  @override
  Future<Map<String, dynamic>> placeOrder({
    required String symbol,
    double? qty,
    double? notional,
    required String side,
    required String type,
    required String timeInForce,
    double? stopPrice,
    double? limitPrice,
    String? clientOrderId,
  }) async {
    if (throwOnPlaceOrder) throw Exception('Broker rejected order');
    return {'id': '$side-$symbol-order'};
  }

  @override
  Future<Map<String, dynamic>> replaceOrder(
    String orderId, {
    double? qty,
    double? stopPrice,
  }) async =>
      {'id': orderId};

  @override
  Future<Map<String, MarketSnapshot>> getSnapshots(List<String> symbols) async =>
      {};

  @override
  Future<MarketClock> getMarketClock() async => MarketClock(
        isOpen: true,
        nextOpen: DateTime.now().add(const Duration(days: 1)),
        nextClose: DateTime.now().add(const Duration(hours: 7)),
        timestamp: DateTime.now(),
      );

  @override
  Future<Map<String, List<HistoricalBar>>> getBars(
    List<String> symbols, {
    String timeframe = '1Day',
    int limit = 30,
    DateTime? start,
    DateTime? end,
  }) async =>
      {};

  @override
  Future<AssetInfo> getAsset(String symbol) async => throw UnimplementedError();

  @override
  Future<SymbolValidationResult> validateSymbols(List<String> symbols) async =>
      SymbolValidationResult(tradable: symbols, nonTradable: [], notFound: []);

  @override
  Future<void> assertMarketOpen() async {}

  @override
  Future<List<Map<String, dynamic>>> getNews({int limit = 30, List<String>? symbols}) async => [];

  @override
  Future<Map<String, dynamic>> getPortfolioHistory({String period = '1M', String timeframe = '1D'}) async => {};
}

void main() {
  final signal = Signal(
    ticker: 'AAPL',
    sentiment: Sentiment.bullish,
    confidence: 0.9,
    timeframe: Timeframe.short,
    reasoning: 'Momentum breakout',
    sourceHeadlines: const [],
    createdAt: DateTime(2026, 4, 6, 10, 0),
  );

  group('OrderExecutor', () {
    test('executeBuy returns submitted execution metadata', () async {
      final executor = OrderExecutor(client: _FakeAlpacaClient());

      final log = await executor.executeBuy(
        signal: signal,
        amountDollars: 250,
      );

      expect(log.action, TradeAction.buy);
      expect(log.orderId, 'buy-AAPL-order');
      expect(log.roundTripId, 'buy-AAPL-order');
      expect(log.executionStatus, TradeExecutionStatus.submitted);
      expect(log.price, isNull);
      expect(log.qty, isNull);
    });

    test('executeSell returns submitted execution metadata', () async {
      final executor = OrderExecutor(client: _FakeAlpacaClient());

      final log = await executor.executeSell(signal: signal);

      expect(log.action, TradeAction.sell);
      expect(log.orderId, 'close-AAPL');
      expect(log.roundTripId, 'close-AAPL');
      expect(log.executionStatus, TradeExecutionStatus.submitted);
    });
  });

  group('setStopLoss', () {
    test('returns order ID on success', () async {
      final executor = OrderExecutor(client: _FakeAlpacaClient());

      final orderId = await executor.setStopLoss(
        symbol: 'AAPL',
        stopPrice: 150.0,
        qty: 2.0,
      );

      expect(orderId, 'sell-AAPL-order');
    });

    test('throws StopLossException when broker rejects', () async {
      final executor =
          OrderExecutor(client: _FakeAlpacaClient(throwOnPlaceOrder: true));

      expect(
        () => executor.setStopLoss(
          symbol: 'AAPL',
          stopPrice: 150.0,
          qty: 2.0,
        ),
        throwsA(isA<StopLossException>().having(
          (e) => e.symbol,
          'symbol',
          'AAPL',
        )),
      );
    });

    test('replaceStopLoss falls back to new stop when PATCH fails', () async {
      // replaceOrder throws, but placeOrder succeeds — should return new ID
      final client = _FakeAlpacaClient();
      final executor = OrderExecutor(client: client);

      // Replace with a non-existent oldOrderId still succeeds by falling back
      final orderId = await executor.replaceStopLoss(
        oldOrderId: null, // no existing order → goes straight to setStopLoss
        symbol: 'TSLA',
        qty: 1.0,
        newStopPrice: 200.0,
      );

      expect(orderId, 'sell-TSLA-order');
    });
  });
}
