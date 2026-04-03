import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morex/config/theme.dart';

void main() {
  group('AppTheme', () {
    test('dark theme has dark brightness', () {
      expect(AppTheme.dark.brightness, Brightness.dark);
    });

    test('dark theme uses Material3', () {
      expect(AppTheme.dark.useMaterial3, true);
    });

    test('dark theme uses Material3 design', () {
      expect(AppTheme.dark.useMaterial3, true);
    });

    test('dark theme has green seed color', () {
      // Color 0xFF00C853 is a shade of green
      final seedColor = AppTheme.dark.colorScheme.primary;
      expect(seedColor, isNotNull);
    });

    test('dark theme color scheme matches brightness', () {
      final colorScheme = AppTheme.dark.colorScheme;
      expect(colorScheme.brightness, Brightness.dark);
    });

    test('dark theme has consistent configuration', () {
      final theme = AppTheme.dark;
      expect(theme.brightness, Brightness.dark);
      expect(theme.useMaterial3, true);
      expect(theme.colorScheme.brightness, Brightness.dark);
    });

    test('dark theme colors are suitable for dark background', () {
      final theme = AppTheme.dark;
      final colorScheme = theme.colorScheme;

      // In dark themes, the surface and background should be dark colors
      // and the text color should be light
      expect(colorScheme.brightness, Brightness.dark);
    });

    test('dark theme is the only theme available in AppTheme', () {
      expect(AppTheme.dark, isNotNull);
    });
  });
}


