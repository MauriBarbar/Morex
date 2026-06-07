import 'package:flutter_test/flutter_test.dart';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/models/account.dart';
import 'package:morex/core/models/asset_info.dart';
import 'package:morex/core/models/historical_bar.dart';
import 'package:morex/core/models/market_clock.dart';
import 'package:morex/core/models/market_snapshot.dart';
import 'package:morex/core/models/position.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/core/models/symbol_validation_result.dart';
import 'package:morex/engine/risk_manager.dart';

// Fake that lets tests control account, positions, and open orders.
class _FakeAlpacaClient implements AlpacaClient {
  final Account account;
  final List<Position> positions;
  final List<Map<String, dynamic>> openOrders;
  final Map<String, MarketSnapshot> snapshots;
  final Map<String, AssetInfo> assets;

  _FakeAlpacaClient({
    required this.account,
    this.positions = const [],
    this.openOrders = const [],
    this.snapshots = const {},
    this.assets = const {},
  });

  @override
  Future<Account> getAccount() async => account;

  @override
  Future<List<Position>> getPositions() async => positions;

  @override
  Future<List<Map<String, dynamic>>> getOrders({String status = 'open'}) async =>
      openOrders;

  // --- unused stubs ---
  @override
  Future<void> cancelOrder(String orderId) async {}
  @override
  Future<Map<String, dynamic>> closePosition(String symbol) async => {};
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
  }) async =>
      {};
  @override
  Future<Map<String, dynamic>> replaceOrder(String orderId,
          {double? qty, double? stopPrice}) async =>
      {};
  @override
  Future<Map<String, MarketSnapshot>> getSnapshots(
          List<String> symbols) async =>
      {for (final s in symbols) if (snapshots.containsKey(s)) s: snapshots[s]!};
  @override
  Future<MarketClock> getMarketClock() async => throw UnimplementedError();
  @override
  Future<Map<String, List<HistoricalBar>>> getBars(List<String> symbols,
          {String timeframe = '1Day',
          int limit = 30,
          DateTime? start,
          DateTime? end}) async =>
      {};
  @override
  Future<AssetInfo> getAsset(String symbol) async {
    final asset = assets[symbol];
    if (asset == null) throw UnimplementedError();
    return asset;
  }
  @override
  Future<SymbolValidationResult> validateSymbols(
          List<String> symbols) async =>
      SymbolValidationResult(tradable: symbols, nonTradable: [], notFound: []);
  @override
  Future<void> assertMarketOpen() async {}

  @override
  Future<List<Map<String, dynamic>>> getNews({int limit = 30, List<String>? symbols}) async => [];

  @override
  Future<Map<String, dynamic>> getPortfolioHistory({String period = '1M', String timeframe = '1D'}) async => {};
}

Account _makeAccount({
  double equity = 10000,
  double buyingPower = 10000,
  double lastEquity = 10000,
  int daytradeCount = 0,
  bool patternDayTrader = false,
}) =>
    Account(
      id: 'test',
      accountNumber: '000',
      status: 'ACTIVE',
      currency: 'USD',
      equity: equity,
      cash: buyingPower,
      buyingPower: buyingPower,
      portfolioValue: equity,
      lastEquity: lastEquity,
      daytradeCount: daytradeCount,
      patternDayTrader: patternDayTrader,
    );

AssetInfo _makeAsset(
  String symbol, {
  String status = 'active',
  bool tradable = true,
  bool fractionable = true,
}) =>
    AssetInfo(
      id: symbol,
      symbol: symbol,
      name: symbol,
      exchange: 'NASDAQ',
      assetClass: 'us_equity',
      status: status,
      tradable: tradable,
      fractionable: fractionable,
    );

MarketSnapshot _makeSnapshot(
  String symbol, {
  double price = 100,
  double? bid,
  double? ask,
}) =>
    MarketSnapshot(
      symbol: symbol,
      latestPrice: price,
      previousClose: price,
      dailyChangePercent: 0,
      volume: 1000000,
      bid: bid,
      ask: ask,
    );

Signal _bullishSignal(String ticker) => Signal(
      ticker: ticker,
      sentiment: Sentiment.bullish,
      confidence: 0.80,
      timeframe: Timeframe.medium,
      reasoning: 'Test',
      sourceHeadlines: const [],
      createdAt: DateTime(2026, 4, 17),
    );

void main() {
  group('RiskManager.evaluate — total exposure', () {
    test('approves signal when exposure is within limit', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(account: _makeAccount()),
        config: const RiskConfig(maxTotalExposurePercent: 0.80),
      );

      final results = await rm.evaluate([_bullishSignal('AAPL')]);

      expect(results.single.approved, isTrue);
    });

    test('rejects when filled positions already exceed exposure limit', () async {
      // $8 500 invested of $10 000 equity = 85% — above 80% limit
      final positions = <Position>[
        Position(
          assetId: 'msft',
          symbol: 'MSFT',
          qty: 10,
          marketValue: 8500,
          avgEntryPrice: 850,
          currentPrice: 850,
          unrealizedPnL: 0,
          unrealizedPnLPercent: 0,
          side: 'long',
        ),
      ];

      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(equity: 10000),
          positions: positions,
        ),
        config: const RiskConfig(maxTotalExposurePercent: 0.80),
      );

      final results = await rm.evaluate([_bullishSignal('AAPL')]);

      expect(results.single.approved, isFalse);
      expect(results.single.reason, contains('exceeds limit'));
    });

    test('rejects when pending buy orders push exposure over limit', () async {
      // Positions: $5 000 (50%). Pending buy: $4 000. Together: 90% > 80% limit.
      final positions = <Position>[
        Position(
          assetId: 'msft',
          symbol: 'MSFT',
          qty: 5,
          marketValue: 5000,
          avgEntryPrice: 1000,
          currentPrice: 1000,
          unrealizedPnL: 0,
          unrealizedPnLPercent: 0,
          side: 'long',
        ),
      ];
      final openOrders = [
        {
          'side': 'buy',
          'status': 'new',
          'notional': '4000',
          'symbol': 'TSLA',
        },
      ];

      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(equity: 10000),
          positions: positions,
          openOrders: openOrders,
        ),
        config: const RiskConfig(maxTotalExposurePercent: 0.80),
      );

      final results = await rm.evaluate([_bullishSignal('AAPL')]);

      expect(results.single.approved, isFalse);
      expect(results.single.reason, contains('pending'));
    });

    test('approves when pending buys are sells (not counted against exposure)',
        () async {
      final openOrders = [
        {
          'side': 'sell', // sell order — should not count toward exposure
          'status': 'new',
          'notional': '4000',
          'symbol': 'TSLA',
        },
      ];

      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(equity: 10000),
          openOrders: openOrders,
        ),
        config: const RiskConfig(maxTotalExposurePercent: 0.80),
      );

      final results = await rm.evaluate([_bullishSignal('AAPL')]);

      expect(results.single.approved, isTrue);
    });

    test('only counts pending orders with active statuses', () async {
      // A filled or cancelled order should not count
      final openOrders = [
        {
          'side': 'buy',
          'status': 'filled', // already filled — not pending
          'notional': '9000',
          'symbol': 'TSLA',
        },
      ];

      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(equity: 10000),
          openOrders: openOrders,
        ),
        config: const RiskConfig(maxTotalExposurePercent: 0.80),
      );

      final results = await rm.evaluate([_bullishSignal('AAPL')]);

      expect(results.single.approved, isTrue);
    });
  });

  group('RiskManager._isPendingOrderStatus', () {
    test('recognises all pending statuses', () {
      for (final status in [
        'new',
        'pending_new',
        'accepted',
        'held',
        'partially_filled',
      ]) {
        expect(RiskManager.isPendingOrderStatus(status), isTrue,
            reason: '$status should be pending');
      }
    });

    test('rejects terminal statuses', () {
      for (final status in ['filled', 'canceled', 'expired', 'done_for_day']) {
        expect(RiskManager.isPendingOrderStatus(status), isFalse,
            reason: '$status should not be pending');
      }
    });
  });

  group('RiskManager.evaluate — PDT guard', () {
    test('blocks new buy when daytrade_count hits limit under \$25K equity',
        () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(equity: 10000, daytradeCount: 3),
        ),
      );
      final results = await rm.evaluate([_bullishSignal('AAPL')]);
      expect(results.single.approved, isFalse);
      expect(results.single.reason, contains('PDT guard'));
    });

    test('blocks PDT-flagged accounts under \$25K outright', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(equity: 10000, patternDayTrader: true),
        ),
      );
      final results = await rm.evaluate([_bullishSignal('AAPL')]);
      expect(results.single.approved, isFalse);
      expect(results.single.reason, contains('PDT-flagged'));
    });

    test('allows day-trades over \$25K equity', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(
            equity: 30000,
            buyingPower: 30000,
            daytradeCount: 5,
            patternDayTrader: true,
          ),
        ),
      );
      final results = await rm.evaluate([_bullishSignal('AAPL')]);
      expect(results.single.approved, isTrue);
    });

    test('allows sells even when PDT would block buys', () async {
      // Bearish on a held position — exits must always be possible.
      final positions = [
        Position(
          assetId: 'aapl',
          symbol: 'AAPL',
          qty: 1,
          marketValue: 100,
          avgEntryPrice: 100,
          currentPrice: 100,
          unrealizedPnL: 0,
          unrealizedPnLPercent: 0,
          side: 'long',
        ),
      ];
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(equity: 10000, daytradeCount: 5),
          positions: positions,
        ),
      );
      final bearish = Signal(
        ticker: 'AAPL',
        sentiment: Sentiment.bearish,
        confidence: 0.80,
        timeframe: Timeframe.medium,
        reasoning: 'Test',
        sourceHeadlines: const [],
        createdAt: DateTime(2026, 4, 17),
      );
      final results = await rm.evaluate([bearish]);
      expect(results.single.approved, isTrue);
    });
  });

  group('RiskManager.evaluate — tradable / fractionable guard', () {
    test('blocks inactive asset', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(),
          assets: {'AAPL': _makeAsset('AAPL', status: 'inactive')},
        ),
      );
      final results = await rm.evaluate([_bullishSignal('AAPL')]);
      expect(results.single.approved, isFalse);
      expect(results.single.reason, contains('not tradable'));
    });

    test('blocks non-tradable asset', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(),
          assets: {'AAPL': _makeAsset('AAPL', tradable: false)},
        ),
      );
      final results = await rm.evaluate([_bullishSignal('AAPL')]);
      expect(results.single.approved, isFalse);
      expect(results.single.reason, contains('not tradable'));
    });

    test('blocks non-fractionable asset', () async {
      // AAPL is in the liquid universe; assert only the fractionable check.
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(),
          assets: {'AAPL': _makeAsset('AAPL', fractionable: false)},
        ),
      );
      final results = await rm.evaluate([_bullishSignal('AAPL')]);
      expect(results.single.approved, isFalse);
      expect(results.single.reason, contains('fractional'));
    });
  });

  group('RiskManager.evaluate — spread guard', () {
    test('blocks when spread exceeds limit', () async {
      // bid 99.50, ask 100.50 → spread 1% > 0.3% default
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(),
          snapshots: {
            'AAPL': _makeSnapshot('AAPL', bid: 99.5, ask: 100.5),
          },
        ),
      );
      final results = await rm.evaluate([_bullishSignal('AAPL')]);
      expect(results.single.approved, isFalse);
      expect(results.single.reason, contains('Spread'));
    });

    test('approves when spread is tight', () async {
      // bid 99.99, ask 100.01 → 0.02% < 0.3%
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(),
          snapshots: {
            'AAPL': _makeSnapshot('AAPL', bid: 99.99, ask: 100.01),
          },
        ),
      );
      final results = await rm.evaluate([_bullishSignal('AAPL')]);
      expect(results.single.approved, isTrue);
    });

    test('approves when quote is unavailable (degrades, does not block)',
        () async {
      // No bid/ask — outside RTH or thin tape. Should not block.
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(),
          snapshots: {'AAPL': _makeSnapshot('AAPL')},
        ),
      );
      final results = await rm.evaluate([_bullishSignal('AAPL')]);
      expect(results.single.approved, isTrue);
    });
  });

  group('RiskManager.evaluate — sector cap', () {
    test('blocks second signal in same sector within one scan', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(account: _makeAccount(equity: 100000, buyingPower: 100000)),
        config: const RiskConfig(enableSectorCap: true, maxPerSector: 1),
      );
      // Both NVDA and AMD map to "Semis".
      final results = await rm.evaluate([
        _bullishSignal('NVDA'),
        _bullishSignal('AMD'),
      ]);
      expect(results[0].approved, isTrue);
      expect(results[1].approved, isFalse);
      expect(results[1].reason, contains('Sector Semis'));
    });

    test('blocks new signal when existing position fills the sector', () async {
      final positions = [
        Position(
          assetId: 'nvda',
          symbol: 'NVDA',
          qty: 1,
          marketValue: 500,
          avgEntryPrice: 500,
          currentPrice: 500,
          unrealizedPnL: 0,
          unrealizedPnLPercent: 0,
          side: 'long',
        ),
      ];
      final rm = RiskManager(
        client: _FakeAlpacaClient(
          account: _makeAccount(equity: 100000, buyingPower: 100000),
          positions: positions,
        ),
        config: const RiskConfig(enableSectorCap: true, maxPerSector: 1),
      );
      final results = await rm.evaluate([_bullishSignal('AMD')]);
      expect(results.single.approved, isFalse);
      expect(results.single.reason, contains('Sector Semis'));
    });

    test('off by default — both semis approved', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(account: _makeAccount(equity: 100000, buyingPower: 100000)),
      );
      final results = await rm.evaluate([
        _bullishSignal('NVDA'),
        _bullishSignal('AMD'),
      ]);
      expect(results.every((r) => r.approved), isTrue);
    });

    test('uncategorised symbols are not capped', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(account: _makeAccount(equity: 100000, buyingPower: 100000)),
        // Disable the liquid-universe gate so the FOOBARs reach the sector
        // logic; uncategorised should pass through both checks.
        config: const RiskConfig(
          enableSectorCap: true,
          maxPerSector: 1,
          enableLiquidUniverseOnly: false,
        ),
      );
      final results = await rm.evaluate([
        _bullishSignal('FOOBAR1'),
        _bullishSignal('FOOBAR2'),
      ]);
      expect(results.every((r) => r.approved), isTrue);
    });
  });

  group('RiskManager.evaluate — liquid universe', () {
    test('blocks symbols outside the universe by default', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(account: _makeAccount()),
      );
      final results = await rm.evaluate([_bullishSignal('SOMERANDOMTICKER')]);
      expect(results.single.approved, isFalse);
      expect(results.single.reason, contains('liquid universe'));
    });

    test('approves liquid mega-caps', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(account: _makeAccount()),
      );
      final results = await rm.evaluate([
        _bullishSignal('AAPL'),
        _bullishSignal('NVDA'),
        _bullishSignal('SPY'),
      ]);
      expect(results.every((r) => r.approved), isTrue);
    });

    test('disabling the gate allows arbitrary symbols', () async {
      final rm = RiskManager(
        client: _FakeAlpacaClient(account: _makeAccount()),
        config: const RiskConfig(enableLiquidUniverseOnly: false),
      );
      final results = await rm.evaluate([_bullishSignal('SOMERANDOMTICKER')]);
      expect(results.single.approved, isTrue);
    });
  });
}
