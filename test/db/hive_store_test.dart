import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/db/hive_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiveStore store;
  late Directory tempDir;
  final _secureStorageData = <String, String>{};

  setUp(() async {
    // Reset the in-memory secure storage for each test
    _secureStorageData.clear();
    const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      final args = call.arguments as Map?;
      final key = args?['key'] as String?;
      switch (call.method) {
        case 'read':
          return _secureStorageData[key];
        case 'write':
          if (key != null) _secureStorageData[key] = args!['value'] as String? ?? '';
          return null;
        case 'delete':
          if (key != null) _secureStorageData.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(_secureStorageData);
        case 'deleteAll':
          _secureStorageData.clear();
          return null;
        case 'containsKey':
          return _secureStorageData.containsKey(key);
        default:
          return null;
      }
    });

    tempDir = await Directory.systemTemp.createTemp('hive_test_');
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

  Signal makeSignal({String ticker = 'AAPL'}) {
    return Signal(
      ticker: ticker,
      sentiment: Sentiment.bullish,
      confidence: 0.85,
      timeframe: Timeframe.short,
      reasoning: 'Test reasoning',
      sourceHeadlines: ['Headline 1'],
      createdAt: DateTime(2026, 4, 4, 10, 0),
    );
  }

  TradeLog makeTrade({
    String ticker = 'AAPL',
    TradeAction action = TradeAction.buy,
  }) {
    return TradeLog(
      ticker: ticker,
      action: action,
      qty: 10,
      price: 195.50,
      orderId: 'order-123',
      roundTripId: 'round-123',
      executionStatus: TradeExecutionStatus.filled,
      executedAt: DateTime(2026, 4, 4, 10, 31),
      reasoning: 'Test trade',
      signal: makeSignal(ticker: ticker),
      createdAt: DateTime(2026, 4, 4, 10, 30),
    );
  }

  group('Trade Logs', () {
    test('saveTrade and getTrades round-trip', () async {
      final trade = makeTrade();
      await store.saveTrade(trade);

      final trades = store.getTrades();
      expect(trades, hasLength(1));
      expect(trades.first.ticker, 'AAPL');
      expect(trades.first.action, TradeAction.buy);
      expect(trades.first.qty, 10);
      expect(trades.first.price, 195.50);
      expect(trades.first.orderId, 'order-123');
      expect(trades.first.roundTripId, 'round-123');
      expect(trades.first.executionStatus, TradeExecutionStatus.filled);
      expect(trades.first.executedAt, DateTime(2026, 4, 4, 10, 31));
      expect(trades.first.reasoning, 'Test trade');
    });

    test('saveTrades stores multiple', () async {
      await store.saveTrades([
        makeTrade(ticker: 'AAPL'),
        makeTrade(ticker: 'GOOG', action: TradeAction.sell),
      ]);

      final trades = store.getTrades();
      expect(trades, hasLength(2));
    });

    test('getTrades respects limit', () async {
      for (int i = 0; i < 10; i++) {
        await store.saveTrade(makeTrade(ticker: 'T$i'));
      }

      final trades = store.getTrades(limit: 3);
      expect(trades, hasLength(3));
    });

    test('getTrades returns newest first', () async {
      await store.saveTrade(makeTrade(ticker: 'FIRST'));
      await store.saveTrade(makeTrade(ticker: 'SECOND'));

      final trades = store.getTrades();
      expect(trades.first.ticker, 'SECOND');
    });

    test('clearTrades removes all', () async {
      await store.saveTrade(makeTrade());
      await store.clearTrades();

      expect(store.getTrades(), isEmpty);
    });

    test('trade with skip action round-trips', () async {
      final trade = makeTrade(action: TradeAction.skip);
      await store.saveTrade(trade);

      final trades = store.getTrades();
      expect(trades.first.action, TradeAction.skip);
      expect(trades.first.wasExecuted, isFalse);
    });
  });

  group('Signals', () {
    test('saveSignal and getSignals round-trip', () async {
      final signal = makeSignal();
      await store.saveSignal(signal);

      final signals = store.getSignals();
      expect(signals, hasLength(1));
      expect(signals.first.ticker, 'AAPL');
      expect(signals.first.sentiment, Sentiment.bullish);
      expect(signals.first.confidence, 0.85);
      expect(signals.first.timeframe, Timeframe.short);
      expect(signals.first.reasoning, 'Test reasoning');
      expect(signals.first.sourceHeadlines, ['Headline 1']);
    });

    test('saveSignals stores multiple', () async {
      await store.saveSignals([
        makeSignal(ticker: 'AAPL'),
        makeSignal(ticker: 'GOOG'),
      ]);

      expect(store.getSignals(), hasLength(2));
    });

    test('getSignals respects limit', () async {
      for (int i = 0; i < 10; i++) {
        await store.saveSignal(makeSignal(ticker: 'S$i'));
      }

      expect(store.getSignals(limit: 5), hasLength(5));
    });

    test('clearSignals removes all', () async {
      await store.saveSignal(makeSignal());
      await store.clearSignals();

      expect(store.getSignals(), isEmpty);
    });
  });

  group('Settings', () {
    test('setSetting and getSetting round-trip', () async {
      await store.setSetting('engine_interval', 4);

      expect(store.getSetting<int>('engine_interval'), 4);
    });

    test('getSetting returns null for missing key', () {
      expect(store.getSetting<String>('nonexistent'), isNull);
    });

    test('getSetting returns default for missing key', () {
      expect(store.getSetting<int>('missing', defaultValue: 42), 42);
    });

    test('setSetting overwrites existing value', () async {
      await store.setSetting('key', 'old');
      await store.setSetting('key', 'new');

      expect(store.getSetting<String>('key'), 'new');
    });
  });
}
