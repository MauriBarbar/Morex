import 'package:dio/dio.dart';
import 'package:morex/config/env.dart';
import 'package:morex/core/models/account.dart';
import 'package:morex/core/models/position.dart';

class AlpacaClient {
  late final Dio _dio;

  AlpacaClient() {
    _dio = Dio(
      BaseOptions(
        baseUrl: Env.alpacaBaseUrl,
        headers: {
          'APCA-API-KEY-ID': Env.alpacaApiKey,
          'APCA-API-SECRET-KEY': Env.alpacaApiSecret,
        },
      ),
    );
  }

  Future<Account> getAccount() async {
    final response = await _dio.get('/v2/account');
    return Account.fromJson(response.data);
  }

  Future<List<Position>> getPositions() async {
    final response = await _dio.get('/v2/positions');
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
  }) async {
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
    if (stopPrice != null) {
      body['stop_price'] = stopPrice.toStringAsFixed(2);
    }

    final response = await _dio.post('/v2/orders', data: body);
    return response.data;
  }

  Future<void> closePosition(String symbol) async {
    await _dio.delete('/v2/positions/$symbol');
  }

  Future<List<Map<String, dynamic>>> getOrders({String status = 'open'}) async {
    final response = await _dio.get('/v2/orders', queryParameters: {'status': status});
    return List<Map<String, dynamic>>.from(response.data);
  }
}
