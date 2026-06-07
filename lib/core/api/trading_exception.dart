/// Thrown when the market is closed and a market order cannot be placed.
class MarketClosedException implements Exception {
  final String message;
  MarketClosedException(this.message);
  @override
  String toString() => message;
}

/// Thrown when symbol validation fails at the API level (network error, etc.).
/// Distinct from symbols that exist but are non-tradable.
class SymbolValidationException implements Exception {
  final String message;
  SymbolValidationException(this.message);
  @override
  String toString() => message;
}

/// Thrown when placing or replacing a stop-loss order fails.
/// The position is live but unprotected — callers must handle this explicitly.
class StopLossException implements Exception {
  final String symbol;
  final String message;
  StopLossException(this.symbol, this.message);
  @override
  String toString() => 'StopLossException[$symbol]: $message';
}

/// Thrown when an Alpaca API request fails. Check [statusCode] to distinguish
/// auth failures (401/403), rate limits (429), and server errors (5xx).
class AlpacaApiException implements Exception {
  final String message;
  final int? statusCode;
  AlpacaApiException(this.message, {this.statusCode});

  bool get isAuthError => statusCode == 401 || statusCode == 403;
  bool get isRateLimit => statusCode == 429;
  bool get isServerError => statusCode != null && statusCode! >= 500;

  @override
  String toString() => statusCode != null
      ? 'AlpacaApiException($statusCode): $message'
      : 'AlpacaApiException: $message';
}

/// Thrown when the Alpaca API credentials are missing or rejected.
class AlpacaAuthException extends AlpacaApiException {
  AlpacaAuthException(String message) : super(message, statusCode: 401);
  @override
  String toString() => 'AlpacaAuthException: $message';
}

/// Thrown when a Claude API request fails. Check [statusCode] to distinguish
/// auth failures (401), rate limits (429), and server errors (5xx).
class ClaudeApiException implements Exception {
  final String message;
  final int? statusCode;
  ClaudeApiException(this.message, {this.statusCode});

  bool get isAuthError => statusCode == 401;
  bool get isRateLimit => statusCode == 429;

  @override
  String toString() => statusCode != null
      ? 'ClaudeApiException($statusCode): $message'
      : 'ClaudeApiException: $message';
}
