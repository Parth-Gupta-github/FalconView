import 'dart:async';

import 'package:flutter/material.dart';

import '../models/place.dart';
import '../services/nominatim_service.dart';
import '../services/offline_repository.dart';

enum SearchTab { search, downloaded }

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const Duration _debounce = Duration(milliseconds: 350);

  SearchTab _tab = SearchTab.search;
  final TextEditingController _controller = TextEditingController();
  final NominatimService _nominatim = NominatimService();
  final OfflineRepository _offline = OfflineRepository();

  Timer? _debounceTimer;
  int _requestSeq = 0;
  bool _loading = false;
  String? _error;
  List<Place> _searchResults = const <Place>[];

  List<Place> _downloadedResults = const <Place>[];
  bool _downloadedLoading = true;

  @override
  void initState() {
    super.initState();
    _refreshDownloaded();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _nominatim.dispose();
    super.dispose();
  }

  Future<void> _refreshDownloaded() async {
    if (!mounted) return;
    setState(() => _downloadedLoading = true);
    try {
      final List<Place> list = await _offline.listDownloaded();
      if (!mounted) return;
      setState(() {
        _downloadedResults = list;
        _downloadedLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _downloadedResults = const <Place>[];
        _downloadedLoading = false;
      });
    }
  }

  void _onQueryChanged(String value) {
    _debounceTimer?.cancel();
    final String q = value.trim();
    if (_tab == SearchTab.downloaded) {
      setState(() {});
      return;
    }
    if (q.isEmpty) {
      setState(() {
        _searchResults = const <Place>[];
        _loading = false;
        _error = null;
      });
      return;
    }
    _debounceTimer = Timer(_debounce, () => _runSearch(q));
  }

  Future<void> _runSearch(String query) async {
    final int seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Place> results = await _nominatim.search(query);
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _searchResults = results;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loading = false;
        _error = 'Search failed. Check your connection.';
        _searchResults = const <Place>[];
      });
    }
  }

  Future<void> _onDownloadTap(Place place) async {
    setState(() => place.state = PlaceDownloadState.downloading);
    try {
      await _offline.download(place);
      if (!mounted) return;
      setState(() => place.state = PlaceDownloadState.downloaded);
      await _refreshDownloaded();
    } on OfflineNotAvailable catch (e) {
      if (!mounted) return;
      setState(() => place.state = PlaceDownloadState.none);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => place.state = PlaceDownloadState.none);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isSearch = _tab == SearchTab.search;
    final List<Place> rows = isSearch ? _searchResults : _downloadedResults;
    final bool hasQuery = _controller.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        leading: const BackButton(),
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Center(
              child: SegmentedButton<SearchTab>(
                segments: const [
                  ButtonSegment(value: SearchTab.search, label: Text('Search')),
                  ButtonSegment(value: SearchTab.downloaded, label: Text('Downloaded')),
                ],
                selected: <SearchTab>{_tab},
                onSelectionChanged: (Set<SearchTab> next) {
                  setState(() => _tab = next.first);
                  if (_tab == SearchTab.downloaded) {
                    _refreshDownloaded();
                  }
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _controller,
              autofocus: isSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: isSearch ? 'Search any city or district' : 'Filter your downloads',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: hasQuery
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _controller.clear();
                          _onQueryChanged('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody(isSearch, rows, hasQuery)),
        ],
      ),
    );
  }

  Widget _buildBody(bool isSearch, List<Place> rows, bool hasQuery) {
    if (isSearch) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
          ),
        );
      }
      if (!hasQuery) {
        return const Center(
          child: Text('Type to search places', style: TextStyle(color: Colors.black54)),
        );
      }
    } else if (_downloadedLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final List<Place> visible = (!isSearch && hasQuery)
        ? rows.where((p) => p.name.toLowerCase().contains(_controller.text.trim().toLowerCase())).toList()
        : rows;
    if (visible.isEmpty) {
      return Center(
        child: Text(
          isSearch ? 'No results' : 'No offline regions yet',
          style: const TextStyle(color: Colors.black54),
        ),
      );
    }
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final Place p = visible[index];
        return ListTile(
          title: Text(p.name),
          subtitle: Text(p.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: _buildTrailing(p, isSearch),
          onTap: () => Navigator.of(context).pop(p),
        );
      },
    );
  }

  Widget _buildTrailing(Place place, bool isSearch) {
    if (isSearch) {
      switch (place.state) {
        case PlaceDownloadState.none:
          return IconButton(
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _onDownloadTap(place),
          );
        case PlaceDownloadState.downloading:
          return const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          );
        case PlaceDownloadState.downloaded:
          return const Icon(Icons.check, color: Colors.green);
      }
    }
    return IconButton(
      icon: const Icon(Icons.delete_outline),
      onPressed: () => _confirmDelete(place),
    );
  }

  Future<void> _confirmDelete(Place place) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete offline region?'),
        content: Text('Remove "${place.name}" from offline storage?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final int? id = place.regionId;
    if (id == null) return;
    try {
      await _offline.delete(id);
      await _refreshDownloaded();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }
}
