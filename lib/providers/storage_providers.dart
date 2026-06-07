import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/db/hive_store.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/core/models/signal.dart';

final hiveStoreProvider = FutureProvider<HiveStore>((ref) async {
  final store = HiveStore();
  await store.init();
  ref.onDispose(() => store.close());
  return store;
});

final storedTradesProvider = FutureProvider<List<TradeLog>>((ref) async {
  final store = await ref.watch(hiveStoreProvider.future);
  return store.getTrades();
});

final storedSignalsProvider = FutureProvider<List<Signal>>((ref) async {
  final store = await ref.watch(hiveStoreProvider.future);
  return store.getSignals();
});
