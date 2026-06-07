import 'dart:async';
import 'dart:convert';
import 'dart:math' show min, Random;

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:morex/config/env.dart';
import 'package:morex/core/logger.dart';

enum WsConnectionState { disconnected, connecting, authenticating, connected }

class AlpacaWebSocket {
  final String _url;
  final String _apiKey;
  final String _apiSecret;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _connectTimeoutTimer;

  final _stateController =
      StreamController<WsConnectionState>.broadcast();
  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  WsConnectionState _state = WsConnectionState.disconnected;
  final Set<String> _subscribedTrades = {};
  final Set<String> _subscribedQuotes = {};
  DateTime? _lastMessageTime;
  DateTime? _lastProbeTime;

  // Exponential backoff state
  int _reconnectAttempt = 0;
  static const _backoffBase = Duration(seconds: 5);
  static const _backoffMax = Duration(minutes: 5);
  static const _heartbeatCheckInterval = Duration(seconds: 10);
  static const _heartbeatTimeout = Duration(seconds: 30);
  // After this much silence, send a probe to confirm two-way liveness before
  // the full timeout fires. Catches a dead subscription without waiting 30s.
  static const _probeInterval = Duration(seconds: 15);

  AlpacaWebSocket({
    required String url,
    String? apiKey,
    String? apiSecret,
  })  : _url = url,
        _apiKey = apiKey ?? Env.alpacaApiKey,
        _apiSecret = apiSecret ?? Env.alpacaApiSecret;

  Stream<WsConnectionState> get stateStream => _stateController.stream;
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  WsConnectionState get state => _state;

  bool get _isTradingStream => !_url.contains('stream.data');

  void connect() {
    if (_state != WsConnectionState.disconnected) return;
    _setState(WsConnectionState.connecting);
    _reconnectTimer?.cancel();

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_url));
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );

      // Set connection timeout: if no response in 15s, reconnect
      _connectTimeoutTimer?.cancel();
      _connectTimeoutTimer = Timer(const Duration(seconds: 15), () {
        if (_state == WsConnectionState.connecting ||
            _state == WsConnectionState.authenticating) {
          _onError('WebSocket connection timeout');
        }
      });

      // Trading stream has no server hello — send auth immediately and cancel
      // the connect timeout (auth timeout is handled by the 15s timer above).
      // Data stream waits for a server hello before authenticating; the timeout
      // is cancelled inside _handleMessage once 'authenticated' is received.
      if (_isTradingStream) {
        _setState(WsConnectionState.authenticating);
        _authenticate();
        _connectTimeoutTimer?.cancel();
        _connectTimeoutTimer = null;
      }
    } catch (e) {
      _setState(WsConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    _lastMessageTime = DateTime.now();
    _lastProbeTime = null; // A real message arrived — reset probe window

    final String rawStr;
    if (raw is List<int>) {
      rawStr = utf8.decode(raw);
    } else {
      rawStr = raw as String;
    }
    final dynamic data;
    try {
      data = jsonDecode(rawStr);
    } catch (e) {
      Log.w('AlpacaWS', 'Malformed JSON from WebSocket, ignoring: $e');
      return;
    }

    if (data is List) {
      for (final msg in data) {
        _handleMessage(msg as Map<String, dynamic>);
      }
    } else if (data is Map<String, dynamic>) {
      _handleMessage(data);
    }
  }

  void _handleMessage(Map<String, dynamic> msg) {
    final type = msg['T'] ?? msg['stream'];

    // Alpaca data stream messages
    if (type == 'success') {
      final msgType = msg['msg'];
      if (msgType == 'connected') {
        Log.i('AlpacaWS', 'Server hello received, authenticating...');
        _setState(WsConnectionState.authenticating);
        _authenticate();
      } else if (msgType == 'authenticated') {
        Log.i('AlpacaWS', 'Authenticated successfully');
        _connectTimeoutTimer?.cancel();
        _connectTimeoutTimer = null;
        _reconnectAttempt = 0;
        _setState(WsConnectionState.connected);
        _resubscribe();
        _startHeartbeat();
      }
      return;
    }

    if (type == 'error') {
      Log.e('AlpacaWS', 'Server error: ${msg['msg']}');
      _onError(msg['msg'] ?? 'Unknown WebSocket error');
      return;
    }

    // Alpaca trading stream auth response:
    // { stream: "authorization", data: { action: "authenticate", status: "authorized" } }
    if (type == 'authorization') {
      final data = msg['data'];
      final status = (data is Map) ? data['status'] : null;
      if (status == 'authorized') {
        Log.i('AlpacaWS', 'Trading auth authorized');
        _connectTimeoutTimer?.cancel();
        _connectTimeoutTimer = null;
        _reconnectAttempt = 0;
        _setState(WsConnectionState.connected);
        _listenTradeUpdates();
        _startHeartbeat();
      } else {
        Log.e('AlpacaWS', 'Trading auth failed: $data');
        _onError('WebSocket authentication failed: $data');
      }
      return;
    }

    if (type == 'listening') return;

    // Forward data messages (trades, quotes, bars, trade_updates)
    _messageController.add(msg);
  }

  void _authenticate() {
    // Both data and trading streams use the same auth format
    _send({'action': 'auth', 'key': _apiKey, 'secret': _apiSecret});
  }

  void _listenTradeUpdates() {
    if (_isTradingStream) {
      Log.d('AlpacaWS', 'Subscribing to trade_updates stream');
      _send({
        'action': 'listen',
        'data': {'streams': ['trade_updates']},
      });
    } else {
      Log.w('AlpacaWS', '_listenTradeUpdates called on non-trading stream');
    }
  }

  void subscribeTrades(List<String> symbols) {
    _subscribedTrades.addAll(symbols);
    if (_state == WsConnectionState.connected && !_isTradingStream) {
      Log.d('AlpacaWS', 'Subscribing to trades: $symbols');
      _send({
        'action': 'subscribe',
        'trades': symbols,
      });
    } else if (_state != WsConnectionState.connected) {
      Log.d('AlpacaWS', 'Deferring trade subscription until connected: $symbols');
    }
  }

  void subscribeQuotes(List<String> symbols) {
    _subscribedQuotes.addAll(symbols);
    if (_state == WsConnectionState.connected && !_isTradingStream) {
      Log.d('AlpacaWS', 'Subscribing to quotes: $symbols');
      _send({
        'action': 'subscribe',
        'quotes': symbols,
      });
    } else if (_state != WsConnectionState.connected) {
      Log.d('AlpacaWS', 'Deferring quote subscription until connected: $symbols');
    }
  }

  void unsubscribeTrades(List<String> symbols) {
    _subscribedTrades.removeAll(symbols);
    if (_state == WsConnectionState.connected && !_isTradingStream) {
      _send({
        'action': 'unsubscribe',
        'trades': symbols,
      });
    }
  }

  void unsubscribeQuotes(List<String> symbols) {
    _subscribedQuotes.removeAll(symbols);
    if (_state == WsConnectionState.connected && !_isTradingStream) {
      _send({
        'action': 'unsubscribe',
        'quotes': symbols,
      });
    }
  }

  void _resubscribe() {
    if (_subscribedTrades.isNotEmpty) {
      subscribeTrades(_subscribedTrades.toList());
    }
    if (_subscribedQuotes.isNotEmpty) {
      subscribeQuotes(_subscribedQuotes.toList());
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastMessageTime = DateTime.now();
    _lastProbeTime = null;

    _heartbeatTimer = Timer.periodic(_heartbeatCheckInterval, (_) {
      if (_state != WsConnectionState.connected || _lastMessageTime == null) return;
      final now = DateTime.now();
      final elapsed = now.difference(_lastMessageTime!);

      if (elapsed > _heartbeatTimeout) {
        Log.w('AlpacaWS',
            'Heartbeat timeout: no message for ${elapsed.inSeconds}s, reconnecting');
        _scheduleReconnect();
        return;
      }

      // After half the timeout with no messages, send a probe to confirm that
      // the server can still reach us. A silently-dropped subscription (server
      // alive, TCP socket open, but our channel dead) is caught this way rather
      // than waiting the full 30s. The server's response resets _lastMessageTime.
      if (elapsed > _probeInterval) {
        final lastProbe = _lastProbeTime;
        if (lastProbe == null || now.difference(lastProbe) > _probeInterval) {
          _lastProbeTime = now;
          _sendProbe();
        }
      }
    });
  }

  /// Sends a lightweight round-trip probe appropriate for the stream type.
  /// The server always responds, which updates [_lastMessageTime] and confirms
  /// two-way liveness. Silently ignored if the channel is not connected.
  void _sendProbe() {
    if (_state != WsConnectionState.connected) return;
    if (_isTradingStream) {
      // Re-send listen — server replies with {"T":"listening","streams":[...]}
      _send({'action': 'listen', 'data': {'streams': ['trade_updates']}});
    } else {
      // Re-send subscribe — server replies with {"T":"subscription",...}
      final quotes = _subscribedQuotes.toList();
      final trades = _subscribedTrades.toList();
      if (quotes.isNotEmpty) {
        _send({'action': 'subscribe', 'quotes': quotes});
      } else if (trades.isNotEmpty) {
        _send({'action': 'subscribe', 'trades': trades});
      }
    }
  }

  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  void _onError(dynamic error) {
    Log.w('AlpacaWS', 'Connection error: $error');
    _setState(WsConnectionState.disconnected);
    _cleanup();
    _scheduleReconnect();
  }

  void _onDone() {
    Log.i('AlpacaWS', 'Connection closed, reconnecting...');
    _setState(WsConnectionState.disconnected);
    _cleanup();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final backoff = Duration(
      milliseconds: min(
        _backoffBase.inMilliseconds * (1 << _reconnectAttempt),
        _backoffMax.inMilliseconds,
      ),
    );
    // Add jitter: ±20% of backoff to avoid thundering herd
    final jitter = (backoff.inMilliseconds * 0.2 * (Random().nextDouble() * 2 - 1)).round();
    final delay = Duration(milliseconds: backoff.inMilliseconds + jitter);
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, connect);
  }

  void _setState(WsConnectionState newState) {
    if (_state != newState) {
      Log.d('AlpacaWS', 'State: $_state → $newState');
      _state = newState;
      if (!_stateController.isClosed) {
        _stateController.add(newState);
      }
    }
  }

  void _cleanup() {
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = null;
    _heartbeatTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  /// Cleanly disconnect without scheduling a reconnect. Call when the app
  /// goes to background. Use [connect] to reconnect when resuming.
  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _setState(WsConnectionState.disconnected);
    _cleanup();
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _cleanup();
    _stateController.close();
    _messageController.close();
  }
}