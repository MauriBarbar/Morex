import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/engine/sentiment_analyzer.dart';
import 'package:morex/providers/position_engine_service_providers.dart';
import 'package:morex/providers/signal_providers.dart';

class SignalsScreen extends ConsumerStatefulWidget {
  const SignalsScreen({super.key});

  @override
  ConsumerState<SignalsScreen> createState() => _SignalsScreenState();
}

class _SignalsScreenState extends ConsumerState<SignalsScreen> {
  final Set<String> _manuallyExecutedTickers = {};
  Timer? _countdownTicker;

  @override
  void initState() {
    super.initState();
    // Drive a 1s rebuild so the "next scan in Xm Ys" countdown stays live.
    _countdownTicker =
        Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _countdownTicker?.cancel();
    super.dispose();
  }

  Future<void> _runManualScan() async {
    setState(() => _manuallyExecutedTickers.clear());
    try {
      await ref.read(signalAutoScanProvider.notifier).scan(force: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Scan failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 6),
        ));
      }
    }
  }

  void _onManualExecute(Signal signal) {
    setState(() => _manuallyExecutedTickers.add(signal.ticker));
    ref.read(recentExecutionTrackerProvider.notifier).record(signal);
  }

  @override
  Widget build(BuildContext context) {
    final scanResult = ref.watch(scanResultProvider);
    final isScanning = ref.watch(isScanningProvider);
    final autoScan = ref.watch(signalAutoScanProvider);

    final autoExecuted = autoScan.lastAutoExecutedTickers.toSet();
    final cooldownSkipped = autoScan.lastCooldownSkipped;

    // Listen for signal execution results and show snackbar feedback
    ref.listen(positionEngineSignalResultProvider, (_, next) {
      next.whenData((result) {
        final success = result['success'] as bool? ?? false;
        final ticker = result['ticker'] as String? ?? '';
        final error = result['error'] as String?;
        final msg = success
            ? 'Order submitted for $ticker'
            : 'Execute failed${error != null ? ': $error' : ''}';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor: success ? Colors.green : Colors.red,
          duration: const Duration(seconds: 3),
        ));
      });
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Signals'),
      ),
      body: Column(
        children: [
          _AutoScanBanner(state: autoScan, isScanning: isScanning),
          Expanded(
            child: scanResult == null
                ? _EmptyState(isScanning: isScanning)
                : _SignalsList(
                    result: scanResult,
                    autoExecutedTickers: autoExecuted,
                    manuallyExecutedTickers: _manuallyExecutedTickers,
                    cooldownSkipped: cooldownSkipped,
                    onExecute: _onManualExecute,
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: isScanning ? null : _runManualScan,
        icon: isScanning
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.radar),
        label: Text(isScanning ? 'Scanning...' : 'Scan Now'),
      ),
    );
  }
}

class _AutoScanBanner extends StatelessWidget {
  final SignalAutoScanState state;
  final bool isScanning;

  const _AutoScanBanner({required this.state, required this.isScanning});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final until = state.nextScanAt.difference(now);
    String countdown;
    if (isScanning) {
      countdown = 'Scanning…';
    } else if (until.isNegative) {
      countdown = 'Scan due — running soon';
    } else if (until.inMinutes >= 1) {
      countdown = 'Next scan in ${until.inMinutes}m ${until.inSeconds % 60}s';
    } else {
      countdown = 'Next scan in ${until.inSeconds}s';
    }

    final lastScan = state.lastScanAt;
    final lastScanLabel = lastScan == null
        ? 'No scan yet'
        : 'Last scan ${_formatAge(now.difference(lastScan))}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(Icons.autorenew,
                    size: 14, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text('Auto-scan every 20 min',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '• $lastScanLabel',
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            countdown,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _formatAge(Duration d) {
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

class _EmptyState extends StatelessWidget {
  final bool isScanning;

  const _EmptyState({required this.isScanning});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.radar,
            size: 64,
            color: Theme.of(context).colorScheme.onSurface.withAlpha(80),
          ),
          const SizedBox(height: 16),
          Text(
            isScanning ? 'Scanning news & analyzing...' : 'Waiting for first scan',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (!isScanning)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Auto-scan runs every 20 minutes. Tap "Scan Now" to scan immediately.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (isScanning)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

class _SignalsList extends StatelessWidget {
  final ScanResult result;
  final Set<String> autoExecutedTickers;
  final Set<String> manuallyExecutedTickers;
  final Map<String, String> cooldownSkipped;
  final void Function(Signal signal)? onExecute;

  const _SignalsList({
    required this.result,
    required this.autoExecutedTickers,
    required this.manuallyExecutedTickers,
    required this.cooldownSkipped,
    this.onExecute,
  });

  @override
  Widget build(BuildContext context) {
    final signals = result.signals;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ScanInfo(result: result),
        const SizedBox(height: 12),
        if (signals.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Icon(Icons.search_off, size: 32, color: Colors.grey),
                  const SizedBox(height: 8),
                  const Text(
                    'No actionable signals found',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    result.news.isEmpty
                        ? 'Could not fetch news — check your connection.'
                        : 'Claude analyzed ${result.news.length} articles and found no clear catalysts. '
                          'Try scanning again in a few minutes when more news is available.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          )
        else
          ...signals.map((s) => _SignalCard(
                signal: s,
                autoExecuted: autoExecutedTickers.contains(s.ticker),
                manuallyExecuted:
                    manuallyExecutedTickers.contains(s.ticker),
                cooldownReason: cooldownSkipped[s.ticker],
                onExecuted: onExecute != null ? () => onExecute!(s) : null,
              )),
      ],
    );
  }
}

class _ScanInfo extends StatelessWidget {
  final ScanResult result;

  const _ScanInfo({required this.result});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.article, size: 18),
                const SizedBox(width: 8),
                Text('${result.news.length} articles analyzed'),
                const Spacer(),
                Text(
                  '${result.signals.length} signal${result.signals.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (result.skippedDueToDedup) ...[
              const SizedBox(height: 6),
              const Text(
                'No new headlines since last scan — showing previous results.',
                style: TextStyle(fontSize: 11, color: Colors.orange),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SignalCard extends ConsumerWidget {
  final Signal signal;
  final bool autoExecuted;
  final bool manuallyExecuted;
  final String? cooldownReason;
  final VoidCallback? onExecuted;

  const _SignalCard({
    required this.signal,
    this.autoExecuted = false,
    this.manuallyExecuted = false,
    this.cooldownReason,
    this.onExecuted,
  });

  void _confirmExecute(BuildContext context, WidgetRef ref) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Execute ${signal.ticker}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${signal.sentiment.name.toUpperCase()} · '
              '${(signal.confidence * 100).toStringAsFixed(0)}% confidence',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(signal.reasoning),
            if (cooldownReason != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.withAlpha(60)),
                ),
                child: Text(
                  '$cooldownReason\n\nManual execution overrides the cooldown.',
                  style:
                      const TextStyle(fontSize: 12, color: Colors.amber),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withAlpha(20),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withAlpha(60)),
              ),
              child: const Text(
                'This will submit a real order through the Position Engine '
                'using your configured risk rules. The engine will manage '
                'stop-loss and take-profit automatically.',
                style: TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(positionEngineServiceProvider).executeSignal(signal);
              onExecuted?.call();
            },
            child: const Text('Execute'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sentimentColor = switch (signal.sentiment) {
      Sentiment.bullish => Colors.green,
      Sentiment.bearish => Colors.red,
      Sentiment.neutral => Colors.grey,
    };

    final sentimentIcon = switch (signal.sentiment) {
      Sentiment.bullish => Icons.trending_up,
      Sentiment.bearish => Icons.trending_down,
      Sentiment.neutral => Icons.trending_flat,
    };

    final confidencePercent = (signal.confidence * 100).toStringAsFixed(0);
    final canExecute = signal.sentiment != Sentiment.neutral && signal.isActionable;
    final executed = autoExecuted || manuallyExecuted;
    final inCooldown = cooldownReason != null && !executed;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  signal.ticker,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Icon(sentimentIcon, color: sentimentColor, size: 20),
                Text(
                  signal.sentiment.name.toUpperCase(),
                  style: TextStyle(
                    color: sentimentColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                _ConfidenceBadge(
                  confidence: signal.confidence,
                  label: '$confidencePercent%',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              signal.reasoning,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (inCooldown) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.snooze, size: 14, color: Colors.amber),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      cooldownReason!,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.amber),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    Chip(
                      label: Text(signal.timeframe.name),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    if (signal.isActionable)
                      Chip(
                        label: const Text('ACTIONABLE'),
                        backgroundColor: sentimentColor.withAlpha(40),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                const Spacer(),
                if (executed)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.teal.withAlpha(30),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.teal.withAlpha(80)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check, size: 12, color: Colors.teal),
                        const SizedBox(width: 4),
                        Text(
                            autoExecuted ? 'AUTO-EXECUTED' : 'EXECUTED',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.teal)),
                      ],
                    ),
                  )
                else if (canExecute)
                  FilledButton.tonal(
                    onPressed: () => _confirmExecute(context, ref),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: sentimentColor.withAlpha(40),
                      foregroundColor: sentimentColor,
                    ),
                    child: Text(
                      inCooldown ? 'Force Execute' : 'Execute',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfidenceBadge extends StatelessWidget {
  final double confidence;
  final String label;

  const _ConfidenceBadge({required this.confidence, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = confidence >= 0.75
        ? Colors.green
        : confidence >= 0.5
            ? Colors.orange
            : Colors.grey;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(100)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
    );
  }
}
