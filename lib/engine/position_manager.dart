import 'package:morex/core/models/managed_position.dart';
import 'package:morex/db/hive_store.dart';

class PositionManager {
  final HiveStore _store;
  final Map<String, ManagedPosition> _positions = {};

  PositionManager({required HiveStore store}) : _store = store {
    for (final pos in _store.getManagedPositions()) {
      _positions[pos.symbol] = pos;
    }
  }

  List<ManagedPosition> get all => List.unmodifiable(_positions.values.toList());

  ManagedPosition? getBySymbol(String symbol) => _positions[symbol];

  bool isManaged(String symbol) => _positions.containsKey(symbol);

  Future<void> registerBuy({
    required String symbol,
    required String orderId,
    required double entryPrice,
    required double qty,
    ExitRules exitRules = const ExitRules(),
  }) async {
    // Allow re-registration if the existing entry is for a different order
    // (e.g. a stale position entry from a previous trade). Silently drop only
    // if this exact orderId is already tracked.
    final existing = _positions[symbol];
    if (existing != null && existing.buyOrderId == orderId) return;
    final pos = ManagedPosition(
      symbol: symbol,
      buyOrderId: orderId,
      entryPrice: entryPrice,
      originalQty: qty,
      remainingQty: qty,
      entryTime: DateTime.now(),
      exitRules: exitRules,
    );
    _positions[symbol] = pos;
    await _store.saveManagedPosition(pos);
  }

  Future<void> update(ManagedPosition pos) async {
    _positions[pos.symbol] = pos;
    await _store.saveManagedPosition(pos);
  }

  Future<void> recordPartialSell(String symbol, double qtySold) async {
    final pos = _positions[symbol];
    if (pos == null) return;
    final updated = pos.copyWith(
      remainingQty: pos.remainingQty - qtySold,
      takeProfitTriggered: true,
    );
    await update(updated);
  }

  Future<void> recordFullClose(String symbol) async {
    _positions.remove(symbol);
    await _store.removeManagedPosition(symbol);
  }

  Future<void> updateStopLoss(
    String symbol, {
    required String orderId,
    required double stopPrice,
  }) async {
    final pos = _positions[symbol];
    if (pos == null) return;
    await update(pos.copyWith(
      stopLossOrderId: orderId,
      currentStopPrice: stopPrice,
    ));
  }

  Future<void> markReEvaluated(String symbol) async {
    final pos = _positions[symbol];
    if (pos == null) return;
    await update(pos.copyWith(lastReEvaluation: DateTime.now()));
  }

  List<ManagedPosition> getOverdue() =>
      all.where((p) => p.isOverdue).toList();

  List<ManagedPosition> getNeedingReEvaluation(Duration minInterval) {
    final now = DateTime.now();
    return all.where((p) {
      if (p.lastReEvaluation == null) return true;
      return now.difference(p.lastReEvaluation!) >= minInterval;
    }).toList();
  }
}
