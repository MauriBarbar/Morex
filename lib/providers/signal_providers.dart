import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/api/claude_client.dart';
import 'package:morex/core/api/news_client.dart';
import 'package:morex/core/logger.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/engine/sentiment_analyzer.dart';
import 'package:morex/providers/alpaca_providers.dart';
import 'package:morex/providers/position_engine_service_providers.dart';

final newsClientProvider = Provider<NewsClient>((ref) {
  return NewsClient(alpacaClient: ref.watch(alpacaClientProvider));
});

final claudeClientProvider = Provider<ClaudeClient>((ref) => ClaudeClient());

final sentimentAnalyzerProvider = Provider<SentimentAnalyzer>((ref) {
  return SentimentAnalyzer(
    newsClient: ref.watch(newsClientProvider),
    claudeClient: ref.watch(claudeClientProvider),
  );
});

final scanResultProvider = StateProvider<ScanResult?>((ref) => null);
final isScanningProvider = StateProvider<bool>((ref) => false);

/// Tracks tickers that were auto-executed recently so the next auto-scan does
/// not blindly re-fire the same trade. A new signal can override the cooldown
/// only if its conviction is meaningfully stronger than the prior execution
/// (higher confidence or reversed sentiment) — otherwise the duplicate is
/// suppressed and surfaced in UI as "cooldown".
class RecentExecution {
  final String ticker;
  final Sentiment sentiment;
  final double confidence;
  final DateTime executedAt;

  const RecentExecution({
    required this.ticker,
    required this.sentiment,
    required this.confidence,
    required this.executedAt,
  });
}

class RecentExecutionTracker extends StateNotifier<Map<String, RecentExecution>> {
  RecentExecutionTracker() : super({});

  /// How long after an auto-execute we suppress repeats of the same direction.
  static const cooldown = Duration(hours: 6);

  /// Required confidence improvement for a same-direction repeat to bypass cooldown.
  /// 0.10 == new signal must be at least 10 percentage points more confident.
  static const _minConfidenceLift = 0.10;

  void record(Signal signal) {
    state = {
      ...state,
      signal.ticker: RecentExecution(
        ticker: signal.ticker,
        sentiment: signal.sentiment,
        confidence: signal.confidence,
        executedAt: DateTime.now(),
      ),
    };
  }

  /// Decide whether [signal] can be auto-executed given recent activity.
  /// Returns null if eligible, or a human-readable skip reason otherwise.
  String? skipReason(Signal signal) {
    final last = state[signal.ticker];
    if (last == null) return null;
    final age = DateTime.now().difference(last.executedAt);
    if (age >= cooldown) return null;

    // Different direction — allow (could be a reversal signal).
    if (last.sentiment != signal.sentiment) return null;

    // Same direction within cooldown — only allow if conviction is meaningfully
    // higher than the prior execution.
    if (signal.confidence >= last.confidence + _minConfidenceLift) return null;

    final mins = age.inMinutes;
    final ago = mins < 60 ? '${mins}m' : '${(mins / 60).toStringAsFixed(1)}h';
    return 'Cooldown: ${signal.sentiment.name} ${signal.ticker} executed $ago ago '
        '(${(last.confidence * 100).toStringAsFixed(0)}% conf) — '
        'need >+${(_minConfidenceLift * 100).toStringAsFixed(0)}pp to retry';
  }

  void clearStale() {
    final cutoff = DateTime.now().subtract(cooldown);
    state = {
      for (final entry in state.entries)
        if (entry.value.executedAt.isAfter(cutoff)) entry.key: entry.value,
    };
  }
}

final recentExecutionTrackerProvider =
    StateNotifierProvider<RecentExecutionTracker, Map<String, RecentExecution>>(
  (ref) => RecentExecutionTracker(),
);

/// Drives a periodic 20-minute scan that runs even while the user is on other
/// tabs. Auto-executes high-conviction signals (>=75%) unless suppressed by
/// the [RecentExecutionTracker].
class SignalAutoScanController extends StateNotifier<SignalAutoScanState> {
  final Ref _ref;
  Timer? _timer;
  static const interval = Duration(minutes: 20);

  SignalAutoScanController(this._ref)
      : super(SignalAutoScanState(nextScanAt: DateTime.now().add(interval)));

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => scan());
    state = state.copyWith(nextScanAt: DateTime.now().add(interval));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Run a scan now and reset the periodic timer so the next auto-scan fires
  /// [interval] after this manual one.
  Future<void> scan({bool force = false}) async {
    if (_ref.read(isScanningProvider)) return;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => scan());

    _ref.read(isScanningProvider.notifier).state = true;
    final autoExecuted = <String>[];
    final cooldownSkipped = <String, String>{};
    try {
      final analyzer = _ref.read(sentimentAnalyzerProvider);
      final equity = _ref.read(accountProvider).valueOrNull?.equity;
      final result = await analyzer.scan(accountEquity: equity, force: force);
      _ref.read(scanResultProvider.notifier).state = result;

      final tracker = _ref.read(recentExecutionTrackerProvider.notifier);
      tracker.clearStale();
      final controller = _ref.read(positionEngineServiceProvider);
      for (final signal in result.signals) {
        if (signal.sentiment == Sentiment.neutral) continue;
        if (!signal.isAutoExecutable) continue;
        final skip = tracker.skipReason(signal);
        if (skip != null) {
          cooldownSkipped[signal.ticker] = skip;
          Log.i('SignalAutoScan', skip);
          continue;
        }
        controller.executeSignal(signal);
        tracker.record(signal);
        autoExecuted.add(signal.ticker);
      }
    } catch (e) {
      Log.e('SignalAutoScan', 'Auto-scan failed', e);
      state = state.copyWith(
        lastError: '$e',
        lastScanAt: DateTime.now(),
        nextScanAt: DateTime.now().add(interval),
      );
      _ref.read(isScanningProvider.notifier).state = false;
      return;
    }

    state = state.copyWith(
      lastScanAt: DateTime.now(),
      nextScanAt: DateTime.now().add(interval),
      lastAutoExecutedTickers: autoExecuted,
      lastCooldownSkipped: cooldownSkipped,
      lastError: null,
    );
    _ref.read(isScanningProvider.notifier).state = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class SignalAutoScanState {
  final DateTime? lastScanAt;
  final DateTime nextScanAt;
  final List<String> lastAutoExecutedTickers;
  final Map<String, String> lastCooldownSkipped;
  final String? lastError;

  const SignalAutoScanState({
    this.lastScanAt,
    required this.nextScanAt,
    this.lastAutoExecutedTickers = const [],
    this.lastCooldownSkipped = const {},
    this.lastError,
  });

  SignalAutoScanState copyWith({
    DateTime? lastScanAt,
    DateTime? nextScanAt,
    List<String>? lastAutoExecutedTickers,
    Map<String, String>? lastCooldownSkipped,
    Object? lastError = _sentinel,
  }) {
    return SignalAutoScanState(
      lastScanAt: lastScanAt ?? this.lastScanAt,
      nextScanAt: nextScanAt ?? this.nextScanAt,
      lastAutoExecutedTickers:
          lastAutoExecutedTickers ?? this.lastAutoExecutedTickers,
      lastCooldownSkipped: lastCooldownSkipped ?? this.lastCooldownSkipped,
      lastError: identical(lastError, _sentinel)
          ? this.lastError
          : lastError as String?,
    );
  }

  static const _sentinel = Object();
}

final signalAutoScanProvider = StateNotifierProvider<SignalAutoScanController,
    SignalAutoScanState>((ref) {
  final controller = SignalAutoScanController(ref);
  controller.start();
  return controller;
});
