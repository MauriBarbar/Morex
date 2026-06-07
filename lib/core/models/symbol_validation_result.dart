/// Result of validating a list of symbols against Alpaca's asset database.
class SymbolValidationResult {
  /// Symbols that exist and are tradable (status=='active' && tradable).
  final List<String> tradable;

  /// Symbols that exist but are not tradable (e.g. status=='inactive' or tradable==false).
  final List<String> nonTradable;

  /// Symbols that don't exist or failed API lookup (404 or network error).
  final List<String> notFound;

  const SymbolValidationResult({
    required this.tradable,
    required this.nonTradable,
    required this.notFound,
  });

  /// True if at least one symbol is tradable.
  bool get hasValidSymbols => tradable.isNotEmpty;

  /// All symbols that failed validation (nonTradable + notFound).
  List<String> get invalid => [...nonTradable, ...notFound];
}
