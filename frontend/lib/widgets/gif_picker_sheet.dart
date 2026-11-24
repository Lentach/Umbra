import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../services/gif_service.dart';
import 'glass/glass_dialog.dart';
import 'glass/glass_sheet.dart';

class GifPickerSheet extends StatefulWidget {
  final void Function(String gifFullUrl) onGifSelected;

  /// Test seam: the Giphy client. Defaults to a real [GifService].
  @visibleForTesting
  final GifService? service;

  const GifPickerSheet({super.key, required this.onGifSelected, this.service});

  @override
  State<GifPickerSheet> createState() => _GifPickerSheetState();

  /// Every Giphy request starts inside this sheet, so it opens only once GIF
  /// search is on ([SettingsProvider.gifSearch], plan C2). While it is off the
  /// tap asks first; a yes turns it on for this device.
  static Future<void> show(
    BuildContext context, {
    required void Function(String) onGifSelected,
  }) async {
    final settings = context.read<SettingsProvider>();
    if (!settings.gifSearch) {
      final enabled = await _askToEnable(context);
      if (!enabled || !context.mounted) return;
      await settings.setGifSearch(enabled: true);
      if (!context.mounted) return;
    }
    // Media-dense grid: opaque sheet surface (spec §7 per-surface fallback);
    // a 60%-viewport backdrop blur would be pure cost under the grid.
    return showGlassSheet(
      context,
      isScrollControlled: true,
      opaque: true,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: GifPickerSheet(onGifSelected: onGifSelected),
      ),
    );
  }

  static Future<bool> _askToEnable(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final enabled = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: Text(l10n.gifConsentTitle),
        content: Text(l10n.gifConsentBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.gifConsentEnable),
          ),
        ],
      ),
    );
    return enabled ?? false;
  }
}

class _GifPickerSheetState extends State<GifPickerSheet> {
  late final _gifService = widget.service ?? GifService();
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  List<GifModel> _gifs = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  Timer? _debounce;
  int _offset = 0;
  String _lastQuery = '';

  /// Names the list the grid is showing: every trending load and every search
  /// takes a new number, and a response that finds a newer one is stale.
  int _listId = 0;

  @override
  void initState() {
    super.initState();
    _loadTrending();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    _gifService.dispose();
    super.dispose();
  }

  Future<void> _loadTrending() async {
    final id = ++_listId;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _offset = 0;
      _lastQuery = '';
    });
    final results = await _gifService.fetchTrending();
    if (!mounted || id != _listId) return;
    setState(() {
      _gifs = results;
      _loading = false;
      _error = results.isEmpty ? 'no_results' : null;
    });
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      _loadTrending();
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 500),
      () => _doSearch(query.trim()),
    );
  }

  Future<void> _doSearch(String query) async {
    final id = ++_listId;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _offset = 0;
      _lastQuery = query;
    });
    final results = await _gifService.search(query);
    if (!mounted || id != _listId) return;
    setState(() {
      _gifs = results;
      _loading = false;
      _error = results.isEmpty ? 'no_results' : null;
    });
  }

  void _onScroll() {
    if (_loadingMore) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    final id = _listId;
    final offset = _offset + 25;
    final results = _lastQuery.isEmpty
        ? await _gifService.fetchTrending(offset: offset)
        : await _gifService.search(_lastQuery, offset: offset);
    if (!mounted || id != _listId) return;
    setState(() {
      // A page that came back empty (the service answers [] on failure) does
      // not move the offset, so the next scroll asks for the same page.
      if (results.isNotEmpty) _offset = offset;
      _gifs.addAll(results);
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      children: [
        const SizedBox(height: 8),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: theme.dividerColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: l10n.gifSearchHint,
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error == 'no_results'
              ? Center(
                  child: Text(
                    l10n.gifNoResults,
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              : GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                  itemCount: _gifs.length + (_loadingMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _gifs.length) {
                      return const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      );
                    }
                    final gif = _gifs[index];
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        widget.onGifSelected(gif.fullUrl);
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          gif.previewUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, e, st) => Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.broken_image, size: 32),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Powered by', style: theme.textTheme.bodySmall),
              const SizedBox(width: 6),
              Image.asset(
                theme.brightness == Brightness.dark
                    ? 'assets/giphy/giphy_logo_white.png'
                    : 'assets/giphy/giphy_logo_black.png',
                height: 16,
                filterQuality: FilterQuality.medium,
                // Fallback keeps the required "Powered by GIPHY" wording if the
                // asset ever fails to load.
                errorBuilder: (_, _, _) => Text(
                  'GIPHY',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
