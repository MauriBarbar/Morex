import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/models/historical_bar.dart';
import 'package:morex/core/models/market_clock.dart';
import 'package:morex/providers/alpaca_providers.dart';

/// Parameters for fetching historical bars.
class BarsParams {
  final String symbol;
  final String timeframe;
  final int limit;
  final DateTime? start;
  final DateTime? end;

  const BarsParams({
    required this.symbol,
    this.timeframe = '1Day',
    this.limit = 30,
    this.start,
    this.end,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BarsParams &&
          runtimeType == other.runtimeType &&
          symbol == other.symbol &&
          timeframe == other.timeframe &&
          limit == other.limit &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode =>
      symbol.hashCode ^
      timeframe.hashCode ^
      limit.hashCode ^
      start.hashCode ^
      end.hashCode;
}

/// Polls the Alpaca market clock every 60 seconds.
/// Emits the latest MarketClock so the UI can show open/closed status.
final marketClockProvider = StreamProvider.autoDispose<MarketClock>((ref) {
  final client = ref.read(alpacaClientProvider);
  final controller = StreamController<MarketClock>.broadcast();

  Future<void> fetch() async {
    try {
      final clock = await client.getMarketClock();
      if (!controller.isClosed) controller.add(clock);
    } catch (_) {
      // Silently ignore — UI handles the loading/error states
    }
  }

  fetch();
  final timer = Timer.periodic(const Duration(seconds: 60), (_) => fetch());

  ref.onDispose(() {
    timer.cancel();
    controller.close();
  });

  return controller.stream;
});

/// Provider for historical bars — parameterized by symbol and timeframe.
final barsProvider = AsyncNotifierProvider.family<
    BarsNotifier,
    List<HistoricalBar>,
    BarsParams>(BarsNotifier.new);

class BarsNotifier extends FamilyAsyncNotifier<List<HistoricalBar>, BarsParams> {
  @override
  Future<List<HistoricalBar>> build(BarsParams params) async {
    final allBars = await ref.read(alpacaClientProvider).getBars(
          [params.symbol],
          timeframe: params.timeframe,
          limit: params.limit,
          start: params.start,
          end: params.end,
        );
    return allBars[params.symbol] ?? [];
  }

  /// Refresh bars for the current parameters.
  Future<void> refresh() async {
    state = await AsyncValue.guard(() => build(arg));
  }
}
