import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/models/position.dart';
import 'package:morex/engine/position_engine.dart';
import 'package:morex/providers/alpaca_providers.dart';
import 'package:morex/providers/market_data_providers.dart';
import 'package:morex/providers/position_engine_service_providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(portfolioAutoRefreshProvider); // auto-refresh every 30s
    final account = ref.watch(accountProvider);
    final positions = ref.watch(positionsProvider);
    final clock = ref.watch(marketClockProvider);
    final engineStatus = ref.watch(positionEngineStatusProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Morex'),
        actions: [
          // Market status pill
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: clock.when(
              data: (c) => _MarketPill(isOpen: c.isOpen),
              loading: () => const _MarketPill(isOpen: null),
              error: (_, _) => const _MarketPill(isOpen: null),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // Account hero
            account.when(
              data: (a) => _AccountHero(
                equity: a.equity,
                cash: a.cash,
                buyingPower: a.buyingPower,
                dailyPnL: a.dailyPnL,
                dailyPnLPercent: a.dailyPnLPercent,
              ),
              loading: () => const _LoadingCard(),
              error: (e, _) => _ErrorCard(message: e.toString()),
            ),
            const SizedBox(height: 12),

            // Equity chart
            const _EquityChartSection(),
            const SizedBox(height: 12),

            // Engine status summary
            _EngineSummary(statusAsync: engineStatus),
            const SizedBox(height: 16),

            // Positions
            Row(
              children: [
                Text('Positions',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                positions.whenOrNull(
                      data: (list) => Text(
                        '${list.length} held',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ) ??
                    const SizedBox.shrink(),
              ],
            ),
            const SizedBox(height: 8),
            positions.when(
              data: (list) => list.isEmpty
                  ? const _EmptyPositions()
                  : Column(
                      children: list
                          .map((p) => _PositionTile(position: p))
                          .toList(),
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

// ---------------------------------------------------------------------------
// Market status pill
// ---------------------------------------------------------------------------

class _MarketPill extends StatelessWidget {
  final bool? isOpen;

  const _MarketPill({required this.isOpen});

  @override
  Widget build(BuildContext context) {
    final color = isOpen == true
        ? Colors.green
        : isOpen == false
            ? Colors.grey
            : Colors.transparent;
    final label = isOpen == true
        ? 'Open'
        : isOpen == false
            ? 'Closed'
            : '';

    if (label.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Account hero card
// ---------------------------------------------------------------------------

class _AccountHero extends StatelessWidget {
  final double equity;
  final double cash;
  final double buyingPower;
  final double dailyPnL;
  final double dailyPnLPercent;

  const _AccountHero({
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
            Text('Portfolio Value',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              '\$${_formatCurrency(equity)}',
              style: Theme.of(context)
                  .textTheme
                  .headlineLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: pnlColor.withAlpha(25),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$pnlSign\$${dailyPnL.toStringAsFixed(2)} ($pnlSign${dailyPnLPercent.toStringAsFixed(2)}%) today',
                style: TextStyle(
                    color: pnlColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 13),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                      label: 'Cash', value: '\$${_formatCurrency(cash)}'),
                ),
                Expanded(
                  child: _MiniStat(
                      label: 'Buying Power',
                      value: '\$${_formatCurrency(buyingPower)}'),
                ),
                Expanded(
                  child: _MiniStat(
                    label: 'Invested',
                    value: '\$${_formatCurrency(equity - cash)}',
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

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;

  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Equity chart
// ---------------------------------------------------------------------------

class _EquityChartSection extends ConsumerStatefulWidget {
  const _EquityChartSection();

  @override
  ConsumerState<_EquityChartSection> createState() =>
      _EquityChartSectionState();
}

class _EquityChartSectionState extends ConsumerState<_EquityChartSection> {
  String _period = '1M';

  static const _periods = ['1W', '1M', '3M', '1A'];
  static const _periodTimeframes = {
    '1W': '15Min',
    '1M': '1D',
    '3M': '1D',
    '1A': '1D',
  };

  @override
  Widget build(BuildContext context) {
    final params = PortfolioHistoryParams(
      period: _period,
      timeframe: _periodTimeframes[_period] ?? '1D',
    );
    final historyAsync = ref.watch(portfolioHistoryProvider(params));

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Equity',
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                ..._periods.map((p) => Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: _PeriodChip(
                        label: p,
                        selected: p == _period,
                        onTap: () => setState(() => _period = p),
                      ),
                    )),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 140,
              child: historyAsync.when(
                data: (points) => points.length < 2
                    ? const Center(
                        child: Text('Not enough data',
                            style: TextStyle(color: Colors.grey, fontSize: 12)))
                    : _EquityLineChart(points: points),
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Text('Chart unavailable',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PeriodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? Theme.of(context).colorScheme.onPrimary : null,
          ),
        ),
      ),
    );
  }
}

class _EquityLineChart extends StatelessWidget {
  final List<EquityPoint> points;

  const _EquityLineChart({required this.points});

  @override
  Widget build(BuildContext context) {
    final equities = points.map((p) => p.equity).toList();
    final minY = equities.reduce(min);
    final maxY = equities.reduce(max);
    final pad = (maxY - minY) == 0 ? maxY * 0.01 : (maxY - minY) * 0.1;

    final isUp = points.last.equity >= points.first.equity;
    final lineColor = isUp ? Colors.green : Colors.red;

    final spots = <FlSpot>[];
    for (var i = 0; i < points.length; i++) {
      spots.add(FlSpot(i.toDouble(), points[i].equity));
    }

    return LineChart(
      LineChartData(
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        minY: minY - pad,
        maxY: maxY + pad,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((spot) {
              final pt = points[spot.spotIndex];
              return LineTooltipItem(
                '\$${pt.equity.toStringAsFixed(2)}',
                TextStyle(
                    color: lineColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12),
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            color: lineColor,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: lineColor.withAlpha(20),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Engine summary
// ---------------------------------------------------------------------------

class _EngineSummary extends StatelessWidget {
  final AsyncValue<EngineStatus> statusAsync;

  const _EngineSummary({required this.statusAsync});

  @override
  Widget build(BuildContext context) {
    final status = statusAsync.valueOrNull ?? const EngineStatus();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: status.isRunning ? Colors.green : Colors.grey,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status.isRunning
                        ? 'Position Engine active'
                        : 'Position Engine idle',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  if (status.lastRun != null)
                    Text(
                      'Last scan ${_formatAge(status.lastRun!)}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                ],
              ),
            ),
            if (status.lastError != null)
              Tooltip(
                message: status.lastError!,
                child: const Icon(Icons.warning_amber_rounded,
                    size: 16, color: Colors.orange),
              ),
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
// Position tile
// ---------------------------------------------------------------------------

class _PositionTile extends StatelessWidget {
  final Position position;

  const _PositionTile({required this.position});

  @override
  Widget build(BuildContext context) {
    final pnlColor = position.isProfit ? Colors.green : Colors.red;
    final pnlSign = position.isProfit ? '+' : '';
    final pnlPctStr =
        '$pnlSign${(position.unrealizedPnLPercent * 100).toStringAsFixed(2)}%';

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Symbol + shares
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(position.symbol,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  Text(
                    '${position.qty.toStringAsFixed(position.qty == position.qty.truncate() ? 0 : 4)} shares @ \$${position.avgEntryPrice.toStringAsFixed(2)}',
                    style:
                        const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
            // Market value + P&L
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('\$${_formatCurrency(position.marketValue)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$pnlSign\$${position.unrealizedPnL.toStringAsFixed(2)}',
                      style: TextStyle(
                          color: pnlColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: pnlColor.withAlpha(25),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(pnlPctStr,
                          style: TextStyle(
                              color: pnlColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _formatCurrency(double value) {
  if (value.abs() >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(2)}M';
  }
  if (value.abs() >= 10000) {
    return '${(value / 1000).toStringAsFixed(1)}K';
  }
  return value.toStringAsFixed(2);
}

class _EmptyPositions extends StatelessWidget {
  const _EmptyPositions();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.account_balance_wallet_outlined,
                  size: 32,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(60)),
              const SizedBox(height: 8),
              const Text('No positions yet'),
            ],
          ),
        ),
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
