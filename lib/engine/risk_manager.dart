import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/models/account.dart';
import 'package:morex/core/models/position.dart';
import 'package:morex/core/models/signal.dart';

class RiskConfig {
  final double maxPositionPercent;
  final double maxTotalExposurePercent;
  final double stopLossPercent;
  final double minConfidence;
  final double dailyLossLimitPercent;
  final double maxOrderDollars;

  const RiskConfig({
    this.maxPositionPercent = 0.05,
    this.maxTotalExposurePercent = 0.60,
    this.stopLossPercent = 0.08,
    this.minConfidence = 0.75,
    this.dailyLossLimitPercent = 0.02,
    this.maxOrderDollars = 500,
  });
}

class RiskCheck {
  final Signal signal;
  final bool approved;
  final String reason;

  const RiskCheck({
    required this.signal,
    required this.approved,
    required this.reason,
  });
}

class RiskManager {
  final AlpacaClient _client;
  final RiskConfig config;

  RiskManager({required AlpacaClient client, this.config = const RiskConfig()})
      : _client = client;

  Future<List<RiskCheck>> evaluate(List<Signal> signals) async {
    final account = await _client.getAccount();
    final positions = await _client.getPositions();
    final results = <RiskCheck>[];

    for (final signal in signals) {
      results.add(_evaluateSignal(signal, account, positions));
    }

    return results;
  }

  RiskCheck _evaluateSignal(
    Signal signal,
    Account account,
    List<Position> positions,
  ) {
    // Only act on bullish signals for buying
    if (signal.sentiment != Sentiment.bullish) {
      // Check if we hold this stock and signal is bearish -> sell candidate
      if (signal.sentiment == Sentiment.bearish) {
        final held = positions.any((p) => p.symbol == signal.ticker);
        if (!held) {
          return RiskCheck(
            signal: signal,
            approved: false,
            reason: 'Bearish but no position to sell',
          );
        }
        return RiskCheck(
          signal: signal,
          approved: true,
          reason: 'Bearish signal on held position — sell candidate',
        );
      }
      return RiskCheck(
        signal: signal,
        approved: false,
        reason: 'Neutral sentiment — no action',
      );
    }

    // Confidence check
    if (signal.confidence < config.minConfidence) {
      return RiskCheck(
        signal: signal,
        approved: false,
        reason:
            'Confidence ${(signal.confidence * 100).toStringAsFixed(0)}% below threshold ${(config.minConfidence * 100).toStringAsFixed(0)}%',
      );
    }

    // Daily loss kill switch
    if (account.dailyPnLPercent < -config.dailyLossLimitPercent * 100) {
      return RiskCheck(
        signal: signal,
        approved: false,
        reason:
            'Daily loss ${account.dailyPnLPercent.toStringAsFixed(2)}% exceeds limit',
      );
    }

    // Already holding this stock?
    final existingPosition = positions.where((p) => p.symbol == signal.ticker);
    if (existingPosition.isNotEmpty) {
      final posValue = existingPosition.first.marketValue;
      final posPercent = posValue / account.equity;
      if (posPercent >= config.maxPositionPercent) {
        return RiskCheck(
          signal: signal,
          approved: false,
          reason:
              '${signal.ticker} already at ${(posPercent * 100).toStringAsFixed(1)}% of portfolio',
        );
      }
    }

    // Total exposure check
    final totalInvested = positions.fold<double>(
      0,
      (sum, p) => sum + p.marketValue.abs(),
    );
    final exposurePercent = totalInvested / account.equity;
    if (exposurePercent >= config.maxTotalExposurePercent) {
      return RiskCheck(
        signal: signal,
        approved: false,
        reason:
            'Total exposure ${(exposurePercent * 100).toStringAsFixed(1)}% exceeds limit',
      );
    }

    // Buying power check
    final orderAmount = _calculateOrderAmount(account);
    if (orderAmount > account.buyingPower) {
      return RiskCheck(
        signal: signal,
        approved: false,
        reason: 'Insufficient buying power',
      );
    }

    return RiskCheck(
      signal: signal,
      approved: true,
      reason:
          'All checks passed — order up to \$${orderAmount.toStringAsFixed(2)}',
    );
  }

  double calculateOrderAmount(Account account) => _calculateOrderAmount(account);

  double _calculateOrderAmount(Account account) {
    final maxByPosition = account.equity * config.maxPositionPercent;
    return maxByPosition.clamp(0, config.maxOrderDollars);
  }
}
