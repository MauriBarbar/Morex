import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/models/account.dart';
import 'package:morex/core/models/asset_info.dart';
import 'package:morex/core/models/historical_bar.dart';
import 'package:morex/core/models/managed_position.dart';
import 'package:morex/core/models/market_clock.dart';
import 'package:morex/core/models/market_snapshot.dart';
import 'package:morex/core/models/position.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/core/models/symbol_validation_result.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/db/hive_store.dart';
import 'package:morex/engine/account_lock.dart';
import 'package:morex/engine/order_monitor.dart';
import 'package:morex/engine/price_stream.dart';
import 'package:morex/engine/quick_trade_engine.dart';
import 'package:morex/engine/risk_manager.dart';
import 'package:morex/engine/trading_lock.dart';

class _FakeAlpacaClient implements AlpacaClient {
  final Account account;
  final List<Map<String, dynamic>> openOrders;
  final List<PositionSnapshot> positions;
  final Set<String> failStopOrders;
  final List<Map<String, dynamic>> placedOrders = [];
  final List<String> canceledOrders = [];
  final List<String> closedPositions = [];
  final List<Map<String, dynamic>> replacedOrders = [];

  _FakeAlpacaClient({
    required this.account,
    List<Map<String, dynamic>> openOrders = const [],
    this.positions = const [],
    Set<String> failStopOrders = const {},
  }) : openOrders = List<Map<String, dynamic>>.from(openOrders),
       failStopOrders = Set<String>.from(failStopOrders);

  @override
  Future<Account> getAccount() async => account;

  @override
  Future<void> cancelOrder(String orderId) async {
    canceledOrders.add(orderId);
  }

  @override
  Future<Map<String, dynamic>> closePosition(String symbol) async {
    closedPositions.add(symbol);
    return {'id': 'close-$symbol'};
  }

  @override
  Future<List<Map<String, dynamic>>> getOrders({
    String status = 'open',
  }) async => openOrders;

  @override
  Future<List<Position>> getPositions() async => positions
      .map(
        (p) => _FakePosition(
          symbol: p.symbol,
          qty: p.qty,
          avgEntryPrice: p.avgEntryPrice,
          currentPrice: p.currentPrice,
          side: p.side,
        ),
      )
      .toList();

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
    if (type == 'stop' && failStopOrders.contains(symbol)) {
      throw Exception('stop placement failed for $symbol');
    }

    final id = stopPrice != null
        ? 'stop-$symbol-${placedOrders.length + 1}'
        : '$side-$symbol-order-${placedOrders.length + 1}';
    final order = <String, dynamic>{
      'id': id,
      'symbol': symbol,
      'side': side,
      'type': type,
      'time_in_force': timeInForce,
      'qty': qty,
      'notional': notional,
      'stop_price': stopPrice,
      'client_order_id': clientOrderId,
    };
    placedOrders.add(order);
    if (type == 'stop') {
      openOrders.add(order);
    }
    return {'id': id};
  }

  @override
  Future<Map<String, dynamic>> replaceOrder(
    String orderId, {
    double? qty,
    double? stopPrice,
  }) async {
    replacedOrders.add({
      'orderId': orderId,
      'qty': qty,
      'stopPrice': stopPrice,
    });
    return {'id': 'replaced-$orderId'};
  }

  @override
  Future<Map<String, MarketSnapshot>> getSnapshots(
    List<String> symbols,
  ) async => {};

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

class PositionSnapshot {
  final String symbol;
  final double qty;
  final double avgEntryPrice;
  final double currentPrice;
  final String side;

  const PositionSnapshot({
    required this.symbol,
    required this.qty,
    required this.avgEntryPrice,
    required this.currentPrice,
    this.side = 'long',
  });
}

class _FakePosition implements Position {
  @override
  final String symbol;
  @override
  final double qty;
  @override
  final double avgEntryPrice;
  @override
  final double currentPrice;
  @override
  final String side;

  const _FakePosition({
    required this.symbol,
    required this.qty,
    required this.avgEntryPrice,
    required this.currentPrice,
    required this.side,
  });

  @override
  String get assetId => 'asset-$symbol';

  @override
  bool get isProfit => unrealizedPnL >= 0;

  @override
  double get marketValue => qty * currentPrice;

  @override
  double get unrealizedPnL => (currentPrice - avgEntryPrice) * qty;

  @override
  double get unrealizedPnLPercent =>
      avgEntryPrice == 0 ? 0 : (currentPrice - avgEntryPrice) / avgEntryPrice;
}

class _FakePriceStream implements PriceStream {
  @override
  Stream<PriceUpdate> get stream => const Stream.empty();

  @override
  Map<String, PriceUpdate> get latestPrices => {};

  @override
  bool get isStarted => true;

  @override
  void start() {}

  @override
  void stop() {}

  @override
  void watchSymbols(List<String> symbols) {}

  @override
  void unwatchSymbols(List<String> symbols) {}

  @override
  void dispose() {}
}

class _FakeOrderMonitor implements OrderMonitor {
  final _controller = StreamController<OrderUpdate>.broadcast();

  void emit(OrderUpdate update) {
    _controller.add(update);
  }

  @override
  Stream<OrderUpdate> get stream => _controller.stream;

  @override
  Map<String, OrderUpdate> get orderStates => const {};

  @override
  bool get isStarted => true;

  @override
  void start() {}

  @override
  void stop() {}

  @override
  void dispose() {
    _controller.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final secureStorageState = <String, String?>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async {
        final args = Map<String, dynamic>.from(
          call.arguments as Map? ?? const {},
        );
        final key = args['key'] as String?;
        switch (call.method) {
          case 'read':
            return secureStorageState[key];
          case 'write':
            if (key != null) {
              secureStorageState[key] = args['value'] as String?;
            }
            return null;
          case 'delete':
            if (key != null) {
              secureStorageState.remove(key);
            }
            return null;
          default:
            return null;
        }
      });

  group('QuickTradeConfig', () {
    test('default values are sensible for day trading', () {
      const config = QuickTradeConfig();
      expect(config.budgetPercent, 0.10);
      expect(config.baseDipThreshold, 0.015);
      expect(config.baseTakeProfitPercent, 0.015);
      expect(config.baseStopLossPercent, 0.01);
      expect(config.baseMaxHoldSeconds, 300);
      expect(config.maxOpenPositions, 3);
      expect(config.maxOrderDollars, 500);
      expect(config.maxConsecutiveLosses, 3);
      expect(config.maxSessionLossPercent, 0.03);
    });

    test('custom config overrides', () {
      const config = QuickTradeConfig(
        budgetPercent: 0.05,
        baseDipThreshold: 0.03,
        maxOpenPositions: 5,
        maxConsecutiveLosses: 2,
      );
      expect(config.budgetPercent, 0.05);
      expect(config.baseDipThreshold, 0.03);
      expect(config.maxOpenPositions, 5);
      expect(config.maxConsecutiveLosses, 2);
      // Unchanged
      expect(config.maxOrderDollars, 500);
    });
  });

  group('QuickTradePosition', () {
    test('pnlPercent calculates correctly for profit', () {
      final pos = QuickTradePosition(
        symbol: 'AAPL',
        entryPrice: 100.0,
        qty: 5.0,
        orderId: 'test-order',
        roundTripId: 'round-1',
        entryTime: DateTime.now(),
        entryType: EntryType.dip,
        stopPrice: 99.0,
        targetPrice: 101.5,
        trailingHigh: 100.0,
      );
      // Price went up 2%
      expect(pos.pnlPercent(102.0), closeTo(0.02, 0.001));
    });

    test('pnlPercent calculates correctly for loss', () {
      final pos = QuickTradePosition(
        symbol: 'TSLA',
        entryPrice: 200.0,
        qty: 2.0,
        orderId: 'test-order',
        roundTripId: 'round-2',
        entryTime: DateTime.now(),
        entryType: EntryType.dip,
        stopPrice: 198.0,
        targetPrice: 203.0,
        trailingHigh: 200.0,
      );
      // Price went down 1%
      expect(pos.pnlPercent(198.0), closeTo(-0.01, 0.001));
    });

    test('holdSeconds increases over time', () {
      final pos = QuickTradePosition(
        symbol: 'NVDA',
        entryPrice: 800.0,
        qty: 1.0,
        orderId: 'test-order',
        roundTripId: 'round-3',
        entryTime: DateTime.now().subtract(const Duration(seconds: 60)),
        entryType: EntryType.dip,
        stopPrice: 792.0,
        targetPrice: 812.0,
        trailingHigh: 800.0,
      );
      expect(pos.holdSeconds, greaterThanOrEqualTo(59));
    });
  });

  group('QuickTradeStatus', () {
    test('default status is stopped with zero values', () {
      const status = QuickTradeStatus();
      expect(status.state, QuickTradeEngineState.stopped);
      expect(status.budgetUsed, 0);
      expect(status.budgetLimit, 0);
      expect(status.openPositions, 0);
      expect(status.totalTrades, 0);
      expect(status.sessionPnL, 0);
      expect(status.lastError, isNull);
    });

    test('copyWith preserves unchanged fields', () {
      const original = QuickTradeStatus(
        state: QuickTradeEngineState.running,
        budgetLimit: 1000,
        sessionPnL: 50.0,
      );
      final updated = original.copyWith(sessionPnL: 75.0);
      expect(updated.state, QuickTradeEngineState.running);
      expect(updated.budgetLimit, 1000);
      expect(updated.sessionPnL, 75.0);
    });

    test('copyWith can set error', () {
      const status = QuickTradeStatus();
      final withError = status.copyWith(lastError: 'Connection lost');
      expect(withError.lastError, 'Connection lost');
    });
  });

  group('QuickTradeAnalytics', () {
    Signal signalFor(String reasoning) => Signal(
      ticker: 'AAPL',
      sentiment: Sentiment.bullish,
      confidence: 1.0,
      timeframe: Timeframe.short,
      reasoning: reasoning,
      sourceHeadlines: const [],
      createdAt: DateTime(2026, 4, 6, 10, 0),
    );

    test('computes expectancy and breakdown by entry type', () {
      final logs = [
        TradeLog(
          ticker: 'AAPL',
          action: TradeAction.buy,
          qty: 10,
          price: 100,
          reasoning: 'Dip buy: -2.1% from high',
          signal: signalFor('Dip + RSI + VWAP confirmed'),
          createdAt: DateTime(2026, 4, 6, 10, 0),
        ),
        TradeLog(
          ticker: 'AAPL',
          action: TradeAction.takeProfitSell,
          qty: 10,
          price: 102,
          reasoning: 'Take profit',
          signal: signalFor('Take profit'),
          createdAt: DateTime(2026, 4, 6, 10, 5),
        ),
        TradeLog(
          ticker: 'NVDA',
          action: TradeAction.buy,
          qty: 2,
          price: 200,
          reasoning: 'Breakout buy: +2.3% from low',
          signal: signalFor('Breakout + volume spike + VWAP confirmed'),
          createdAt: DateTime(2026, 4, 6, 10, 10),
        ),
        TradeLog(
          ticker: 'NVDA',
          action: TradeAction.sell,
          qty: 2,
          price: 197,
          reasoning: 'Stop loss',
          signal: signalFor('Stop loss'),
          createdAt: DateTime(2026, 4, 6, 10, 14),
        ),
      ];

      final analytics = QuickTradeAnalytics.fromTradeLogs(logs);

      expect(analytics.rounds, 2);
      expect(analytics.wins, 1);
      expect(analytics.losses, 1);
      expect(analytics.netPnl, closeTo(14, 0.001));
      expect(analytics.expectancy, closeTo(7, 0.001));
      expect(analytics.byEntryType[EntryType.dip]?.netPnl, closeTo(20, 0.001));
      expect(
        analytics.byEntryType[EntryType.breakout]?.netPnl,
        closeTo(-6, 0.001),
      );
    });

    test('ignores submitted orders without confirmed fill prices', () {
      final logs = [
        TradeLog(
          ticker: 'AAPL',
          action: TradeAction.buy,
          qty: null,
          price: null,
          orderId: 'buy-submitted',
          reasoning: 'Buy submitted',
          signal: signalFor('Dip + RSI + VWAP confirmed'),
          createdAt: DateTime(2026, 4, 6, 10, 0),
        ),
        TradeLog(
          ticker: 'AAPL',
          action: TradeAction.buy,
          qty: 10,
          price: 100,
          orderId: 'buy-filled',
          reasoning: 'Dip buy: -2.1% from high',
          signal: signalFor('Dip + RSI + VWAP confirmed'),
          createdAt: DateTime(2026, 4, 6, 10, 1),
        ),
        TradeLog(
          ticker: 'AAPL',
          action: TradeAction.takeProfitSell,
          qty: 10,
          price: 101.5,
          orderId: 'sell-filled',
          reasoning: 'Take profit fill',
          signal: signalFor('Take profit'),
          createdAt: DateTime(2026, 4, 6, 10, 5),
        ),
      ];

      final analytics = QuickTradeAnalytics.fromTradeLogs(logs);

      expect(analytics.rounds, 1);
      expect(analytics.netPnl, closeTo(15, 0.001));
    });
  });

  group('QuickTrade restart reconciliation', () {
    late HiveStore store;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('quick_trade_recovery_');
      store = HiveStore();
      await store.init(path: tempDir.path);
    });

    tearDown(() async {
      await store.close();
      await Hive.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'rebuilds status from broker positions and open orders on start',
      () async {
        Signal signalFor(String ticker, String reasoning, DateTime createdAt) =>
            Signal(
              ticker: ticker,
              sentiment: Sentiment.bullish,
              confidence: 1.0,
              timeframe: Timeframe.short,
              reasoning: reasoning,
              sourceHeadlines: const [],
              createdAt: createdAt,
            );

        final now = DateTime.now();
        // Pin "today" to noon so that subtracting hours never crosses midnight.
        final todayNoon = DateTime(now.year, now.month, now.day, 12);
        final yesterday = now.subtract(const Duration(days: 1));

        await store.saveTrades([
          TradeLog(
            ticker: 'MSFT',
            action: TradeAction.buy,
            qty: 1,
            price: 100,
            orderId: 'msft-buy',
            roundTripId: 'msft-round',
            executionStatus: TradeExecutionStatus.filled,
            executedAt: todayNoon.subtract(const Duration(hours: 2)),
            reasoning: 'Dip buy: recovered closed round',
            signal: signalFor('MSFT', 'Dip + RSI + VWAP confirmed', todayNoon),
            createdAt: todayNoon.subtract(const Duration(hours: 2, minutes: 1)),
          ),
          TradeLog(
            ticker: 'MSFT',
            action: TradeAction.takeProfitSell,
            qty: 1,
            price: 110,
            orderId: 'msft-sell',
            roundTripId: 'msft-round',
            executionStatus: TradeExecutionStatus.filled,
            executedAt: todayNoon.subtract(const Duration(hours: 1)),
            reasoning: 'Take profit fill',
            signal: signalFor('MSFT', 'Take profit', todayNoon),
            createdAt: todayNoon.subtract(const Duration(hours: 1, minutes: 1)),
          ),
          TradeLog(
            ticker: 'AAPL',
            action: TradeAction.buy,
            qty: 2,
            price: 100,
            orderId: 'aapl-buy',
            roundTripId: 'aapl-round',
            executionStatus: TradeExecutionStatus.filled,
            executedAt: yesterday,
            reasoning: 'Dip buy: existing open round',
            signal: signalFor('AAPL', 'Dip + RSI + VWAP confirmed', yesterday),
            createdAt: yesterday.subtract(const Duration(minutes: 1)),
          ),
          TradeLog(
            ticker: 'AMD',
            action: TradeAction.buy,
            qty: 3,
            price: 20,
            orderId: 'amd-buy',
            roundTripId: 'amd-round',
            executionStatus: TradeExecutionStatus.filled,
            executedAt: yesterday.subtract(const Duration(hours: 1)),
            reasoning: 'Breakout buy: open exit pending',
            signal: signalFor(
              'AMD',
              'Breakout + volume spike + VWAP confirmed',
              yesterday.subtract(const Duration(hours: 1)),
            ),
            createdAt: yesterday.subtract(const Duration(hours: 1, minutes: 1)),
          ),
        ]);

        await store.saveManagedPosition(
          ManagedPosition(
            symbol: 'TSLA',
            buyOrderId: 'managed-tsla',
            entryPrice: 300,
            originalQty: 1,
            remainingQty: 1,
            entryTime: DateTime(2026, 4, 1),
          ),
        );

        final client = _FakeAlpacaClient(
          account: const Account(
            id: 'acct-1',
            accountNumber: 'paper-1',
            status: 'ACTIVE',
            currency: 'USD',
            equity: 10000,
            cash: 5000,
            buyingPower: 10000,
            portfolioValue: 10000,
            lastEquity: 9900,
          ),
          positions: const [
            PositionSnapshot(
              symbol: 'AAPL',
              qty: 2,
              avgEntryPrice: 100,
              currentPrice: 110,
            ),
            PositionSnapshot(
              symbol: 'NVDA',
              qty: 1,
              avgEntryPrice: 50,
              currentPrice: 51,
            ),
            PositionSnapshot(
              symbol: 'AMD',
              qty: 2,
              avgEntryPrice: 20,
              currentPrice: 24,
            ),
            PositionSnapshot(
              symbol: 'TSLA',
              qty: 1,
              avgEntryPrice: 300,
              currentPrice: 305,
            ),
          ],
          openOrders: [
            {
              'id': 'nvda-open-buy',
              'symbol': 'NVDA',
              'side': 'buy',
              'notional': '300',
              'filled_qty': '1',
              'filled_avg_price': '50',
              'submitted_at': now.toIso8601String(),
            },
            {
              'id': 'amd-open-sell',
              'symbol': 'AMD',
              'side': 'sell',
              'filled_qty': '1',
              'filled_avg_price': '22',
              'submitted_at': now.toIso8601String(),
            },
          ],
        );

        final engine = QuickTradeEngine(
          client: client,
          priceStream: _FakePriceStream(),
          store: store,
          orderMonitor: _FakeOrderMonitor(),
          tradingLock: TradingLock(),
          riskManager: RiskManager(client: client),
          accountLock: AccountLock(),
        );

        await engine.start(['AAPL', 'NVDA', 'AMD', 'TSLA']);

        expect(engine.status.state, QuickTradeEngineState.running);
        expect(engine.status.budgetLimit, 1000);
        expect(engine.status.budgetUsed, closeTo(540, 0.001));
        expect(engine.status.openPositions, 3);
        expect(engine.status.totalTrades, 1);
        expect(engine.status.sessionPnL, closeTo(10, 0.001));
        expect(
          engine.status.recentLogs.any((log) => log.ticker == 'MSFT'),
          isTrue,
        );

        engine.dispose();
      },
    );

    test(
      'creates broker stop orders for recovered quick-trade positions',
      () async {
        final now = DateTime.now();
        await store.saveTrade(
          TradeLog(
            ticker: 'AAPL',
            action: TradeAction.buy,
            qty: 2,
            price: 100,
            orderId: 'aapl-buy',
            roundTripId: 'aapl-round',
            executionStatus: TradeExecutionStatus.filled,
            executedAt: now.subtract(const Duration(minutes: 5)),
            reasoning: 'Dip buy: recovered open round',
            signal: Signal(
              ticker: 'AAPL',
              sentiment: Sentiment.bullish,
              confidence: 1,
              timeframe: Timeframe.short,
              reasoning: 'Dip + RSI + VWAP confirmed',
              sourceHeadlines: const [],
              createdAt: now.subtract(const Duration(minutes: 6)),
            ),
            createdAt: now.subtract(const Duration(minutes: 6)),
          ),
        );

        final client = _FakeAlpacaClient(
          account: const Account(
            id: 'acct-1',
            accountNumber: 'paper-1',
            status: 'ACTIVE',
            currency: 'USD',
            equity: 10000,
            cash: 5000,
            buyingPower: 10000,
            portfolioValue: 10000,
            lastEquity: 9900,
          ),
          positions: const [
            PositionSnapshot(
              symbol: 'AAPL',
              qty: 2,
              avgEntryPrice: 100,
              currentPrice: 101,
            ),
          ],
        );

        final engine = QuickTradeEngine(
          client: client,
          priceStream: _FakePriceStream(),
          store: store,
          orderMonitor: _FakeOrderMonitor(),
          tradingLock: TradingLock(),
          riskManager: RiskManager(client: client),
          accountLock: AccountLock(),
        );

        await engine.start(['AAPL']);

        expect(
          client.placedOrders.any(
            (order) => order['symbol'] == 'AAPL' && order['type'] == 'stop',
          ),
          isTrue,
        );
        expect(client.closedPositions, isEmpty);

        engine.dispose();
      },
    );

    test(
      'force-closes recovered positions when broker stop cannot be created',
      () async {
        final now = DateTime.now();
        await store.saveTrade(
          TradeLog(
            ticker: 'AAPL',
            action: TradeAction.buy,
            qty: 2,
            price: 100,
            orderId: 'aapl-buy',
            roundTripId: 'aapl-round',
            executionStatus: TradeExecutionStatus.filled,
            executedAt: now.subtract(const Duration(minutes: 5)),
            reasoning: 'Dip buy: recovered open round',
            signal: Signal(
              ticker: 'AAPL',
              sentiment: Sentiment.bullish,
              confidence: 1,
              timeframe: Timeframe.short,
              reasoning: 'Dip + RSI + VWAP confirmed',
              sourceHeadlines: const [],
              createdAt: now.subtract(const Duration(minutes: 6)),
            ),
            createdAt: now.subtract(const Duration(minutes: 6)),
          ),
        );

        final client = _FakeAlpacaClient(
          account: const Account(
            id: 'acct-1',
            accountNumber: 'paper-1',
            status: 'ACTIVE',
            currency: 'USD',
            equity: 10000,
            cash: 5000,
            buyingPower: 10000,
            portfolioValue: 10000,
            lastEquity: 9900,
          ),
          positions: const [
            PositionSnapshot(
              symbol: 'AAPL',
              qty: 2,
              avgEntryPrice: 100,
              currentPrice: 101,
            ),
          ],
          failStopOrders: {'AAPL'},
        );

        final engine = QuickTradeEngine(
          client: client,
          priceStream: _FakePriceStream(),
          store: store,
          orderMonitor: _FakeOrderMonitor(),
          tradingLock: TradingLock(),
          riskManager: RiskManager(client: client),
          accountLock: AccountLock(),
        );

        await engine.start(['AAPL']);

        expect(client.closedPositions, contains('AAPL'));
        expect(
          engine.logs.any(
            (log) =>
                log.ticker == 'AAPL' &&
                log.reasoning.contains('missing broker stop-loss protection'),
          ),
          isTrue,
        );

        engine.dispose();
      },
    );
  });
}
