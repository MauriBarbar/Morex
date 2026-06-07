import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:morex/core/logger.dart';
import 'package:morex/core/models/managed_position.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/core/models/trade_log.dart';

const _tradeLogsBoxName = 'trade_logs';
const _signalsBoxName = 'signals';
const _settingsBoxName = 'settings';
const _managedPositionsBoxName = 'managed_positions';
const _hiveEncryptionKeyName = 'hive_encryption_key';

class HiveStore {
  late Box<Map> _tradeBox;
  late Box<Map> _signalBox;
  late Box _settingsBox;
  late Box<Map> _managedBox;
  bool _isInitialized = false;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  bool get isInitialized => _isInitialized;

  Future<void> init({String? path}) async {
    if (path != null) {
      Hive.init(path);
    } else {
      await Hive.initFlutter();
    }

    // Get or create encryption key.
    // On key corruption (e.g. malformed hex), rotate: delete the corrupt key,
    // generate a fresh one, and delete the now-unreadable boxes before reopening.
    // We do NOT delete boxes before confirming the new key is valid — that would
    // cause data loss on transient platform errors (keychain locked, etc.).
    HiveAesCipher cipher;
    try {
      cipher = await _getEncryptionCipher();
    } catch (e) {
      Log.e('HiveStore', 'Failed to get encryption key — attempting key rotation', e);
      try {
        await _secureStorage.delete(key: _hiveEncryptionKeyName);
        cipher = await _getEncryptionCipher(); // Generates and stores a fresh key
        // Old boxes are encrypted with the lost key and are no longer readable.
        // Delete them so Hive can create fresh encrypted boxes below.
        for (final name in [
          _tradeLogsBoxName,
          _signalsBoxName,
          _settingsBoxName,
          _managedPositionsBoxName,
        ]) {
          try {
            await Hive.deleteBoxFromDisk(name);
          } catch (_) {}
        }
        Log.i('HiveStore', 'Key rotation complete — starting with fresh encrypted storage');
      } catch (e2) {
        Log.e('HiveStore', 'Key rotation failed — secure storage unavailable', e2);
        rethrow;
      }
    }

    // Open boxes with encryption
    _tradeBox = await Hive.openBox<Map>(_tradeLogsBoxName, encryptionCipher: cipher);
    _signalBox = await Hive.openBox<Map>(_signalsBoxName, encryptionCipher: cipher);
    _settingsBox = await Hive.openBox(_settingsBoxName, encryptionCipher: cipher);
    _managedBox = await Hive.openBox<Map>(_managedPositionsBoxName, encryptionCipher: cipher);

    _isInitialized = true;
  }

  /// Get or create the 32-byte AES encryption key.
  Future<HiveAesCipher> _getEncryptionCipher() async {
    String? keyStr = await _secureStorage.read(key: _hiveEncryptionKeyName);

    if (keyStr == null) {
      // Generate a new 32-byte key
      final key = _generateEncryptionKey();
      keyStr = _keyToHexString(key);
      await _secureStorage.write(key: _hiveEncryptionKeyName, value: keyStr);
      Log.i('HiveStore', 'Generated new encryption key');
    }

    final key = _hexStringToKey(keyStr);
    return HiveAesCipher(key);
  }

  /// Generate a random 32-byte encryption key.
  Uint8List _generateEncryptionKey() {
    return Uint8List.fromList(Hive.generateSecureKey());
  }

  /// Convert Uint8List key to hex string for secure storage.
  String _keyToHexString(Uint8List key) {
    return key.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Convert hex string back to Uint8List key.
  Uint8List _hexStringToKey(String hexStr) {
    final bytes = <int>[];
    for (int i = 0; i < hexStr.length; i += 2) {
      bytes.add(int.parse(hexStr.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  // --- Trade Logs ---

  Future<void> saveTrade(TradeLog log) async {
    if (!_isInitialized) {
      Log.w('HiveStore', 'Trade log save attempted before Hive initialization: ${log.ticker}');
      return;
    }
    if (!_tradeBox.isOpen) {
      throw Exception('Trade box is closed; cannot save trade for ${log.ticker}');
    }
    await _tradeBox.add(_tradeToMap(log));
  }

  Future<void> saveTrades(List<TradeLog> logs) async {
    if (!_isInitialized) return;
    for (final log in logs) {
      await _tradeBox.add(_tradeToMap(log));
    }
  }

  List<TradeLog> getTrades({int limit = 50}) {
    if (!_isInitialized) return [];
    final entries = _tradeBox.values.toList().reversed.take(limit);
    return entries.map(_tradeFromMap).toList();
  }

  Future<void> clearTrades() async {
    if (!_isInitialized) return;
    await _tradeBox.clear();
  }

  Map<String, dynamic> _tradeToMap(TradeLog log) {
    return {
      'ticker': log.ticker,
      'action': log.action.name,
      'qty': log.qty,
      'price': log.price,
      'expectedPrice': log.expectedPrice,
      'orderId': log.orderId,
      'roundTripId': log.roundTripId,
      'executionStatus': log.executionStatus?.name,
      'executedAt': log.executedAt?.toIso8601String(),
      'reasoning': log.reasoning,
      'signal': _signalToMap(log.signal),
      'createdAt': log.createdAt.toIso8601String(),
    };
  }

  TradeLog _tradeFromMap(Map map) {
    return TradeLog(
      ticker: map['ticker'] ?? '',
      action: TradeAction.values.firstWhere(
        (a) => a.name == map['action'],
        orElse: () => TradeAction.skip,
      ),
      qty: (map['qty'] as num?)?.toDouble(),
      price: (map['price'] as num?)?.toDouble(),
      expectedPrice: (map['expectedPrice'] as num?)?.toDouble(),
      orderId: map['orderId'],
      roundTripId: map['roundTripId'],
      executionStatus: _tradeExecutionStatusFromName(map['executionStatus']),
      executedAt: map['executedAt'] != null
          ? DateTime.tryParse('${map['executedAt']}')
          : null,
      reasoning: map['reasoning'] ?? '',
      signal: _signalFromMap(Map<String, dynamic>.from(map['signal'] ?? {})),
      createdAt:
          DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
    );
  }

  TradeExecutionStatus? _tradeExecutionStatusFromName(Object? value) {
    if (value == null) return null;
    for (final status in TradeExecutionStatus.values) {
      if (status.name == value) return status;
    }
    return null;
  }

  // --- Signals ---

  Future<void> saveSignal(Signal signal) async {
    if (!_isInitialized) return;
    await _signalBox.add(_signalToMap(signal));
  }

  Future<void> saveSignals(List<Signal> signals) async {
    if (!_isInitialized) return;
    for (final s in signals) {
      await _signalBox.add(_signalToMap(s));
    }
  }

  List<Signal> getSignals({int limit = 50}) {
    if (!_isInitialized) return [];
    final entries = _signalBox.values.toList().reversed.take(limit);
    return entries
        .map((m) => _signalFromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> clearSignals() async {
    if (!_isInitialized) return;
    await _signalBox.clear();
  }

  Map<String, dynamic> _signalToMap(Signal signal) {
    return {
      'ticker': signal.ticker,
      'sentiment': signal.sentiment.name,
      'confidence': signal.confidence,
      'timeframe': signal.timeframe.name,
      'reasoning': signal.reasoning,
      'sourceHeadlines': signal.sourceHeadlines,
      'createdAt': signal.createdAt.toIso8601String(),
    };
  }

  Signal _signalFromMap(Map<String, dynamic> map) {
    return Signal(
      ticker: map['ticker'] ?? '',
      sentiment: Sentiment.values.firstWhere(
        (s) => s.name == map['sentiment'],
        orElse: () => Sentiment.neutral,
      ),
      confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
      timeframe: Timeframe.values.firstWhere(
        (t) => t.name == map['timeframe'],
        orElse: () => Timeframe.short,
      ),
      reasoning: map['reasoning'] ?? '',
      sourceHeadlines: List<String>.from(map['sourceHeadlines'] ?? []),
      createdAt:
          DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
    );
  }

  // --- Managed Positions ---

  Future<void> saveManagedPosition(ManagedPosition pos) async {
    if (!_isInitialized) return;
    await _managedBox.put(pos.symbol, pos.toMap());
  }

  List<ManagedPosition> getManagedPositions() {
    if (!_isInitialized) return [];
    return _managedBox.values
        .map((m) => ManagedPosition.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> removeManagedPosition(String symbol) async {
    if (!_isInitialized) return;
    await _managedBox.delete(symbol);
  }

  Future<void> clearManagedPositions() async {
    if (!_isInitialized) return;
    await _managedBox.clear();
  }

  // --- Settings ---

  Future<void> setSetting(String key, dynamic value) async {
    if (!_isInitialized) return;
    await _settingsBox.put(key, value);
  }

  T? getSetting<T>(String key, {T? defaultValue}) {
    if (!_isInitialized) return defaultValue;
    final value = _settingsBox.get(key, defaultValue: defaultValue);
    if (value is T) return value;
    if (value == null) return defaultValue;
    Log.w('HiveStore', 'getSetting: key "$key" has type ${value.runtimeType}, expected $T — returning default');
    return defaultValue;
  }

  Future<void> close() async {
    if (!_isInitialized) return;
    await _tradeBox.close();
    await _signalBox.close();
    await _settingsBox.close();
    await _managedBox.close();
    _isInitialized = false;
  }

  /// Delete all stored data and encryption key. Used for storage recovery on corruption.
  Future<void> deleteAll() async {
    try {
      // Close boxes if open
      if (_isInitialized) {
        try {
          await _tradeBox.close();
        } catch (_) {}
        try {
          await _signalBox.close();
        } catch (_) {}
        try {
          await _settingsBox.close();
        } catch (_) {}
        try {
          await _managedBox.close();
        } catch (_) {}
        _isInitialized = false;
      }

      // Delete all box files from disk
      await Hive.deleteBoxFromDisk(_tradeLogsBoxName);
      await Hive.deleteBoxFromDisk(_signalsBoxName);
      await Hive.deleteBoxFromDisk(_settingsBoxName);
      await Hive.deleteBoxFromDisk(_managedPositionsBoxName);

      // Delete encryption key from secure storage
      await _secureStorage.delete(key: _hiveEncryptionKeyName);
      Log.i('HiveStore', 'All storage data and encryption key deleted');
    } catch (e) {
      Log.e('HiveStore', 'Failed to delete all storage', e);
      rethrow;
    }
  }
}
