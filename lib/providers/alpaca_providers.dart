import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/models/account.dart';
import 'package:morex/core/models/position.dart';

final alpacaClientProvider = Provider<AlpacaClient>((ref) {
  return AlpacaClient();
});

// Keep data alive for 2 minutes after last listener drops — prevents a loading
// flash when navigating between screens while still allowing GC if the user
// leaves the app idle for a while.
const _cacheWindow = Duration(minutes: 2);

/// Automatically invalidates [accountProvider] and [positionsProvider] every
/// 30 seconds while any widget is watching this provider.
/// Attach via `ref.watch(portfolioAutoRefreshProvider)` on the Dashboard.
final portfolioAutoRefreshProvider = Provider.autoDispose<void>((ref) {
  final timer = Timer.periodic(const Duration(seconds: 30), (_) {
    ref.invalidate(accountProvider);
    ref.invalidate(positionsProvider);
  });
  ref.onDispose(timer.cancel);
});

final accountProvider = FutureProvider.autoDispose<Account>((ref) async {
  final link = ref.keepAlive();
  final timer = Timer(_cacheWindow, link.close);
  ref.onDispose(timer.cancel);
  final client = ref.watch(alpacaClientProvider);
  return client.getAccount();
});

final positionsProvider =
    FutureProvider.autoDispose<List<Position>>((ref) async {
  final link = ref.keepAlive();
  final timer = Timer(_cacheWindow, link.close);
  ref.onDispose(timer.cancel);
  final client = ref.watch(alpacaClientProvider);
  return client.getPositions();
});

/// Portfolio equity history for charting. Parameterized by period.
class PortfolioHistoryParams {
  final String period;
  final String timeframe;
  const PortfolioHistoryParams({this.period = '1M', this.timeframe = '1D'});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PortfolioHistoryParams &&
          period == other.period &&
          timeframe == other.timeframe;

  @override
  int get hashCode => period.hashCode ^ timeframe.hashCode;
}

class EquityPoint {
  final DateTime time;
  final double equity;
  final double profitLoss;
  final double profitLossPct;

  const EquityPoint({
    required this.time,
    required this.equity,
    required this.profitLoss,
    required this.profitLossPct,
  });
}

final portfolioHistoryProvider = FutureProvider.autoDispose
    .family<List<EquityPoint>, PortfolioHistoryParams>((ref, params) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 5), link.close);
  ref.onDispose(timer.cancel);
  final client = ref.read(alpacaClientProvider);
  final data = await client.getPortfolioHistory(
    period: params.period,
    timeframe: params.timeframe,
  );

  final timestamps = (data['timestamp'] as List?)?.cast<int>() ?? [];
  final equities = (data['equity'] as List?) ?? [];
  final pls = (data['profit_loss'] as List?) ?? [];
  final plPcts = (data['profit_loss_pct'] as List?) ?? [];

  final points = <EquityPoint>[];
  for (var i = 0; i < timestamps.length; i++) {
    final equity = (equities.length > i && equities[i] != null)
        ? (equities[i] as num).toDouble()
        : null;
    if (equity == null) continue;
    points.add(EquityPoint(
      time: DateTime.fromMillisecondsSinceEpoch(timestamps[i] * 1000),
      equity: equity,
      profitLoss: (pls.length > i && pls[i] != null)
          ? (pls[i] as num).toDouble()
          : 0,
      profitLossPct: (plPcts.length > i && plPcts[i] != null)
          ? (plPcts[i] as num).toDouble()
          : 0,
    ));
  }
  return points;
});
