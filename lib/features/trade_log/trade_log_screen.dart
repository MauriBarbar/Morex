import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/models/managed_position.dart';
import 'package:morex/core/models/position.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/engine/position_engine.dart';
import 'package:morex/providers/alpaca_providers.dart';
import 'package:morex/providers/position_engine_service_providers.dart';

class TradeLogScreen extends ConsumerStatefulWidget {
  const TradeLogScreen({super.key});

  @override
  ConsumerState<TradeLogScreen> createState() => _TradeLogScreenState();
}

class _TradeLogScreenState extends ConsumerState<TradeLogScreen> {
  bool _starting = false;
  StreamSubscription? _configErrorSub;
  StreamSubscription? _criticalAlertSub;
  StreamSubscription? _closeResultSub;

  @override
  void initState() {
    super.initState();
    final service = FlutterBackgroundService();

    // Listen for background service config errors (missing API keys, etc.)
    _configErrorSub = service.on('config_error').listen((event) {
      if (!mounted) return;
      final message = event?['message'] as String? ?? 'Unknown config error';
      setState(() => _starting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 5),
      ));
    });

    // Listen for critical alerts (unprotected positions, etc.)
    _criticalAlertSub = service.on('critical_alert').listen((event) {
      if (!mounted) return;
      final message = event?['message'] as String? ?? '';
      if (message.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 8),
      ));
    });

    // Listen for manual close position results
    _closeResultSub = service.on('pe_close_result').listen((event) {
      if (!mounted) return;
      final success = event?['success'] as bool? ?? false;
      final symbol = event?['symbol'] as String? ?? '';
      final error = event?['error'] as String?;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(success
            ? 'Closed $symbol'
            : 'Failed to close $symbol${error != null ? ': $error' : ''}'),
        backgroundColor: success ? Colors.green : Colors.red,
        duration: const Duration(seconds: 4),
      ));
    });
  }

  @override
  void dispose() {
    _configErrorSub?.cancel();
    _criticalAlertSub?.cancel();
    _closeResultSub?.cancel();
    super.dispose();
  }

  void _confirmClose(String symbol) {
    final controller = ref.read(positionEngineServiceProvider);
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Close $symbol?'),
        content: const Text(
          'This will submit a market sell order for the full position. '
          'The stop-loss order will be cancelled automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              controller.closePosition(symbol);
            },
            child: const Text('Close Position'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleEngine(
      PositionEngineServiceController controller, bool isRunning) async {
    if (isRunning) {
      controller.stop();
      return;
    }

    setState(() => _starting = true);
    try {
      await controller.start();
      // Give the background service time to report status
      await Future.delayed(const Duration(seconds: 2));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to start: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(portfolioAutoRefreshProvider); // refreshes live positions/PnL
    final controller = ref.watch(positionEngineServiceProvider);
    final statusAsync = ref.watch(positionEngineStatusProvider);
    final logs = ref.watch(positionEngineLogsProvider);
    final positions = ref.watch(positionEnginePositionsProvider);
    final livePositions = ref.watch(positionsProvider).valueOrNull ?? const [];

    final isRunning = statusAsync.valueOrNull?.isRunning ?? false;

    // Clear starting flag once status confirms running
    if (isRunning && _starting) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _starting = false);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Position Engine'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextButton.icon(
              onPressed: _starting
                  ? null
                  : () => _toggleEngine(controller, isRunning),
              icon: _starting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      isRunning ? Icons.stop : Icons.auto_mode,
                      color: isRunning ? Colors.red : Colors.green,
                      size: 18,
                    ),
              label: Text(
                _starting
                    ? 'Starting...'
                    : isRunning
                        ? 'Stop'
                        : 'Auto',
                style: TextStyle(
                  color: _starting
                      ? Colors.grey
                      : isRunning
                          ? Colors.red
                          : Colors.green,
                ),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => controller.runOnce(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusCard(statusAsync: statusAsync),
            const SizedBox(height: 16),
            _ManagedPositionsSection(
              positions: positions,
              livePositions: livePositions,
              onClosePosition: (symbol) => _confirmClose(symbol),
            ),
            const SizedBox(height: 16),
            Text('Trade History', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (logs.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No trades yet')),
                ),
              )
            else
              ...logs.reversed.take(50).map((log) => _TradeLogTile(log: log)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => controller.runOnce(),
        icon: const Icon(Icons.play_arrow),
        label: const Text('Run Now'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Status card
// ---------------------------------------------------------------------------

class _StatusCard extends StatelessWidget {
  final AsyncValue<EngineStatus> statusAsync;

  const _StatusCard({required this.statusAsync});

  @override
  Widget build(BuildContext context) {
    return statusAsync.when(
      data: (status) => _StatusContent(status: status),
      loading: () => const _StatusContent(status: EngineStatus()),
      error: (e, _) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Status error: $e'),
        ),
      ),
    );
  }
}

class _StatusContent extends StatelessWidget {
  final EngineStatus status;

  const _StatusContent({required this.status});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  status.isRunning ? Icons.circle : Icons.circle_outlined,
                  size: 12,
                  color: status.isRunning ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  status.isRunning ? 'Running — scans every 20 min' : 'Stopped',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (status.lastRun != null) ...[
              const SizedBox(height: 6),
              Text(
                'Last run: ${_formatAge(status.lastRun!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (status.lastError != null) ...[
              const SizedBox(height: 6),
              Text(
                status.lastError!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatAge(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

// ---------------------------------------------------------------------------
// Managed positions section
// ---------------------------------------------------------------------------

class _ManagedPositionsSection extends StatelessWidget {
  final List<ManagedPosition> positions;
  final List<Position> livePositions;
  final void Function(String symbol) onClosePosition;

  const _ManagedPositionsSection({
    required this.positions,
    required this.livePositions,
    required this.onClosePosition,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Managed Positions',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            if (positions.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${positions.length}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            const Spacer(),
            Tooltip(
              triggerMode: TooltipTriggerMode.tap,
              showDuration: const Duration(seconds: 6),
              message:
                  'Each position has a max hold window. Once held that long, '
                  'the engine force-closes it on the next re-eval cycle so '
                  'capital does not sit on stale theses. Configure in Settings.',
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline, size: 12, color: Colors.grey),
                  SizedBox(width: 4),
                  Text('Hold rule',
                      style: TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (positions.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: Text('No managed positions')),
            ),
          )
        else
          ...positions.map((p) {
            final live = livePositions
                .where((lp) => lp.symbol == p.symbol)
                .firstOrNull;
            return _ManagedPositionCard(
              position: p,
              live: live,
              onClose: () => onClosePosition(p.symbol),
            );
          }),
      ],
    );
  }
}

class _ManagedPositionCard extends StatelessWidget {
  final ManagedPosition position;
  final Position? live;
  final VoidCallback onClose;

  const _ManagedPositionCard({
    required this.position,
    required this.live,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final overdue = position.isOverdue;
    final holdMs = DateTime.now()
        .difference(position.entryTime)
        .inMilliseconds
        .clamp(0, 1 << 62);
    final maxHoldMs =
        Duration(days: position.exitRules.maxHoldDays).inMilliseconds;
    final holdFraction = (holdMs / maxHoldMs).clamp(0.0, 1.0);
    final holdColor = holdFraction > 0.8
        ? Colors.red
        : holdFraction > 0.5
            ? Colors.orange
            : Colors.green;

    final remaining = Duration(milliseconds: maxHoldMs - holdMs);
    final autoExitLabel = remaining.isNegative
        ? 'Auto-exit pending'
        : 'Auto-exit in ${_formatDurationCompact(remaining)}';

    final entry = position.entryPrice;
    final stop = position.currentStopPrice;
    final tpPrice = entry * (1 + position.exitRules.takeProfitPercent);
    final livePrice = live?.currentPrice;
    final pnlDollars = live?.unrealizedPnL;
    final pnlPercent = live?.unrealizedPnLPercent; // already a decimal fraction
    final pnlColor =
        (pnlDollars ?? 0) >= 0 ? Colors.green : Colors.red;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  position.symbol,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                if (position.source == 'manual')
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.withAlpha(30),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.withAlpha(80)),
                    ),
                    child: const Text(
                      'MANUAL',
                      style: TextStyle(fontSize: 10, color: Colors.blue),
                    ),
                  ),
                if (overdue)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red.withAlpha(30),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withAlpha(80)),
                    ),
                    child: const Text(
                      'OVERDUE',
                      style: TextStyle(fontSize: 10, color: Colors.red),
                    ),
                  ),
                const Spacer(),
                Text(
                  '${position.remainingQty.toStringAsFixed(position.remainingQty == position.remainingQty.truncate() ? 0 : 4)} sh',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 28,
                  child: OutlinedButton(
                    onPressed: onClose,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Close', style: TextStyle(fontSize: 11)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Live P&L row — primary value-at-stake, only when we have live data
            if (livePrice != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '\$${livePrice.toStringAsFixed(2)}',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 8),
                  if (pnlDollars != null && pnlPercent != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: pnlColor.withAlpha(25),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${pnlDollars >= 0 ? '+' : ''}\$${pnlDollars.toStringAsFixed(2)} '
                        '(${pnlDollars >= 0 ? '+' : ''}${(pnlPercent * 100).toStringAsFixed(2)}%)',
                        style: TextStyle(
                            color: pnlColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                _InfoItem(
                    label: 'Entry',
                    value: '\$${entry.toStringAsFixed(2)}'),
                const SizedBox(width: 16),
                if (stop != null)
                  _InfoItem(
                    label: 'Stop',
                    value: '\$${stop.toStringAsFixed(2)}',
                    sub: livePrice != null
                        ? _distanceLabel(livePrice, stop, isStop: true)
                        : null,
                  ),
                const SizedBox(width: 16),
                _InfoItem(
                  label: position.takeProfitTriggered ? 'TP done' : 'TP',
                  value: '\$${tpPrice.toStringAsFixed(2)}',
                  sub: livePrice != null && !position.takeProfitTriggered
                      ? _distanceLabel(livePrice, tpPrice, isStop: false)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.timer_outlined, size: 12, color: holdColor),
                const SizedBox(width: 4),
                Text(
                  'Held ${_formatHeldDuration(position.entryTime)}',
                  style: TextStyle(
                      fontSize: 11,
                      color: holdColor,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text(
                  '· $autoExitLabel',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
                if (position.takeProfitTriggered) ...[
                  const Spacer(),
                  const Icon(Icons.check_circle_outline,
                      size: 12, color: Colors.teal),
                  const SizedBox(width: 2),
                  const Text('TP triggered',
                      style: TextStyle(fontSize: 10, color: Colors.teal)),
                ],
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: holdFraction,
                backgroundColor: Colors.grey.shade800,
                color: holdColor,
                minHeight: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatHeldDuration(DateTime entryTime) {
  final d = DateTime.now().difference(entryTime);
  if (d.isNegative) return 'just now';
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) {
    final mins = d.inMinutes.remainder(60);
    return mins > 0 ? '${d.inHours}h ${mins}m' : '${d.inHours}h';
  }
  final hours = d.inHours.remainder(24);
  return hours > 0 ? '${d.inDays}d ${hours}h' : '${d.inDays}d';
}

String _formatDurationCompact(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) {
    final mins = d.inMinutes.remainder(60);
    return mins > 0 ? '${d.inHours}h ${mins}m' : '${d.inHours}h';
  }
  final hours = d.inHours.remainder(24);
  return hours > 0 ? '${d.inDays}d ${hours}h' : '${d.inDays}d';
}

String _distanceLabel(double current, double target, {required bool isStop}) {
  if (current <= 0 || target <= 0) return '';
  final delta = (current - target) / current;
  final pct = (delta * 100).abs().toStringAsFixed(1);
  if (isStop) {
    // Stop is below current — distance shows "Xpc% away"
    return '$pct% away';
  }
  // TP target — show how far still to go
  final toGo = ((target - current) / current * 100).abs().toStringAsFixed(1);
  return '$toGo% to go';
}

class _InfoItem extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;

  const _InfoItem({required this.label, required this.value, this.sub});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style:
                Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10)),
        Text(value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        if (sub != null && sub!.isNotEmpty)
          Text(sub!,
              style: const TextStyle(fontSize: 9, color: Colors.grey)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Trade log tile
// ---------------------------------------------------------------------------

class _TradeLogTile extends StatelessWidget {
  final TradeLog log;

  const _TradeLogTile({required this.log});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (log.action) {
      TradeAction.buy => (Icons.arrow_upward, Colors.green),
      TradeAction.takeProfitSell => (Icons.check, Colors.teal),
      TradeAction.trailingStopSell => (Icons.trending_down, Colors.orange),
      TradeAction.sell => (Icons.arrow_downward, Colors.red),
      TradeAction.timeExit => (Icons.timer_off, Colors.red),
      TradeAction.reEvalSell => (Icons.psychology, Colors.red),
      TradeAction.skip => (Icons.block, Colors.grey),
    };

    final priceStr = log.price != null
        ? ' @ \$${log.price!.toStringAsFixed(2)}'
        : '';
    final qtyStr = log.qty != null
        ? ' ${log.qty!.toStringAsFixed(log.qty! % 1 == 0 ? 0 : 4)}sh'
        : '';

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: color.withAlpha(30),
          child: Icon(icon, color: color, size: 16),
        ),
        title: Text(
          '${log.action.name.toUpperCase()} ${log.ticker}$qtyStr$priceStr',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        subtitle: log.reasoning.isNotEmpty
            ? Text(
                log.reasoning,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              )
            : null,
        trailing: Text(
          _formatTime(log.createdAt),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (now.difference(dt).inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }
}
