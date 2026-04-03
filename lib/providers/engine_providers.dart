import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/engine/order_executor.dart';
import 'package:morex/engine/risk_manager.dart';
import 'package:morex/engine/trading_engine.dart';
import 'package:morex/providers/alpaca_providers.dart';
import 'package:morex/providers/signal_providers.dart';

final riskManagerProvider = Provider<RiskManager>((ref) {
  return RiskManager(client: ref.watch(alpacaClientProvider));
});

final orderExecutorProvider = Provider<OrderExecutor>((ref) {
  return OrderExecutor(client: ref.watch(alpacaClientProvider));
});

final tradingEngineProvider = Provider<TradingEngine>((ref) {
  final engine = TradingEngine(
    analyzer: ref.watch(sentimentAnalyzerProvider),
    riskManager: ref.watch(riskManagerProvider),
    orderExecutor: ref.watch(orderExecutorProvider),
    alpacaClient: ref.watch(alpacaClientProvider),
  );
  ref.onDispose(() => engine.dispose());
  return engine;
});

final engineStatusProvider = StreamProvider<EngineStatus>((ref) {
  final engine = ref.watch(tradingEngineProvider);
  return engine.statusStream;
});
