/// Coordinates symbol-level trading locks between multiple engines
/// to prevent simultaneous order placement on the same symbol.
class TradingLock {
  final Set<String> _active = {};

  /// Try to acquire a lock on a symbol.
  /// Returns true if acquired, false if already locked by another engine.
  bool tryAcquire(String symbol) {
    if (_active.contains(symbol)) {
      return false;
    }
    _active.add(symbol);
    return true;
  }

  /// Release a lock on a symbol.
  void release(String symbol) {
    _active.remove(symbol);
  }

  /// Get the set of currently locked symbols (for debugging/monitoring).
  Set<String> get activeSymbols => Set.unmodifiable(_active);
}
