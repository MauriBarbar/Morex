import 'dart:async';
import 'dart:collection';

/// An async semaphore (mutual exclusion lock) for account-level operations.
///
/// Prevents concurrent account checks + submissions from both engines, ensuring that
/// exposure limit checks are not stale by the time an order is submitted.
///
/// In Dart's single-threaded event loop model, this lock guarantees that only one
/// event can read account state and submit an order at a time.
class AccountLock {
  bool _locked = false;
  final Queue<Completer<void>> _waiters = Queue();

  /// Acquire the lock. Blocks if already locked until released.
  Future<void> acquire() async {
    if (!_locked) {
      _locked = true;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  /// Release the lock and wake the next waiter if any.
  void release() {
    if (!_locked) return;
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      next.complete();
    } else {
      _locked = false;
    }
  }
}
