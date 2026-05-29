import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_tier.dart';
import '../models/place.dart';
import '../services/nominatim_service.dart';
import '../services/offline_repository.dart';
import '../services/offline_search_index.dart';
import '../services/subscription_service.dart';
import '../util/tile_math.dart';
import 'plans_screen.dart';

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
  Map<int, PoiSource> _poiSourceByRegion = const <int, PoiSource>{};

  @override
  void initState() {
    super.initState();
    _refreshDownloaded();
    subscriptionService.addListener(_onTierChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _nominatim.dispose();
    subscriptionService.removeListener(_onTierChanged);
    super.dispose();
  }

  void _onTierChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _promptUpgrade() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Offline download is a Pro feature.'),
        duration: Duration(seconds: 3),
      ),
    );
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PlansScreen()),
    );
  }

  Future<void> _refreshDownloaded() async {
    if (!mounted) return;
    setState(() => _downloadedLoading = true);
    try {
      final List<Place> list = await _offline.listDownloaded();
      final Map<int, PoiSource> sources = <int, PoiSource>{};
      for (final Place p in list) {
        final int? id = p.regionId;
        if (id == null) continue;
        sources[id] = await _offline.poiSourceFor(id);
      }
      if (!mounted) return;
      setState(() {
        _downloadedResults = list;
        _poiSourceByRegion = sources;
        _downloadedLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _downloadedResults = const <Place>[];
        _poiSourceByRegion = const <int, PoiSource>{};
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
        _searchResults = _withCuratedAggregate(query, results);
        _loading = false;
      });
    } catch (_) {
      // Offline POI fallback only kicks in for Pro — Free users see the
      // plain network-failed message and can upgrade via the Plans screen.
      if (subscriptionService.tier == AppTier.pro) {
        final List<Place> cached = await _offline.searchOffline(query);
        if (!mounted || seq != _requestSeq) return;
        if (cached.isNotEmpty) {
          setState(() {
            _searchResults = cached;
            _loading = false;
            _error = null;
          });
          return;
        }
      }
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loading = false;
        _error = subscriptionService.tier == AppTier.pro
            ? 'Search failed and no offline matches in downloaded regions.'
            : 'Search failed. Check your connection.';
        _searchResults = const <Place>[];
      });
    }
  }

  Future<void> _onDownloadTap(Place place) async {
    setState(() {
      place.state = PlaceDownloadState.downloading;
      place.downloadProgress = 0;
    });
    try {
      await _offline.download(
        place,
        onProgress: (double pct) {
          if (!mounted) return;
          setState(() => place.downloadProgress = pct);
        },
      );
      if (!mounted) return;
      setState(() {
        place.state = PlaceDownloadState.downloaded;
        place.downloadProgress = 100;
      });
      await _refreshDownloaded();
      if (!mounted) return;
      final String? indexErr = _offline.lastIndexError;
      if (indexErr != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Search index not built: $indexErr'),
            duration: const Duration(seconds: 8),
          ),
        );
      } else {
        final PoiSource src = _offline.lastPoiSource;
        final IndexBuildStats? stats = _offline.lastIndexStats;
        final String tail = stats == null
            ? ''
            : ' (${stats.tilesScanned} tiles → ${stats.poisInserted} POIs)';
        final String origin = src == PoiSource.mvt
            ? 'POIs extracted from MBTiles$tail'
            : 'No POIs indexed for this region$tail';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${place.name}: $origin'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } on OfflineNotAvailable catch (e) {
      if (!mounted) return;
      setState(() {
        place.state = PlaceDownloadState.none;
        place.downloadProgress = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        place.state = PlaceDownloadState.none;
        place.downloadProgress = 0;
      });
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
        final int? id = p.regionId;
        final PoiSource? src = (!isSearch && id != null)
            ? _poiSourceByRegion[id]
            : null;
        // Only show size on the Search tab — Downloaded rows are already
        // on disk so the estimate is no longer actionable there.
        final String? sizeText = isSearch ? _sizeEstimate(p) : null;
        return ListTile(
          title: Row(
            children: <Widget>[
              Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
              if (src != null && src != PoiSource.none) ...<Widget>[
                const SizedBox(width: 8),
                _PoiSourceChip(source: src),
              ],
              if (sizeText != null) ...<Widget>[
                const SizedBox(width: 8),
                _SizeChip(text: sizeText),
              ],
            ],
          ),
          subtitle: Text(p.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: _buildTrailing(p, isSearch),
          onTap: () => Navigator.of(context).pop(p),
        );
      },
    );
  }

  Widget _buildTrailing(Place place, bool isSearch) {
    if (isSearch) {
      final bool isPro = subscriptionService.tier == AppTier.pro;
      switch (place.state) {
        case PlaceDownloadState.none:
          if (!isPro) {
            return IconButton(
              tooltip: 'Offline download is a Pro feature',
              icon: const Icon(Icons.lock_outline),
              onPressed: _promptUpgrade,
            );
          }
          return IconButton(
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _onDownloadTap(place),
          );
        case PlaceDownloadState.downloading:
          final double pct = place.downloadProgress.clamp(0, 100);
          return SizedBox(
            width: 36,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: pct > 0 ? pct / 100 : null,
                  strokeWidth: 2.5,
                ),
                Text(
                  '${pct.round()}%',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
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

  // Pin a synthetic whole-country Place on top of Nominatim's results when
  // the query is a country alias (currently only US). State/city rows from
  // Nominatim continue to appear below it; any Nominatim row that *is* the
  // same whole country is suppressed to avoid a visible duplicate.
  List<Place> _withCuratedAggregate(String query, List<Place> base) {
    final Place? curated = _curatedAggregateFor(query);
    if (curated == null) return base;
    final List<Place> filtered = base.where((Place p) {
      final String n = p.name.trim().toLowerCase();
      return n != 'united states' && n != 'united states of america';
    }).toList();
    return <Place>[curated, ...filtered];
  }

  static Place? _curatedAggregateFor(String query) {
    final String q = query.trim().toLowerCase();
    const Set<String> usAliases = <String>{
      'us',
      'usa',
      'u.s.',
      'u.s.a.',
      'united states',
      'united states of america',
    };
    if (usAliases.contains(q)) {
      // CONUS + Alaska + Hawaii. West edge clamped to -180 (Aleutians cross
      // the antimeridian; the sliver east of it is excluded by design to
      // keep the bbox a single rectangle).
      return Place(
        name: 'United States',
        subtitle: 'Whole-country offline pack (CONUS + Alaska + Hawaii)',
        center: const LatLng(39.5, -98.35),
        bbox: LatLngBounds(
          southwest: const LatLng(18.0, -180.0),
          northeast: const LatLng(72.0, -66.0),
        ),
      );
    }
    return null;
  }

  String _sizeEstimate(Place p) {
    return TileMath.estimatedDownloadSize(
      p.bbox.southwest.latitude,
      p.bbox.southwest.longitude,
      p.bbox.northeast.latitude,
      p.bbox.northeast.longitude,
    );
  }
}

class _SizeChip extends StatelessWidget {
  const _SizeChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.blueGrey.shade300.withValues(alpha: 0.6),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.sd_storage_outlined, size: 11, color: Colors.blueGrey.shade700),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(
              color: Colors.blueGrey.shade800,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _PoiSourceChip extends StatelessWidget {
  const _PoiSourceChip({required this.source});

  final PoiSource source;

  @override
  Widget build(BuildContext context) {
    final bool isMvt = source == PoiSource.mvt;
    final Color bg = isMvt ? Colors.green.shade50 : Colors.amber.shade50;
    final Color fg = isMvt ? Colors.green.shade800 : Colors.amber.shade900;
    final IconData icon =
        isMvt ? Icons.layers_outlined : Icons.cloud_download_outlined;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: fg.withValues(alpha: 0.4), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 3),
          Text(
            source.label,
            style: TextStyle(
              color: fg,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
