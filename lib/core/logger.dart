import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warning, error }

class Log {
  static LogLevel _minLevel = kReleaseMode ? LogLevel.info : LogLevel.debug;

  static set minLevel(LogLevel level) => _minLevel = level;

  static void d(String tag, String message) =>
      _log(LogLevel.debug, tag, message);

  static void i(String tag, String message) =>
      _log(LogLevel.info, tag, message);

  static void w(String tag, String message) =>
      _log(LogLevel.warning, tag, message);

  static void e(String tag, String message, [Object? error]) {
    _log(LogLevel.error, tag, error != null ? '$message: $error' : message);
  }

  static void _log(LogLevel level, String tag, String message) {
    if (level.index < _minLevel.index) return;

    final prefix = switch (level) {
      LogLevel.debug => 'D',
      LogLevel.info => 'I',
      LogLevel.warning => 'W',
      LogLevel.error => 'E',
    };

    final line = '[$prefix/$tag] $message';

    if (kReleaseMode) {
      // In release mode, use dart:developer log (visible in device logs,
      // not stripped like print). Errors always logged.
      if (level.index >= LogLevel.warning.index) {
        dev.log(line, name: 'Morex', level: level == LogLevel.error ? 1000 : 900);
      }
    } else {
      // In debug mode, print everything at or above min level
      // ignore: avoid_print
      print(line);
    }
  }
}
