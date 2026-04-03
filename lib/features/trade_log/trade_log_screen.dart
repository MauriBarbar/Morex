import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/engine/trading_engine.dart';
import 'package:morex/providers/engine_providers.dart';

class TradeLogScreen extends ConsumerWidget {
  const TradeLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(tradingEngineProvider);
    final statusAsync = ref.watch(engineStatusProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trade Log'),
        actions: [
          statusAsync.when(
            data: (status) => _EngineToggle(
              isRunning: status.isRunning,
              onToggle: () {
                if (status.isRunning) {
                  engine.stop();
                } else {
                  engine.start();
                }
              },
            ),
            loading: () => _EngineToggle(isRunning: false, onToggle: () => engine.start()),
            error: (_, _) => _EngineToggle(isRunning: false, onToggle: () => engine.start()),
          ),
        ],
      ),
      body: statusAsync.when(
        data: (status) => _TradeLogBody(engine: engine, status: status),
        loading: () => _TradeLogBody(engine: engine, status: engine.status),
        error: (_, _) => _TradeLogBody(engine: engine, status: engine.status),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => engine.runCycle(),
        icon: const Icon(Icons.play_arrow),
        label: const Text('Run Once'),
      ),
    );
  }
}

class _EngineToggle extends StatelessWidget {
  final bool isRunning;
  final VoidCallback onToggle;

  const _EngineToggle({required this.isRunning, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TextButton.icon(
        onPressed: onToggle,
        icon: Icon(
          isRunning ? Icons.stop : Icons.auto_mode,
          color: isRunning ? Colors.red : Colors.green,
        ),
        label: Text(
          isRunning ? 'Stop' : 'Auto',
          style: TextStyle(color: isRunning ? Colors.red : Colors.green),
        ),
      ),
    );
  }
}

class _TradeLogBody extends StatelessWidget {
  final TradingEngine engine;
  final EngineStatus status;

  const _TradeLogBody({required this.engine, required this.status});

  @override
  Widget build(BuildContext context) {
    final logs = engine.tradeLogs.reversed.toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StatusCard(status: status),
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
          ...logs.map((log) => _TradeLogTile(log: log)),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  final EngineStatus status;

  const _StatusCard({required this.status});

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
                  status.isRunning ? 'Engine running (every 4h)' : 'Engine stopped',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (status.lastRun != null) ...[
              const SizedBox(height: 8),
              Text(
                'Last run: ${_formatTime(status.lastRun!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (status.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                'Error: ${status.lastError}',
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _TradeLogTile extends StatelessWidget {
  final TradeLog log;

  const _TradeLogTile({required this.log});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (log.action) {
      TradeAction.buy => (Icons.arrow_upward, Colors.green),
      TradeAction.sell => (Icons.arrow_downward, Colors.red),
      TradeAction.skip => (Icons.block, Colors.grey),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withAlpha(30),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text(
          '${log.action.name.toUpperCase()} ${log.ticker}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          log.reasoning,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          '${log.createdAt.hour.toString().padLeft(2, '0')}:${log.createdAt.minute.toString().padLeft(2, '0')}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
