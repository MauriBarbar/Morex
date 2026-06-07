import 'package:morex/core/api/alpaca_client.dart';
import 'package:morex/core/logger.dart';
import 'package:morex/core/models/account.dart';
import 'package:morex/core/models/asset_info.dart';
import 'package:morex/core/models/market_snapshot.dart';
import 'package:morex/core/models/position.dart';
import 'package:morex/core/models/signal.dart';

class RiskConfig {
  final double maxPositionPercent;
  final double maxTotalExposurePercent;
  final double stopLossPercent;
  final double minConfidence;
  final double dailyLossLimitPercent;
  final double maxOrderDollars;
  final double takeProfitPercent;
  final double takeProfitSellFraction;
  final bool trailingStopEnabled;
  final double trailingStopPercent;
  final int maxHoldDays;
  final double reEvalSellConfidence;

  // -- Pattern Day Trader guard --
  // FINRA: <$25K accounts may make at most 3 day-trades in any rolling
  // 5-business-day window before being flagged as PDT.
  final bool enablePdtGuard;
  final double pdtEquityThreshold;
  final int pdtMaxDayTrades;

  // -- Spread guard --
  // Skip entries when the bid/ask spread is too wide — eats P&L on
  // market-order entries and exits.
  final bool enableSpreadGuard;
  final double maxSpreadPercent;

  // -- Tradable / halt guard --
  // Skip entries on assets that are inactive, untradable, or halted.
  final bool enableTradableCheck;

  // -- Sector concentration cap --
  // Limits correlation risk when news drives multiple names in the same
  // sector. Off by default — only meaningful when symbols are in the
  // built-in sector map (mega-caps + popular ETFs).
  final bool enableSectorCap;
  final int maxPerSector;

  // -- Liquid-universe whitelist --
  // Restricts entries to a curated set of liquid mega-caps and popular ETFs
  // — small caps have wider spreads, thinner volume, and nasty slippage on
  // market orders, all of which silently bleed P&L on a fast-trading engine.
  final bool enableLiquidUniverseOnly;

  const RiskConfig({
    this.maxPositionPercent = 0.10,
    this.maxTotalExposurePercent = 0.80,
    this.stopLossPercent = 0.08,
    this.minConfidence = 0.60,
    this.dailyLossLimitPercent = 0.03,
    this.maxOrderDollars = 1000,
    this.takeProfitPercent = 0.15,
    this.takeProfitSellFraction = 0.5,
    this.trailingStopEnabled = true,
    this.trailingStopPercent = 0.05,
    this.maxHoldDays = 14,
    this.reEvalSellConfidence = 0.65,
    this.enablePdtGuard = true,
    this.pdtEquityThreshold = 25000,
    this.pdtMaxDayTrades = 3,
    this.enableSpreadGuard = true,
    this.maxSpreadPercent = 0.003,
    this.enableTradableCheck = true,
    this.enableSectorCap = false,
    this.maxPerSector = 1,
    this.enableLiquidUniverseOnly = true,
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

  // Cached asset info (tradable + fractionable). TTL 1h — Alpaca's asset
  // status changes infrequently, and a stale "tradable=true" failing at
  // order time is a recoverable error (Alpaca rejects).
  static const _assetCacheTtl = Duration(hours: 1);
  final Map<String, _CachedAsset> _assetCache = {};

  RiskManager({required AlpacaClient client, this.config = const RiskConfig()})
      : _client = client;

  Future<List<RiskCheck>> evaluate(List<Signal> signals) async {
    final account = await _client.getAccount();
    final positions = await _client.getPositions();
    final openOrders = await _client.getOrders(status: 'open');

    // Sum notional value of pending buy orders so they count against exposure.
    // Without this, two concurrent signal approvals can each pass the exposure
    // check individually but together exceed the limit once both orders fill.
    final pendingBuyValue = openOrders
        .where((o) =>
            o['side'] == 'buy' &&
            isPendingOrderStatus(o['status'] as String? ?? ''))
        .fold<double>(0, (sum, o) {
      final notional = double.tryParse(o['notional']?.toString() ?? '');
      return sum + (notional ?? 0);
    });

    // Subtract notional of pending sell orders from exposure — a position in the
    // process of being sold should not block a new buy on a different symbol.
    final pendingSellValue = openOrders
        .where((o) =>
            o['side'] == 'sell' &&
            isPendingOrderStatus(o['status'] as String? ?? ''))
        .fold<double>(0, (sum, o) {
      final symbol = o['symbol'] as String? ?? '';
      final orderQty = double.tryParse(o['qty']?.toString() ?? '') ?? 0;
      final pos = positions.where((p) => p.symbol == symbol).firstOrNull;
      if (pos == null || orderQty <= 0 || pos.qty <= 0) return sum;
      final fraction = (orderQty / pos.qty).clamp(0.0, 1.0);
      return sum + pos.marketValue.abs() * fraction;
    });

    // Pre-fetch snapshots and asset infos for symbols we'll actually evaluate
    // for entry. Sells (bearish on held position) don't need either.
    final entryCandidates = signals
        .where((s) => s.sentiment == Sentiment.bullish)
        .map((s) => s.ticker)
        .toSet();

    final snapshots = await _safeGetSnapshots(entryCandidates);
    final assets = await _resolveAssets(entryCandidates);

    // Sector occupancy from existing positions (used by sector cap).
    final sectorOccupancy = <String, int>{};
    for (final p in positions) {
      final sector = _sectorFor(p.symbol);
      if (sector != null) {
        sectorOccupancy[sector] = (sectorOccupancy[sector] ?? 0) + 1;
      }
    }

    final results = <RiskCheck>[];
    for (final signal in signals) {
      final check = _evaluateSignal(
        signal,
        account,
        positions,
        pendingBuyValue,
        pendingSellValue,
        snapshots[signal.ticker],
        assets[signal.ticker],
        sectorOccupancy,
      );
      // If approved and it's an entry, reserve the sector slot so subsequent
      // signals in the same scan respect the cap.
      if (check.approved && signal.sentiment == Sentiment.bullish) {
        final sector = _sectorFor(signal.ticker);
        if (sector != null) {
          sectorOccupancy[sector] = (sectorOccupancy[sector] ?? 0) + 1;
        }
      }
      results.add(check);
    }
    return results;
  }

  static bool isPendingOrderStatus(String status) {
    const pending = {'new', 'pending_new', 'accepted', 'held', 'partially_filled'};
    return pending.contains(status.toLowerCase());
  }

  RiskCheck _evaluateSignal(
    Signal signal,
    Account account,
    List<Position> positions,
    double pendingBuyValue,
    double pendingSellValue,
    MarketSnapshot? snapshot,
    AssetInfo? asset,
    Map<String, int> sectorOccupancy,
  ) {
    // Sells are evaluated first — they should not be blocked by entry-side
    // guards (PDT, spread, tradable, sector). A position you can't exit is
    // worse than one you can't open.
    if (signal.sentiment != Sentiment.bullish) {
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

    // -------- Entry-side checks (bullish only) --------

    // Liquid-universe gate. Outside this set, expect wide spreads and
    // slippage that silently consume the strategy's expectancy.
    if (config.enableLiquidUniverseOnly &&
        !_liquidUniverse.contains(signal.ticker.toUpperCase())) {
      return RiskCheck(
        signal: signal,
        approved: false,
        reason:
            '${signal.ticker} not in liquid universe (mega-caps + popular ETFs only)',
      );
    }

    // Tradable / halt check.
    if (config.enableTradableCheck && asset != null && !asset.isActive) {
      return RiskCheck(
        signal: signal,
        approved: false,
        reason:
            '${signal.ticker} not tradable (status=${asset.status}, tradable=${asset.tradable})',
      );
    }

    // Fractionable check (replaces the old hardcoded blacklist — Alpaca's
    // own `fractionable` flag is authoritative).
    if (asset != null && !asset.fractionable) {
      return RiskCheck(
        signal: signal,
        approved: false,
        reason: '${signal.ticker} does not support fractional trading',
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

    // Guard against zero equity
    if (account.equity <= 0) {
      return RiskCheck(signal: signal, approved: false, reason: 'Account equity is zero or negative');
    }

    // PDT guard — block new buys when account would breach the day-trade
    // count limit. Already-flagged PDT accounts under threshold are blocked
    // outright; otherwise count-based check.
    if (config.enablePdtGuard && account.equity < config.pdtEquityThreshold) {
      if (account.patternDayTrader) {
        return RiskCheck(
          signal: signal,
          approved: false,
          reason:
              'PDT-flagged account under \$${config.pdtEquityThreshold.toStringAsFixed(0)} '
              'equity — new entries blocked',
        );
      }
      if (account.daytradeCount >= config.pdtMaxDayTrades) {
        return RiskCheck(
          signal: signal,
          approved: false,
          reason:
              'PDT guard: ${account.daytradeCount} day-trades in 5d window '
              '(limit ${config.pdtMaxDayTrades}) at \$${account.equity.toStringAsFixed(0)} equity',
        );
      }
    }

    // Daily loss kill switch.
    // account.dailyPnLPercent is a percentage value (e.g. -3.5 means -3.5%).
    // config.dailyLossLimitPercent is a decimal fraction (e.g. 0.03 = 3%).
    // Multiply by 100 to compare on the same scale.
    if (account.dailyPnLPercent < -config.dailyLossLimitPercent * 100) {
      return RiskCheck(
        signal: signal,
        approved: false,
        reason: 'Daily loss ${account.dailyPnLPercent.toStringAsFixed(2)}% exceeds limit',
      );
    }

    // Spread guard — wide spreads silently eat P&L on market orders.
    if (config.enableSpreadGuard && snapshot != null) {
      final spread = snapshot.spreadPercent;
      if (spread != null && spread > config.maxSpreadPercent) {
        return RiskCheck(
          signal: signal,
          approved: false,
          reason:
              'Spread ${(spread * 100).toStringAsFixed(2)}% exceeds limit ${(config.maxSpreadPercent * 100).toStringAsFixed(2)}%',
        );
      }
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
          reason: '${signal.ticker} already at ${(posPercent * 100).toStringAsFixed(1)}% of portfolio',
        );
      }
    }

    // Sector concentration cap.
    if (config.enableSectorCap) {
      final sector = _sectorFor(signal.ticker);
      if (sector != null) {
        final occupancy = sectorOccupancy[sector] ?? 0;
        // Don't double-count the same symbol if it's already a position.
        final alreadyHeldInSector = positions.any(
          (p) => p.symbol == signal.ticker && _sectorFor(p.symbol) == sector,
        );
        final effective = alreadyHeldInSector ? occupancy - 1 : occupancy;
        if (effective >= config.maxPerSector) {
          return RiskCheck(
            signal: signal,
            approved: false,
            reason:
                'Sector $sector already at $effective position(s) — limit ${config.maxPerSector}',
          );
        }
      }
    }

    // Total exposure check — includes filled positions and pending buys, minus
    // any positions currently being sold (their capital is already committed to exit).
    final filledExposure = positions.fold<double>(0, (sum, p) => sum + p.marketValue.abs());
    final totalInvested = (filledExposure - pendingSellValue).clamp(0.0, double.infinity) + pendingBuyValue;
    final exposurePercent = totalInvested / account.equity;
    if (exposurePercent >= config.maxTotalExposurePercent) {
      return RiskCheck(
        signal: signal,
        approved: false,
        reason: 'Total exposure ${(exposurePercent * 100).toStringAsFixed(1)}% exceeds limit'
            '${pendingBuyValue > 0 ? ' (includes \$${pendingBuyValue.toStringAsFixed(0)} pending)' : ''}',
      );
    }

    // Buying power check
    final orderAmount = _calculateOrderAmount(account);
    if (orderAmount > account.buyingPower) {
      return RiskCheck(signal: signal, approved: false, reason: 'Insufficient buying power');
    }

    return RiskCheck(
      signal: signal,
      approved: true,
      reason: 'All checks passed — order up to \$${orderAmount.toStringAsFixed(2)}',
    );
  }

  double calculateOrderAmount(Account account) => _calculateOrderAmount(account);

  double _calculateOrderAmount(Account account) {
    final maxByPosition = account.equity * config.maxPositionPercent;
    return maxByPosition.clamp(0, config.maxOrderDollars);
  }

  // ---------------------------------------------------------------------------
  // Asset / snapshot helpers
  // ---------------------------------------------------------------------------

  /// Best-effort snapshot fetch — failures degrade to no spread guard rather
  /// than blocking all entries.
  Future<Map<String, MarketSnapshot>> _safeGetSnapshots(
      Set<String> symbols) async {
    if (symbols.isEmpty) return const {};
    if (!config.enableSpreadGuard) return const {};
    try {
      return await _client.getSnapshots(symbols.toList());
    } catch (e) {
      Log.w('RiskManager', 'Snapshot fetch failed; spread guard disabled this scan: $e');
      return const {};
    }
  }

  /// Resolve asset infos with TTL caching. Failures degrade to no tradable
  /// check rather than blocking entries.
  Future<Map<String, AssetInfo>> _resolveAssets(Set<String> symbols) async {
    if (symbols.isEmpty) return const {};
    if (!config.enableTradableCheck) return const {};
    final result = <String, AssetInfo>{};
    final now = DateTime.now();
    final toFetch = <String>[];
    for (final sym in symbols) {
      final cached = _assetCache[sym];
      if (cached != null && now.difference(cached.fetchedAt) < _assetCacheTtl) {
        result[sym] = cached.asset;
      } else {
        toFetch.add(sym);
      }
    }
    if (toFetch.isEmpty) return result;
    final futures = toFetch.map((sym) async {
      try {
        final asset = await _client.getAsset(sym);
        _assetCache[sym] = _CachedAsset(asset: asset, fetchedAt: now);
        result[sym] = asset;
      } catch (e) {
        Log.w('RiskManager', 'getAsset($sym) failed; tradable check skipped: $e');
      }
    });
    await Future.wait(futures);
    return result;
  }

  // ---------------------------------------------------------------------------
  // Sector mapping
  //
  // Curated for the universe most likely to dominate news-driven scans
  // (mega-caps + popular ETFs). Symbols not in the map return null and are
  // treated as "uncategorised" (no sector cap applied).
  // ---------------------------------------------------------------------------

  static const _sectorMap = <String, String>{
    // Mega-cap tech
    'AAPL': 'Tech', 'MSFT': 'Tech', 'GOOGL': 'Tech', 'GOOG': 'Tech',
    'META': 'Tech', 'AMZN': 'Tech', 'NFLX': 'Tech', 'ORCL': 'Tech',
    'CRM': 'Tech', 'ADBE': 'Tech', 'IBM': 'Tech',
    // Semiconductors
    'NVDA': 'Semis', 'AMD': 'Semis', 'INTC': 'Semis', 'TSM': 'Semis',
    'AVGO': 'Semis', 'QCOM': 'Semis', 'MU': 'Semis', 'AMAT': 'Semis',
    'ASML': 'Semis', 'SMCI': 'Semis',
    // EV / auto
    'TSLA': 'Auto', 'F': 'Auto', 'GM': 'Auto', 'RIVN': 'Auto',
    'LCID': 'Auto', 'NIO': 'Auto',
    // Banks / finance
    'JPM': 'Banks', 'BAC': 'Banks', 'WFC': 'Banks', 'GS': 'Banks',
    'MS': 'Banks', 'C': 'Banks', 'SCHW': 'Banks',
    // Healthcare / pharma
    'JNJ': 'Pharma', 'PFE': 'Pharma', 'MRK': 'Pharma', 'LLY': 'Pharma',
    'ABBV': 'Pharma', 'BMY': 'Pharma', 'GILD': 'Pharma', 'NVO': 'Pharma',
    // Energy
    'XOM': 'Energy', 'CVX': 'Energy', 'COP': 'Energy', 'OXY': 'Energy',
    // Consumer
    'WMT': 'Consumer', 'COST': 'Consumer', 'TGT': 'Consumer',
    'HD': 'Consumer', 'NKE': 'Consumer', 'MCD': 'Consumer', 'SBUX': 'Consumer',
    // Crypto-adjacent
    'COIN': 'Crypto', 'MARA': 'Crypto', 'RIOT': 'Crypto', 'MSTR': 'Crypto',
    // Broad-market ETFs
    'SPY': 'BroadETF', 'VOO': 'BroadETF', 'IVV': 'BroadETF',
    'QQQ': 'BroadETF', 'DIA': 'BroadETF', 'IWM': 'BroadETF',
    // Sector ETFs (separate bucket so they don't collapse into single names)
    'XLK': 'TechETF', 'XLF': 'FinanceETF', 'XLE': 'EnergyETF',
    'XLV': 'HealthETF', 'XLY': 'ConsumerETF', 'SMH': 'SemisETF',
  };

  static String? _sectorFor(String symbol) => _sectorMap[symbol.toUpperCase()];

  // The liquid-universe is exactly the set of symbols we have a sector
  // mapping for — these are the only names the engine has any business
  // trading on a market-order, fast-stop strategy.
  static final Set<String> _liquidUniverse = _sectorMap.keys.toSet();
}

class _CachedAsset {
  final AssetInfo asset;
  final DateTime fetchedAt;
  const _CachedAsset({required this.asset, required this.fetchedAt});
}
