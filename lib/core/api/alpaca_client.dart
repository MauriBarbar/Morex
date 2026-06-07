import 'dart:async';

import 'package:dio/dio.dart';
import 'package:morex/config/env.dart';
import 'package:morex/core/api/trading_exception.dart';
import 'package:morex/core/logger.dart';
import 'package:morex/core/models/account.dart';
import 'package:morex/core/models/asset_info.dart';
import 'package:morex/core/models/historical_bar.dart';
import 'package:morex/core/models/market_clock.dart';
import 'package:morex/core/models/market_snapshot.dart';
import 'package:morex/core/models/position.dart';
import 'package:morex/core/models/symbol_validation_result.dart';

class AlpacaClient {
  late final Dio _dio;
  late final Dio _dataDio;
  static const _connectTimeout = Duration(seconds: 8);
  static const _sendTimeout = Duration(seconds: 8);
  static const _receiveTimeout = Duration(seconds: 12);
  static const _marketClockCacheDuration = Duration(seconds: 60);

  MarketClock? _cachedClock;
  DateTime? _clockCacheTime;

  AlpacaClient() {
    final headers = {
      'APCA-API-KEY-ID': Env.alpacaApiKey,
      'APCA-API-SECRET-KEY': Env.alpacaApiSecret,
    };
    _dio = Dio(BaseOptions(
      baseUrl: Env.alpacaBaseUrl,
      headers: headers,
      connectTimeout: _connectTimeout,
      sendTimeout: _sendTimeout,
      receiveTimeout: _receiveTimeout,
    ));
    _dataDio = Dio(BaseOptions(
      baseUrl: Env.alpacaDataBaseUrl,
      headers: headers,
      connectTimeout: _connectTimeout,
      sendTimeout: _sendTimeout,
      receiveTimeout: _receiveTimeout,
    ));
  }

  /// Retry helper with exponential backoff.
  /// Retries up to 3 times on 5xx errors and network timeouts.
  /// Fails immediately on 4xx (client errors).
  Future<T> _withRetry<T>(
    Future<T> Function() fn, {
    int maxAttempts = 3,
  }) async {
    int attempt = 0;
    while (true) {
      attempt++;
      try {
        return await fn();
      } on DioException catch (e) {
        final statusCode = e.response?.statusCode;
        final isClientError = statusCode != null && statusCode >= 400 && statusCode < 500;
        final isRetryable = e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            (statusCode != null && statusCode >= 500);

        if (isClientError || attempt >= maxAttempts || !isRetryable) {
          rethrow;
        }

        final backoffMs = 500 * (1 << (attempt - 1));
        Log.d('AlpacaClient',
            'Retry $attempt/$maxAttempts after ${backoffMs}ms: ${_describeDioError(e)}');
        await Future.delayed(Duration(milliseconds: backoffMs));
      }
    }
  }

  Future<Account> getAccount() async {
    final response = await _runTradingRequest(() => _dio.get('/v2/account'));
    return Account.fromJson(response.data);
  }

  Future<List<Position>> getPositions() async {
    final response = await _runTradingRequest(() => _dio.get('/v2/positions'));
    return (response.data as List)
        .map((json) => Position.fromJson(json))
        .toList();
  }

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
    if (symbol.isEmpty) throw ArgumentError('symbol cannot be empty');
    if (qty == null && notional == null) {
      throw ArgumentError('Either qty or notional must be provided');
    }
    if (qty != null && qty <= 0) throw ArgumentError('qty must be positive');
    if (notional != null && notional <= 0) throw ArgumentError('notional must be positive');
    if (limitPrice != null && limitPrice <= 0) throw ArgumentError('limitPrice must be positive');
    // Alpaca rejects notional + limit combinations — limit orders need qty.
    if (limitPrice != null && notional != null && qty == null) {
      throw ArgumentError('Limit orders require qty, not notional');
    }

    final body = <String, dynamic>{
      'symbol': symbol,
      'side': side,
      'type': type,
      'time_in_force': timeInForce,
    };
    if (notional != null) {
      body['notional'] = notional.toStringAsFixed(2);
    } else if (qty != null) {
      body['qty'] = qty.toString();
    }
    if (stopPrice != null) body['stop_price'] = stopPrice.toStringAsFixed(2);
    if (limitPrice != null) body['limit_price'] = limitPrice.toStringAsFixed(2);
    if (clientOrderId != null) body['client_order_id'] = clientOrderId;

    final response =
        await _runTradingRequest(() => _dio.post('/v2/orders', data: body));
    return response.data;
  }

  Future<Map<String, dynamic>> closePosition(String symbol) async {
    final response =
        await _runTradingRequest(() => _dio.delete('/v2/positions/$symbol'));
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<List<Map<String, dynamic>>> getOrders({String status = 'open'}) async {
    final response = await _runTradingRequest(
      () => _dio.get('/v2/orders', queryParameters: {'status': status}),
    );
    return List<Map<String, dynamic>>.from(response.data);
  }

  Future<void> cancelOrder(String orderId) async {
    await _runTradingRequest(() => _dio.delete('/v2/orders/$orderId'));
  }

  /// Atomically replaces an existing order's qty and/or stop price.
  /// Throws on failure (e.g. order already filled/canceled).
  Future<Map<String, dynamic>> replaceOrder(
    String orderId, {
    double? qty,
    double? stopPrice,
  }) async {
    final body = <String, dynamic>{};
    if (qty != null) body['qty'] = qty.toString();
    if (stopPrice != null) body['stop_price'] = stopPrice.toStringAsFixed(2);
    final response = await _runTradingRequest(
      () => _dio.patch('/v2/orders/$orderId', data: body),
    );
    return response.data;
  }

  Future<Map<String, MarketSnapshot>> getSnapshots(List<String> symbols) async {
    if (symbols.isEmpty) return {};
    final response = await _runDataRequest(
      () => _dataDio.get(
        '/v2/stocks/snapshots',
        queryParameters: {'symbols': symbols.join(',')},
      ),
    );
    final data = response.data as Map<String, dynamic>;
    return data.map((symbol, json) => MapEntry(
          symbol,
          MarketSnapshot.fromAlpacaJson(symbol, Map<String, dynamic>.from(json)),
        ));
  }

  /// Get market clock — cached for 60 seconds to avoid hammering the API.
  Future<MarketClock> getMarketClock() async {
    final now = DateTime.now();
    if (_cachedClock != null &&
        _clockCacheTime != null &&
        now.difference(_clockCacheTime!).inSeconds < _marketClockCacheDuration.inSeconds) {
      return _cachedClock!;
    }
    final response = await _runTradingRequest(() => _dio.get('/v2/clock'));
    _cachedClock = MarketClock.fromJson(response.data);
    _clockCacheTime = now;
    return _cachedClock!;
  }

  /// Throws [MarketClosedException] if market is closed.
  Future<void> assertMarketOpen() async {
    final clock = await getMarketClock();
    if (!clock.isOpen) {
      throw MarketClosedException('Market is closed (next open: ${clock.nextOpen})');
    }
  }

  Future<Map<String, List<HistoricalBar>>> getBars(
    List<String> symbols, {
    String timeframe = '1Day',
    int limit = 30,
    DateTime? start,
    DateTime? end,
  }) async {
    if (symbols.isEmpty) return {};
    final params = <String, dynamic>{
      'symbols': symbols.join(','),
      'timeframe': timeframe,
      'limit': limit,
    };
    if (start != null) params['start'] = start.toIso8601String();
    if (end != null) params['end'] = end.toIso8601String();

    final response = await _runDataRequest(
      () => _dataDio.get('/v2/stocks/bars', queryParameters: params),
    );
    final barsData = response.data['bars'] as Map<String, dynamic>? ?? {};
    return barsData.map((symbol, json) {
      final barsList = (json as List?)?.cast<Map<String, dynamic>>() ?? [];
      return MapEntry(symbol, barsList.map((b) => HistoricalBar.fromJson(b)).toList());
    });
  }

  /// Fetch recent news articles from Alpaca's news API.
  /// Returns ticker-tagged articles — much higher quality than RSS for trading.
  Future<List<Map<String, dynamic>>> getNews({
    int limit = 30,
    List<String>? symbols,
  }) async {
    final params = <String, dynamic>{'limit': limit};
    if (symbols != null && symbols.isNotEmpty) {
      params['symbols'] = symbols.join(',');
    }
    final response = await _runDataRequest(
      () => _dataDio.get('/v1beta1/news', queryParameters: params),
    );
    final news = response.data['news'] as List? ?? [];
    return List<Map<String, dynamic>>.from(news);
  }

  /// Fetch portfolio history for equity charting.
  /// [period] examples: "1D", "1W", "1M", "3M", "1A"
  /// [timeframe] examples: "1Min", "5Min", "15Min", "1H", "1D"
  Future<Map<String, dynamic>> getPortfolioHistory({
    String period = '1M',
    String timeframe = '1D',
  }) async {
    final response = await _runTradingRequest(
      () => _dio.get('/v2/account/portfolio/history', queryParameters: {
        'period': period,
        'timeframe': timeframe,
        'extended_hours': true,
      }),
    );
    return Map<String, dynamic>.from(response.data);
  }

  Future<AssetInfo> getAsset(String symbol) async {
    final response = await _runTradingRequest(() => _dio.get('/v2/assets/$symbol'));
    return AssetInfo.fromJson(response.data);
  }

  Future<SymbolValidationResult> validateSymbols(List<String> symbols) async {
    if (symbols.isEmpty) {
      return const SymbolValidationResult(tradable: [], nonTradable: [], notFound: []);
    }
    final tradable = <String>[];
    final nonTradable = <String>[];
    final notFound = <String>[];

    final futures = symbols.map((symbol) async {
      try {
        final asset = await getAsset(symbol);
        if (asset.isActive) {
          tradable.add(symbol);
        } else {
          nonTradable.add(symbol);
        }
      } catch (_) {
        notFound.add(symbol);
      }
    });
    await Future.wait(futures);
    return SymbolValidationResult(tradable: tradable, nonTradable: nonTradable, notFound: notFound);
  }

  Future<Response<dynamic>> _runTradingRequest(
    Future<Response<dynamic>> Function() request,
  ) async {
    _ensureConfigured();
    try {
      return await _withRetry(request);
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      Log.w('AlpacaClient', 'Trading request failed: ${_describeDioError(e)}');
      if (statusCode == 401 || statusCode == 403) {
        throw AlpacaAuthException(_describeDioError(e));
      }
      throw AlpacaApiException(_describeDioError(e), statusCode: statusCode);
    }
  }

  Future<Response<dynamic>> _runDataRequest(
    Future<Response<dynamic>> Function() request,
  ) async {
    _ensureConfigured();
    try {
      return await _withRetry(request);
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      Log.w('AlpacaClient', 'Data request failed: ${_describeDioError(e)}');
      if (statusCode == 401 || statusCode == 403) {
        throw AlpacaAuthException(_describeDioError(e));
      }
      throw AlpacaApiException(_describeDioError(e), statusCode: statusCode);
    }
  }

  void _ensureConfigured() {
    if (Env.alpacaApiKey.isEmpty || Env.alpacaApiSecret.isEmpty) {
      throw AlpacaAuthException('Alpaca API credentials are missing.');
    }
  }

  String _describeDioError(DioException e) {
    final statusCode = e.response?.statusCode;
    final details = e.response?.data;
    if (statusCode != null) {
      return 'Alpaca request failed ($statusCode): ${details ?? e.message}';
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return 'Alpaca request timed out.';
    }
    return 'Alpaca request failed: ${e.message}';
  }
}
