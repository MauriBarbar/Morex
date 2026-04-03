import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/models/signal.dart';
import 'package:morex/engine/sentiment_analyzer.dart';
import 'package:morex/providers/signal_providers.dart';

class SignalsScreen extends ConsumerWidget {
  const SignalsScreen({super.key});

  Future<void> _runScan(WidgetRef ref) async {
    ref.read(isScanningProvider.notifier).state = true;
    try {
      final analyzer = ref.read(sentimentAnalyzerProvider);
      final result = await analyzer.scan();
      ref.read(scanResultProvider.notifier).state = result;
    } finally {
      ref.read(isScanningProvider.notifier).state = false;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scanResult = ref.watch(scanResultProvider);
    final isScanning = ref.watch(isScanningProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Signals'),
      ),
      body: scanResult == null
          ? _EmptyState(isScanning: isScanning)
          : _SignalsList(result: scanResult),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: isScanning ? null : () => _runScan(ref),
        icon: isScanning
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.radar),
        label: Text(isScanning ? 'Scanning...' : 'Scan News'),
      ),
    );
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
            isScanning ? 'Scanning news & analyzing...' : 'No signals yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (!isScanning)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Tap "Scan News" to analyze market headlines',
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

  const _SignalsList({required this.result});

  @override
  Widget build(BuildContext context) {
    final signals = result.signals;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ScanInfo(result: result),
        const SizedBox(height: 12),
        if (signals.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No signals from this scan')),
            ),
          )
        else
          ...signals.map((s) => _SignalCard(signal: s)),
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
        child: Row(
          children: [
            const Icon(Icons.article, size: 18),
            const SizedBox(width: 8),
            Text('${result.news.length} articles analyzed'),
            const Spacer(),
            Text(
              '${result.signals.length} signals',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignalCard extends StatelessWidget {
  final Signal signal;

  const _SignalCard({required this.signal});

  @override
  Widget build(BuildContext context) {
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
            const SizedBox(height: 8),
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
