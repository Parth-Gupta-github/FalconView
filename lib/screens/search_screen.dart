import 'package:flutter/material.dart';

import '../models/place.dart';

enum SearchTab { search, downloaded }

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  SearchTab _tab = SearchTab.search;
  final TextEditingController _controller = TextEditingController();

  // Placeholder data so the UI is visible before Nominatim / OfflineManager are wired.
  final List<Place> _searchResults = <Place>[
    Place(
      name: 'Indore',
      subtitle: 'Madhya Pradesh, India',
      center: const LatLng(22.7196, 75.8577),
      bbox: const LatLngBounds(south: 22.65, north: 22.80, west: 75.78, east: 75.94),
    ),
    Place(
      name: 'Bhopal',
      subtitle: 'Madhya Pradesh, India',
      center: const LatLng(23.2599, 77.4126),
      bbox: const LatLngBounds(south: 23.15, north: 23.35, west: 77.30, east: 77.53),
    ),
  ];

  final List<Place> _downloadedResults = <Place>[
    Place(
      name: 'Indore',
      subtitle: 'Madhya Pradesh, India',
      center: const LatLng(22.7196, 75.8577),
      bbox: const LatLngBounds(south: 22.65, north: 22.80, west: 75.78, east: 75.94),
      state: PlaceDownloadState.downloaded,
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isSearch = _tab == SearchTab.search;
    final List<Place> rows = isSearch ? _searchResults : _downloadedResults;

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
              decoration: InputDecoration(
                hintText: isSearch ? 'Search any city or district' : 'Filter your downloads',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? const Center(
                    child: Text(
                      'No results',
                      style: TextStyle(color: Colors.black54),
                    ),
                  )
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final Place p = rows[index];
                      return ListTile(
                        title: Text(p.name),
                        subtitle: Text(p.subtitle),
                        trailing: _buildTrailing(p, isSearch),
                        onTap: () => Navigator.of(context).pop(p),
                      );
                    },
                  ),
          ),
        ],
      ),
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
