import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/models/account.dart';
import 'package:morex/core/models/position.dart';

final alpacaClientProvider = Provider<AlpacaClient>((ref) {
  return AlpacaClient();
});

final accountProvider = FutureProvider.autoDispose<Account>((ref) async {
  final client = ref.watch(alpacaClientProvider);
  return client.getAccount();
});

final positionsProvider =
    FutureProvider.autoDispose<List<Position>>((ref) async {
  final client = ref.watch(alpacaClientProvider);
  return client.getPositions();
});
