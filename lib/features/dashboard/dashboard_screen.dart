import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/providers/alpaca_providers.dart';
import 'package:morex/core/models/position.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final positions = ref.watch(positionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Morex'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(accountProvider);
              ref.invalidate(positionsProvider);
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(accountProvider);
          ref.invalidate(positionsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            account.when(
              data: (a) => _AccountCard(
                equity: a.equity,
                cash: a.cash,
                buyingPower: a.buyingPower,
                dailyPnL: a.dailyPnL,
                dailyPnLPercent: a.dailyPnLPercent,
              ),
              loading: () => const _LoadingCard(),
              error: (e, _) => _ErrorCard(message: e.toString()),
            ),
            const SizedBox(height: 16),
            Text(
              'Positions',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            positions.when(
              data: (list) => list.isEmpty
                  ? const _EmptyPositions()
                  : Column(
                      children:
                          list.map((p) => _PositionTile(position: p)).toList(),
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _ErrorCard(message: e.toString()),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final double equity;
  final double cash;
  final double buyingPower;
  final double dailyPnL;
  final double dailyPnLPercent;

  const _AccountCard({
    required this.equity,
    required this.cash,
    required this.buyingPower,
    required this.dailyPnL,
    required this.dailyPnLPercent,
  });

  @override
  Widget build(BuildContext context) {
    final pnlColor = dailyPnL >= 0 ? Colors.green : Colors.red;
    final pnlSign = dailyPnL >= 0 ? '+' : '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Portfolio Value',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '\$${equity.toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              '$pnlSign\$${dailyPnL.toStringAsFixed(2)} ($pnlSign${dailyPnLPercent.toStringAsFixed(2)}%) today',
              style: TextStyle(color: pnlColor, fontWeight: FontWeight.w500),
            ),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StatItem(label: 'Cash', value: '\$${cash.toStringAsFixed(2)}'),
                _StatItem(
                    label: 'Buying Power',
                    value: '\$${buyingPower.toStringAsFixed(2)}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;

  const _StatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}

class _PositionTile extends StatelessWidget {
  final Position position;

  const _PositionTile({required this.position});

  @override
  Widget build(BuildContext context) {
    final pnlColor = position.isProfit ? Colors.green : Colors.red;
    final pnlSign = position.isProfit ? '+' : '';

    return Card(
      child: ListTile(
        title: Text(
          position.symbol,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${position.qty} shares @ \$${position.avgEntryPrice.toStringAsFixed(2)}',
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('\$${position.marketValue.toStringAsFixed(2)}'),
            Text(
              '$pnlSign\$${position.unrealizedPnL.toStringAsFixed(2)}',
              style: TextStyle(color: pnlColor, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPositions extends StatelessWidget {
  const _EmptyPositions();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No positions yet')),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;

  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message),
      ),
    );
  }
}
