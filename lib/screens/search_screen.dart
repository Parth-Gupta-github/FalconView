import 'dart:async';

import 'package:flutter/material.dart';

import '../models/place.dart';
import '../services/nominatim_service.dart';

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

  Timer? _debounceTimer;
  int _requestSeq = 0;
  bool _loading = false;
  String? _error;
  List<Place> _searchResults = const <Place>[];

  final List<Place> _downloadedResults = <Place>[
    Place(
      name: 'Indore',
      subtitle: 'Madhya Pradesh, India',
      center: const LatLng(22.7196, 75.8577),
      bbox: LatLngBounds(
        southwest: const LatLng(22.65, 75.78),
        northeast: const LatLng(22.80, 75.94),
      ),
      state: PlaceDownloadState.downloaded,
    ),
  ];

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _nominatim.dispose();
    super.dispose();
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
    }
    if (rows.isEmpty) {
      return const Center(
        child: Text('No results', style: TextStyle(color: Colors.black54)),
      );
    }
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final Place p = rows[index];
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
            onPressed: () => setState(() => place.state = PlaceDownloadState.downloading),
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
    if (ok == true) {
      setState(() => _downloadedResults.remove(place));
    }
  }
}
