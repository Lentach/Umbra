import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/models/chat_background_preference.dart';
import 'package:fireplace/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Owner ruling 2026-07-28: Hot Stone ('light', warm paper + ember) is the
  // default theme for fresh installs. Saved choices always win — the flip must
  // never stomp an existing preference, and the legacy dark_mode_preference
  // migration keeps mapping old dark/system picks to 'dark'.
  group('theme default', () {
    test('fresh install defaults to Hot Stone (light)', () async {
      SharedPreferences.setMockInitialValues({});
      expect(SettingsProvider.kDefaultThemePreference, 'light');
      expect(await SettingsProvider.storedThemePreference(), 'light');

      final settings = SettingsProvider();
      // Constructor field default paints frame 1 before the async load lands.
      expect(settings.themePreference, 'light');
      expect(settings.themeMode, ThemeMode.light);
      // Let the async prefs load settle; still light.
      await Future<void>.delayed(Duration.zero);
      expect(settings.themePreference, 'light');
    });

    test('saved preference survives the default flip', () async {
      SharedPreferences.setMockInitialValues({'theme_preference': 'dark'});
      expect(await SettingsProvider.storedThemePreference(), 'dark');
    });

    test('legacy dark_mode_preference still migrates to dark', () async {
      SharedPreferences.setMockInitialValues({
        'dark_mode_preference': 'system',
      });
      expect(await SettingsProvider.storedThemePreference(), 'dark');
    });

    test('invalid stored value falls back to the Hot Stone default', () async {
      SharedPreferences.setMockInitialValues({'theme_preference': 'neon'});
      expect(await SettingsProvider.storedThemePreference(), 'light');
    });
  });

  // Autoplay videos is ON by default (Telegram parity); turning it off must
  // survive a restart, which a fresh provider over the same prefs simulates.
  group('autoplay videos', () {
    test('fresh install defaults to autoplay ON', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider(initialThemePreference: 'light');
      expect(settings.autoplayVideos, isTrue);
      // Let the async prefs load settle; still on.
      await Future<void>.delayed(Duration.zero);
      expect(settings.autoplayVideos, isTrue);
    });

    test('setAutoplayVideos(false) persists and a fresh provider loads it',
        () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider(initialThemePreference: 'light');
      await settings.setAutoplayVideos(false);
      expect(settings.autoplayVideos, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('autoplay_videos'), isFalse);

      final relaunched = SettingsProvider(initialThemePreference: 'light');
      await Future<void>.delayed(Duration.zero);
      expect(relaunched.autoplayVideos, isFalse);
    });
  });

  // Amendment (lxxix): key-change warnings are DEMOTED (off) by default; opting
  // back in must survive a restart, which a fresh provider over the same prefs
  // simulates.
  group('key-change warnings', () {
    test('fresh install defaults to warnings OFF', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider(initialThemePreference: 'light');
      expect(settings.keyChangeWarnings, isFalse);
      // Let the async prefs load settle; still off.
      await Future<void>.delayed(Duration.zero);
      expect(settings.keyChangeWarnings, isFalse);
    });

    test('setKeyChangeWarnings(true) persists and a fresh provider loads it',
        () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider(initialThemePreference: 'light');
      await settings.setKeyChangeWarnings(true);
      expect(settings.keyChangeWarnings, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('key_change_warnings'), isTrue);

      final relaunched = SettingsProvider(initialThemePreference: 'light');
      await Future<void>.delayed(Duration.zero);
      expect(relaunched.keyChangeWarnings, isTrue);
    });
  });

  // Decision 62 / E61c: receipts and typing on box chats are OFF until this
  // device's user turns them on, and the choice survives a restart (a fresh
  // provider over the same prefs).
  group('receipts and typing', () {
    test('a fresh install has receipts and typing OFF', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider(initialThemePreference: 'light');
      await Future<void>.delayed(Duration.zero);
      expect(settings.receiptsAndTyping, isFalse);
    });

    test('turning it on persists and a fresh provider loads it', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider(initialThemePreference: 'light');
      await settings.setReceiptsAndTyping(enabled: true);
      expect(settings.receiptsAndTyping, isTrue);

      final relaunched = SettingsProvider(initialThemePreference: 'light');
      await Future<void>.delayed(Duration.zero);
      expect(relaunched.receiptsAndTyping, isTrue);

      await relaunched.setReceiptsAndTyping(enabled: false);
      final again = SettingsProvider(initialThemePreference: 'light');
      await Future<void>.delayed(Duration.zero);
      expect(again.receiptsAndTyping, isFalse);
    });
  });

  group('global chat background', () {
    test(
      'defaults to themeDefault and persists an explicit per-user value',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsProvider(initialThemePreference: 'dark');

        await settings.loadChatBackground(1);

        expect(settings.chatBackground, ChatBackgroundPreference.themeDefault);
        expect(settings.resolvedChatBackground, ChatBackgroundLayer.plain);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('chat_wallpaper_1'), 'theme_default');
      },
    );

    test(
      'explicit override round-trips per user and survives theme changes',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsProvider(initialThemePreference: 'dark');
        await settings.loadChatBackground(1);
        await settings.setChatBackground(1, ChatBackgroundPreference.glyphs);

        await settings.setThemePreference('cosmic');

        expect(settings.chatBackground, ChatBackgroundPreference.glyphs);
        expect(settings.resolvedChatBackground, ChatBackgroundLayer.glyphs);

        final reloaded = SettingsProvider(initialThemePreference: 'cosmic');
        await reloaded.loadChatBackground(1);
        expect(reloaded.chatBackground, ChatBackgroundPreference.glyphs);

        final otherUser = SettingsProvider(initialThemePreference: 'cosmic');
        await otherUser.loadChatBackground(2);
        expect(otherUser.chatBackground, ChatBackgroundPreference.themeDefault);
      },
    );

    test('themeDefault resolves to starfield only for Cosmic', () async {
      SharedPreferences.setMockInitialValues({
        'chat_wallpaper_1': 'theme_default',
      });
      final settings = SettingsProvider(initialThemePreference: 'cosmic');

      await settings.loadChatBackground(1);

      expect(settings.resolvedChatBackground, ChatBackgroundLayer.starfield);
      await settings.setThemePreference('blue');
      expect(settings.resolvedChatBackground, ChatBackgroundLayer.plain);
    });

    test(
      'saved Cosmic theme wins over async constructor state during migration',
      () async {
        SharedPreferences.setMockInitialValues({
          'theme_preference': 'cosmic',
          'cosmic_starfield_enabled': true,
          'chat_wallpaper_1': 'glyphs',
        });
        final settings = SettingsProvider(initialThemePreference: 'dark');

        await settings.loadChatBackground(1);

        expect(settings.chatBackground, ChatBackgroundPreference.themeDefault);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('chat_wallpaper_1'), 'theme_default');
      },
    );

    test(
      'legacy Cosmic-off migrates each account to plain without deleting source',
      () async {
        SharedPreferences.setMockInitialValues({
          'theme_preference': 'cosmic',
          'cosmic_starfield_enabled': false,
        });

        final first = SettingsProvider(initialThemePreference: 'dark');
        await first.loadChatBackground(1);
        expect(first.chatBackground, ChatBackgroundPreference.plain);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('cosmic_starfield_enabled'), isFalse);

        final second = SettingsProvider(initialThemePreference: 'dark');
        await second.loadChatBackground(2);
        expect(second.chatBackground, ChatBackgroundPreference.plain);
        expect(prefs.getString('chat_wallpaper_1'), 'plain');
        expect(prefs.getString('chat_wallpaper_2'), 'plain');
      },
    );

    test('migrates legacy per-conversation glyph keys for one user', () async {
      SharedPreferences.setMockInitialValues({
        'theme_preference': 'dark',
        'conversation_wallpaper_1:10': 'glyphs',
        'conversation_wallpaper_1:11': 'default',
        'conversation_wallpaper_2:30': 'glyphs',
      });
      final settings = SettingsProvider(initialThemePreference: 'dark');

      await settings.loadChatBackground(1);

      expect(settings.chatBackground, ChatBackgroundPreference.glyphs);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('chat_wallpaper_1'), 'hieroglyphs');
      expect(prefs.containsKey('conversation_wallpaper_1:10'), isFalse);
      expect(prefs.containsKey('conversation_wallpaper_1:11'), isFalse);
      expect(prefs.containsKey('conversation_wallpaper_2:30'), isTrue);
    });

    test(
      'explicit legacy default wins over per-conversation glyph keys',
      () async {
        SharedPreferences.setMockInitialValues({
          'theme_preference': 'dark',
          'chat_wallpaper_1': 'default',
          'conversation_wallpaper_1:10': 'glyphs',
        });
        final settings = SettingsProvider(initialThemePreference: 'dark');

        await settings.loadChatBackground(1);

        expect(settings.chatBackground, ChatBackgroundPreference.themeDefault);
      },
    );

    test(
      'legacy dark-mode preference is used when theme key is absent',
      () async {
        SharedPreferences.setMockInitialValues({
          'dark_mode_preference': 'light',
          'cosmic_starfield_enabled': false,
          'chat_wallpaper_1': 'glyphs',
        });
        final settings = SettingsProvider(initialThemePreference: 'cosmic');

        await settings.loadChatBackground(1);

        expect(settings.chatBackground, ChatBackgroundPreference.glyphs);
      },
    );
  });
}
