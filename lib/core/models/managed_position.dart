class ExitRules {
  final double stopLossPercent;
  final double takeProfitPercent;
  final double takeProfitSellFraction;
  final bool trailingStopEnabled;
  final double trailingStopPercent;
  final int maxHoldDays;

  const ExitRules({
    this.stopLossPercent = 0.08,
    this.takeProfitPercent = 0.15,
    this.takeProfitSellFraction = 0.5,
    this.trailingStopEnabled = true,
    this.trailingStopPercent = 0.05,
    this.maxHoldDays = 14,
  });

  Map<String, dynamic> toMap() => {
        'stopLossPercent': stopLossPercent,
        'takeProfitPercent': takeProfitPercent,
        'takeProfitSellFraction': takeProfitSellFraction,
        'trailingStopEnabled': trailingStopEnabled,
        'trailingStopPercent': trailingStopPercent,
        'maxHoldDays': maxHoldDays,
      };

  factory ExitRules.fromMap(Map<String, dynamic> map) => ExitRules(
        stopLossPercent: (map['stopLossPercent'] as num?)?.toDouble() ?? 0.08,
        takeProfitPercent:
            (map['takeProfitPercent'] as num?)?.toDouble() ?? 0.15,
        takeProfitSellFraction:
            (map['takeProfitSellFraction'] as num?)?.toDouble() ?? 0.5,
        trailingStopEnabled: map['trailingStopEnabled'] as bool? ?? true,
        trailingStopPercent:
            (map['trailingStopPercent'] as num?)?.toDouble() ?? 0.05,
        maxHoldDays: (map['maxHoldDays'] as num?)?.toInt() ?? 14,
      );
}

class ManagedPosition {
  final String symbol;
  final String buyOrderId;
  final double entryPrice;
  final double originalQty;
  final double remainingQty;
  final DateTime entryTime;
  final ExitRules exitRules;
  final String? stopLossOrderId;
  final double? currentStopPrice;
  final bool takeProfitTriggered;
  final DateTime? lastReEvaluation;
  final String source; // 'engine' or 'manual'

  const ManagedPosition({
    required this.symbol,
    required this.buyOrderId,
    required this.entryPrice,
    required this.originalQty,
    required this.remainingQty,
    required this.entryTime,
    this.exitRules = const ExitRules(),
    this.stopLossOrderId,
    this.currentStopPrice,
    this.takeProfitTriggered = false,
    this.lastReEvaluation,
    this.source = 'engine',
  });

  int get holdDays {
    final days = DateTime.now().difference(entryTime).inDays;
    if (days < 0) {
      // entryTime is in the future — device clock was likely skewed at entry time.
      // Use lastReEvaluation as a proxy for elapsed time if available; otherwise 0.
      if (lastReEvaluation != null) {
        return DateTime.now().difference(lastReEvaluation!).inDays.clamp(0, 99999);
      }
      return 0;
    }
    return days.clamp(0, 99999);
  }

  bool get isOverdue => holdDays >= exitRules.maxHoldDays;
  bool get isWayOverdue => holdDays >= exitRules.maxHoldDays * 2;

  ManagedPosition copyWith({
    String? symbol,
    String? buyOrderId,
    double? entryPrice,
    double? originalQty,
    double? remainingQty,
    DateTime? entryTime,
    ExitRules? exitRules,
    String? stopLossOrderId,
    double? currentStopPrice,
    bool? takeProfitTriggered,
    DateTime? lastReEvaluation,
    String? source,
  }) {
    return ManagedPosition(
      symbol: symbol ?? this.symbol,
      buyOrderId: buyOrderId ?? this.buyOrderId,
      entryPrice: entryPrice ?? this.entryPrice,
      originalQty: originalQty ?? this.originalQty,
      remainingQty: remainingQty ?? this.remainingQty,
      entryTime: entryTime ?? this.entryTime,
      exitRules: exitRules ?? this.exitRules,
      stopLossOrderId: stopLossOrderId ?? this.stopLossOrderId,
      currentStopPrice: currentStopPrice ?? this.currentStopPrice,
      takeProfitTriggered: takeProfitTriggered ?? this.takeProfitTriggered,
      lastReEvaluation: lastReEvaluation ?? this.lastReEvaluation,
      source: source ?? this.source,
    );
  }

  Map<String, dynamic> toMap() => {
        'symbol': symbol,
        'buyOrderId': buyOrderId,
        'entryPrice': entryPrice,
        'originalQty': originalQty,
        'remainingQty': remainingQty,
        'entryTime': entryTime.toIso8601String(),
        'exitRules': exitRules.toMap(),
        'stopLossOrderId': stopLossOrderId,
        'currentStopPrice': currentStopPrice,
        'takeProfitTriggered': takeProfitTriggered,
        'lastReEvaluation': lastReEvaluation?.toIso8601String(),
        'source': source,
      };

  factory ManagedPosition.fromMap(Map<String, dynamic> map) {
    return ManagedPosition(
      symbol: map['symbol'] ?? '',
      buyOrderId: map['buyOrderId'] ?? '',
      entryPrice: (map['entryPrice'] as num?)?.toDouble() ?? 0,
      originalQty: (map['originalQty'] as num?)?.toDouble() ?? 0,
      remainingQty: (map['remainingQty'] as num?)?.toDouble() ?? 0,
      entryTime:
          DateTime.tryParse(map['entryTime'] ?? '') ?? DateTime.now(),
      exitRules: map['exitRules'] != null
          ? ExitRules.fromMap(Map<String, dynamic>.from(map['exitRules']))
          : const ExitRules(),
      stopLossOrderId: map['stopLossOrderId'],
      currentStopPrice: (map['currentStopPrice'] as num?)?.toDouble(),
      takeProfitTriggered: map['takeProfitTriggered'] as bool? ?? false,
      lastReEvaluation: map['lastReEvaluation'] != null
          ? DateTime.tryParse(map['lastReEvaluation'])
          : null,
      source: map['source'] ?? 'engine',
    );
  }
}
