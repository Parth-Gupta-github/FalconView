import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/external_link.dart';
import 'map_screen.dart';

/// Web-only landing page shown before the browser map. It introduces
/// FalconView and offers per-platform download links plus a button that opens
/// the in-browser map. On non-web targets the app boots straight into
/// [MapScreen], so this screen is never reached there.
///
/// The visual identity is taken from the app icon — an origami falcon folded
/// from a paper map — so the page uses that artwork's forest-green / cream /
/// burnt-orange palette and a topographic-contour backdrop.
class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});

  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> {
  // ---- Download links -------------------------------------------------------
  // Point these at the real release artifacts when they're published. Until
  // then they open the repository's Releases page, which is a sensible default.
  static const String _releasesUrl =
      'https://github.com/Parth-Gupta-github/FalconView/releases/latest';
  static const String _githubUrl =
      'https://github.com/Parth-Gupta-github/FalconView';
  static const String _pressKitUrl =
      'https://github.com/Parth-Gupta-github/FalconView/tree/main/assets';
  static const String _androidUrl = _releasesUrl;
  static const String _windowsUrl = _releasesUrl;
  static const String _macosUrl = _releasesUrl;
  static const String _iosUrl = _releasesUrl;

  final ScrollController _scroll = ScrollController();
  final GlobalKey _downloadKey = GlobalKey();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToDownloads() {
    final BuildContext? ctx = _downloadKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOutCubic,
      alignment: 0.05,
    );
  }

  void _openMap() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const MapScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Brand.greenDeep,
      body: Stack(
        children: <Widget>[
          // Topographic contour texture behind everything.
          const Positioned.fill(child: CustomPaint(painter: _TopoPainter())),
          // Soft warm glow bleeding in from the top.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.75, -1.1),
                  radius: 1.3,
                  colors: <Color>[
                    _Brand.orange.withValues(alpha: 0.16),
                    _Brand.greenDeep.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 28,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          const _TopBar(),
                          const SizedBox(height: 36),
                          _Hero(
                            onLaunch: _openMap,
                            onGetApp: _scrollToDownloads,
                          ),
                          const SizedBox(height: 96),
                          const _SectionLabel('WHAT IT DOES'),
                          const SizedBox(height: 28),
                          const _FeatureGrid(),
                          const SizedBox(height: 96),
                          const _SectionLabel('SEE IT IN ACTION'),
                          const SizedBox(height: 28),
                          const _DemoCarousel(),
                          const SizedBox(height: 96),
                          _SectionLabel('GET FALCONVIEW', key: _downloadKey),
                          const SizedBox(height: 10),
                          Text(
                            'One map experience, every device.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _Brand.cream,
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 28),
                          const _DownloadGrid(
                            android: _androidUrl,
                            windows: _windowsUrl,
                            macos: _macosUrl,
                            ios: _iosUrl,
                          ),
                          const SizedBox(height: 22),
                          _GithubCta(
                            onStar: () => openExternal(_githubUrl),
                            onDemo: _openMap,
                          ),
                          const SizedBox(height: 72),
                          const _WhatsNew(),
                          const SizedBox(height: 72),
                          const _FaqSection(),
                          const SizedBox(height: 72),
                          const _PressKit(url: _pressKitUrl),
                          const SizedBox(height: 72),
                          const _Footer(),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Brand palette — sampled from assets/icon/icon.png.
// ===========================================================================
class _Brand {
  const _Brand._();

  static const Color greenDeep = Color(0xFF233A2C);
  static const Color greenDark = Color(0xFF18271E);
  static const Color greenPanel = Color(0xFF2E4838);
  static const Color cream = Color(0xFFECE4CC);
  static const Color creamDim = Color(0xFFA9B19E);
  static const Color orange = Color(0xFFE2611F);
  static const Color orangeBright = Color(0xFFF47A33);
}

// ===========================================================================
// Top bar — wordmark + a small "open map" affordance.
// ===========================================================================
class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const _IconTile(size: 40, radius: 12),
        const SizedBox(width: 12),
        Text(
          'FalconView',
          style: TextStyle(
            color: _Brand.cream,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        const Spacer(),
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: _Brand.orange,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'Offline-ready',
          style: TextStyle(
            color: _Brand.creamDim,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// Hero — headline + CTAs on the left, the falcon mark on the right. Stacks on
// narrow viewports.
// ===========================================================================
class _Hero extends StatelessWidget {
  const _Hero({required this.onLaunch, required this.onGetApp});

  final VoidCallback onLaunch;
  final VoidCallback onGetApp;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth >= 860;
        final Widget text = _HeroCopy(
          onLaunch: onLaunch,
          onGetApp: onGetApp,
          centered: !wide,
        );
        final Widget art = _HeroArt(big: wide);
        if (!wide) {
          return Column(
            children: <Widget>[art, const SizedBox(height: 40), text],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(flex: 6, child: text),
            const SizedBox(width: 48),
            Expanded(flex: 5, child: art),
          ],
        );
      },
    );
  }
}

class _HeroCopy extends StatelessWidget {
  const _HeroCopy({
    required this.onLaunch,
    required this.onGetApp,
    required this.centered,
  });

  final VoidCallback onLaunch;
  final VoidCallback onGetApp;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final CrossAxisAlignment cross = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final TextAlign align = centered ? TextAlign.center : TextAlign.start;
    return Column(
      crossAxisAlignment: cross,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _Brand.orange.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: _Brand.orange.withValues(alpha: 0.45)),
          ),
          child: Text(
            'TACTICAL MAPPING, OFF THE GRID',
            style: TextStyle(
              color: _Brand.orangeBright,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 22),
        Text(
          'The map that\nworks anywhere.',
          textAlign: align,
          style: TextStyle(
            color: _Brand.cream,
            fontSize: 52,
            height: 1.05,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.5,
          ),
        ),
        const SizedBox(height: 20),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(
            'FalconView is an offline-first mapping tool for the field. Drop '
            'marks, record tracks, measure distance and area, and search — '
            'with a basemap that keeps rendering even when the signal drops.',
            textAlign: align,
            style: TextStyle(
              color: _Brand.creamDim,
              fontSize: 16.5,
              height: 1.55,
            ),
          ),
        ),
        const SizedBox(height: 32),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          alignment: centered ? WrapAlignment.center : WrapAlignment.start,
          children: <Widget>[
            _PrimaryButton(
              label: 'Launch web map',
              icon: Icons.travel_explore_rounded,
              onTap: onLaunch,
            ),
            _GhostButton(
              label: 'Get the app',
              icon: Icons.south_rounded,
              onTap: onGetApp,
            ),
          ],
        ),
      ],
    );
  }
}

class _HeroArt extends StatelessWidget {
  const _HeroArt({required this.big});

  final bool big;

  @override
  Widget build(BuildContext context) {
    final double size = big ? 360 : 240;
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Halo behind the mark.
          Container(
            width: size * 1.04,
            height: size * 1.04,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: <Color>[
                  _Brand.orange.withValues(alpha: 0.22),
                  _Brand.orange.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
          _IconTile(size: size, radius: size * 0.22, glow: true),
        ],
      ),
    );
  }
}

// ===========================================================================
// The app icon, presented as a rounded "app tile" with depth.
// ===========================================================================
class _IconTile extends StatelessWidget {
  const _IconTile({
    required this.size,
    required this.radius,
    this.glow = false,
  });

  final double size;
  final double radius;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: glow ? 0.45 : 0.30),
            blurRadius: glow ? 48 : 12,
            offset: Offset(0, glow ? 24 : 6),
          ),
        ],
        border: Border.all(
          color: _Brand.cream.withValues(alpha: 0.10),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/icon/icon.png',
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

// ===========================================================================
// Feature highlights — the app's real toolset.
// ===========================================================================
class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid();

  static const List<_Feature> _features = <_Feature>[
    _Feature(
      icon: Icons.wifi_off_rounded,
      title: 'Works offline',
      body:
          'A bundled vector basemap plus on-device search and routing keep '
          'you oriented with zero signal.',
    ),
    _Feature(
      icon: Icons.place_rounded,
      title: 'Field tools',
      body:
          'Mark waypoints, record a live track, measure distance with the '
          'ruler, and outline an area — fast.',
    ),
    _Feature(
      icon: Icons.devices_rounded,
      title: 'Every platform',
      body:
          'One experience across Windows, macOS, Android, iOS and the web — '
          'rendered identically everywhere.',
    ),
    _Feature(
      icon: Icons.bolt_rounded,
      title: 'GPU-fast tiles',
      body:
          'Vector tiles drawn on the GPU mean buttery pan and zoom, whether '
          'you are online or fully offline.',
    ),
    _Feature(
      icon: Icons.search_rounded,
      title: 'Search & navigate',
      body:
          'Find any city, district or POI and route to it — with results '
          'served from your offline regions too.',
    ),
    _Feature(
      icon: Icons.satellite_alt_rounded,
      title: 'Satellite & terrain',
      body:
          'Switch the basemap to high-resolution satellite imagery whenever '
          'you need the real picture.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 18,
      runSpacing: 18,
      alignment: WrapAlignment.center,
      children: <Widget>[
        for (final _Feature f in _features) _FeatureCard(feature: f),
      ],
    );
  }
}

class _Feature {
  const _Feature({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.feature});

  final _Feature feature;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _Brand.greenPanel.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _Brand.cream.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: _Brand.orange.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(feature.icon, color: _Brand.orangeBright, size: 24),
          ),
          const SizedBox(height: 18),
          Text(
            feature.title,
            style: TextStyle(
              color: _Brand.cream,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            feature.body,
            style: TextStyle(color: _Brand.creamDim, fontSize: 14, height: 1.5),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Download section.
// ===========================================================================
class _DownloadGrid extends StatelessWidget {
  const _DownloadGrid({
    required this.android,
    required this.windows,
    required this.macos,
    required this.ios,
  });

  final String android;
  final String windows;
  final String macos;
  final String ios;

  @override
  Widget build(BuildContext context) {
    final List<_Download> items = <_Download>[
      _Download(
        label: 'Windows',
        sublabel: 'Desktop installer',
        requirement: 'Windows 10+',
        size: '15 MB',
        icon: Icons.desktop_windows_rounded,
        url: windows,
      ),
      _Download(
        label: 'macOS',
        sublabel: 'Apple silicon & Intel',
        requirement: 'macOS 11+',
        size: '34 MB',
        icon: Icons.laptop_mac_rounded,
        url: macos,
      ),
      _Download(
        label: 'Android',
        sublabel: 'APK / Play Store',
        requirement: 'Android 6+',
        size: '102 MB',
        icon: Icons.android_rounded,
        url: android,
      ),
      _Download(
        label: 'iOS',
        sublabel: 'iPhone & iPad',
        requirement: 'iOS 14+',
        size: '25 MB',
        icon: Icons.phone_iphone_rounded,
        url: ios,
      ),
    ];
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      alignment: WrapAlignment.center,
      children: <Widget>[
        for (final _Download d in items)
          _DownloadCard(item: d, onTap: () => openExternal(d.url)),
      ],
    );
  }
}

class _Download {
  const _Download({
    required this.label,
    required this.sublabel,
    required this.requirement,
    required this.size,
    required this.icon,
    required this.url,
  });

  final String label;
  final String sublabel;
  final String requirement;
  final String size;
  final IconData icon;
  final String url;
}

class _DownloadCard extends StatefulWidget {
  const _DownloadCard({required this.item, required this.onTap});

  final _Download item;
  final VoidCallback onTap;

  @override
  State<_DownloadCard> createState() => _DownloadCardState();
}

class _DownloadCardState extends State<_DownloadCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          width: 200,
          transform: Matrix4.translationValues(0.0, _hover ? -4.0 : 0.0, 0.0),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _hover ? _Brand.cream : _Brand.cream.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(18),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: _hover ? 0.35 : 0.22),
                blurRadius: _hover ? 28 : 14,
                offset: Offset(0, _hover ? 14 : 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(widget.item.icon, color: _Brand.greenDeep, size: 30),
                  const Spacer(),
                  Icon(
                    Icons.arrow_outward_rounded,
                    color: _hover ? _Brand.orange : _Brand.greenDeep,
                    size: 20,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                widget.item.label,
                style: const TextStyle(
                  color: _Brand.greenDark,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                widget.item.sublabel,
                style: TextStyle(
                  color: _Brand.greenDeep.withValues(alpha: 0.7),
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                widget.item.requirement,
                style: TextStyle(
                  color: _Brand.greenDark.withValues(alpha: 0.78),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 130),
                child: _hover
                    ? Padding(
                        key: const ValueKey<String>('size'),
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: <Widget>[
                            const Icon(
                              Icons.sd_card_rounded,
                              color: _Brand.orange,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              widget.item.size,
                              style: const TextStyle(
                                color: _Brand.orange,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(
                        key: ValueKey<String>('empty'),
                        height: 24,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _Brand.orange.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: _Brand.orange.withValues(alpha: 0.30)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: _Brand.orangeBright, size: 14),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: _Brand.orangeBright,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Product preview carousel.
// ===========================================================================
class _DemoCarousel extends StatefulWidget {
  const _DemoCarousel();

  @override
  State<_DemoCarousel> createState() => _DemoCarouselState();
}

class _DemoCarouselState extends State<_DemoCarousel> {
  int _index = 0;

  static const List<_DemoSlide> _slides = <_DemoSlide>[
    _DemoSlide(
      icon: Icons.travel_explore_rounded,
      title: 'Browse the world map',
      body:
          'Pan, zoom, switch layers and keep the basemap responsive on web or desktop.',
    ),
    _DemoSlide(
      icon: Icons.edit_location_alt_rounded,
      title: 'Mark and measure in the field',
      body:
          'Drop waypoints, draw routes, measure distance and outline areas without leaving the map.',
    ),
    _DemoSlide(
      icon: Icons.cloud_download_rounded,
      title: 'Take regions offline',
      body:
          'Pick a city or draw a polygon, then keep tiles, search and routing ready for no-signal work.',
    ),
  ];

  void _move(int delta) {
    setState(() => _index = (_index + delta) % _slides.length);
  }

  @override
  Widget build(BuildContext context) {
    final _DemoSlide slide = _slides[_index];
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: _Brand.greenPanel.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _Brand.cream.withValues(alpha: 0.09)),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final bool wide = c.maxWidth >= 760;
          final Widget preview = _DemoPreview(slide: slide);
          final Widget copy = _DemoCopy(
            slide: slide,
            index: _index,
            count: _slides.length,
            onPrev: () => _move(-1),
            onNext: () => _move(1),
            onSelect: (int i) => setState(() => _index = i),
          );
          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[preview, const SizedBox(height: 18), copy],
            );
          }
          return Row(
            children: <Widget>[
              Expanded(flex: 6, child: preview),
              const SizedBox(width: 26),
              Expanded(flex: 4, child: copy),
            ],
          );
        },
      ),
    );
  }
}

class _DemoSlide {
  const _DemoSlide({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;
}

class _DemoPreview extends StatelessWidget {
  const _DemoPreview({required this.slide});

  final _DemoSlide slide;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        decoration: BoxDecoration(
          color: _Brand.greenDark,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _Brand.cream.withValues(alpha: 0.10)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: <Widget>[
            const Positioned.fill(
              child: CustomPaint(painter: _MiniMapPainter()),
            ),
            Positioned(
              left: 22,
              bottom: 22,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _Brand.greenDeep.withValues(alpha: 0.84),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _Brand.cream.withValues(alpha: 0.12),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(slide.icon, color: _Brand.orangeBright, size: 22),
                    const SizedBox(width: 10),
                    Text(
                      'FalconView live preview',
                      style: TextStyle(
                        color: _Brand.cream,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DemoCopy extends StatelessWidget {
  const _DemoCopy({
    required this.slide,
    required this.index,
    required this.count,
    required this.onPrev,
    required this.onNext,
    required this.onSelect,
  });

  final _DemoSlide slide;
  final int index;
  final int count;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Chip(label: 'See it in action', icon: Icons.play_circle_fill_rounded),
        const SizedBox(height: 18),
        Text(
          slide.title,
          style: TextStyle(
            color: _Brand.cream,
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          slide.body,
          style: TextStyle(color: _Brand.creamDim, fontSize: 15, height: 1.55),
        ),
        const SizedBox(height: 24),
        Row(
          children: <Widget>[
            _RoundIconButton(icon: Icons.chevron_left_rounded, onTap: onPrev),
            const SizedBox(width: 10),
            _RoundIconButton(icon: Icons.chevron_right_rounded, onTap: onNext),
            const Spacer(),
            for (int i = 0; i < count; i++)
              Padding(
                padding: const EdgeInsets.only(left: 7),
                child: GestureDetector(
                  onTap: () => onSelect(i),
                  child: Container(
                    width: i == index ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == index
                          ? _Brand.orange
                          : _Brand.cream.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _GithubCta extends StatelessWidget {
  const _GithubCta({required this.onStar, required this.onDemo});

  final VoidCallback onStar;
  final VoidCallback onDemo;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 14,
      runSpacing: 12,
      children: <Widget>[
        _GhostButton(
          label: 'Star on GitHub',
          icon: Icons.star_rounded,
          onTap: onStar,
        ),
        _PrimaryButton(
          label: 'Try in browser',
          icon: Icons.public_rounded,
          onTap: onDemo,
        ),
      ],
    );
  }
}

class _WhatsNew extends StatelessWidget {
  const _WhatsNew();

  @override
  Widget build(BuildContext context) {
    return _SectionPanel(
      label: "WHAT'S NEW IN 1.0",
      child: _DarkExpansionTile(
        title: "What's new in 1.0",
        subtitle: 'A quick mini changelog for the first public build.',
        children: const <Widget>[
          _Bullet('Offline vector basemap bundled for first-run use.'),
          _Bullet('Waypoint, track, distance and area tools on one map.'),
          _Bullet('Search, routing, satellite view and Pro offline regions.'),
        ],
      ),
    );
  }
}

class _FaqSection extends StatelessWidget {
  const _FaqSection();

  static const List<_Faq> _items = <_Faq>[
    _Faq(
      'Is it free?',
      'Yes. FalconView has a free tier for core mapping tools, with Pro reserved for heavier offline workflows.',
    ),
    _Faq(
      'Do you collect data?',
      'FalconView is designed to work locally first. The app does not need personal data for offline map use.',
    ),
    _Faq(
      'Why unsigned?',
      'Early macOS and iOS builds may not be notarized or signed yet, so Apple can show a security warning before launch.',
    ),
    _Faq(
      'What is the difference between Pro and Free?',
      'Free covers the everyday map experience. Pro unlocks advanced offline region downloads and related field features.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return _SectionPanel(
      label: 'FAQ',
      child: Column(
        children: <Widget>[
          for (final _Faq item in _items)
            _DarkExpansionTile(
              title: item.question,
              children: <Widget>[_Answer(item.answer)],
            ),
        ],
      ),
    );
  }
}

class _Faq {
  const _Faq(this.question, this.answer);
  final String question;
  final String answer;
}

class _PressKit extends StatelessWidget {
  const _PressKit({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return _SectionPanel(
      label: 'PRESS KIT',
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: _Brand.greenPanel.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _Brand.cream.withValues(alpha: 0.09)),
        ),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 18,
          runSpacing: 18,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Brand assets for future coverage',
                    style: TextStyle(
                      color: _Brand.cream,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'App icon, screenshots, attribution notes and release links in one place.',
                    style: TextStyle(color: _Brand.creamDim, fontSize: 14.5),
                  ),
                ],
              ),
            ),
            _GhostButton(
              label: 'Open press kit',
              icon: Icons.folder_open_rounded,
              onTap: () => openExternal(url),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionPanel extends StatelessWidget {
  const _SectionPanel({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SectionLabel(label),
        const SizedBox(height: 24),
        child,
      ],
    );
  }
}

class _DarkExpansionTile extends StatelessWidget {
  const _DarkExpansionTile({
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final List<Widget> children;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        collapsedIconColor: _Brand.creamDim,
        iconColor: _Brand.orangeBright,
        tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        title: Text(
          title,
          style: TextStyle(
            color: _Brand.cream,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  subtitle!,
                  style: TextStyle(color: _Brand.creamDim, fontSize: 13.5),
                ),
              ),
        children: children,
      ),
    );
  }
}

class _Answer extends StatelessWidget {
  const _Answer(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(color: _Brand.creamDim, fontSize: 14, height: 1.5),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.check_circle_rounded,
            color: _Brand.orange,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: _Brand.creamDim,
                fontSize: 14,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon),
      color: _Brand.cream,
      style: IconButton.styleFrom(
        backgroundColor: _Brand.cream.withValues(alpha: 0.10),
        hoverColor: _Brand.orange.withValues(alpha: 0.24),
      ),
    );
  }
}

// ===========================================================================
// Shared bits.
// ===========================================================================
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Container(width: 28, height: 2, color: _Brand.orange),
        const SizedBox(width: 12),
        Text(
          text,
          style: TextStyle(
            color: _Brand.orangeBright,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(width: 12),
        Container(width: 28, height: 2, color: _Brand.orange),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: _Brand.orange,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 18),
        textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 0,
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: _Brand.cream,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
        side: BorderSide(color: _Brand.cream.withValues(alpha: 0.30)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Divider(color: _Brand.cream.withValues(alpha: 0.10)),
        const SizedBox(height: 20),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: <Widget>[
            const _IconTile(size: 26, radius: 8),
            Text(
              'FalconView',
              style: TextStyle(
                color: _Brand.cream,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            Text(
              '· Built by Parv Tiwari & Parth Gupta',
              style: TextStyle(color: _Brand.creamDim, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '© OpenStreetMap contributors · OpenMapTiles',
          style: TextStyle(
            color: _Brand.creamDim.withValues(alpha: 0.7),
            fontSize: 11.5,
          ),
        ),
      ],
    );
  }
}

class _MiniMapPainter extends CustomPainter {
  const _MiniMapPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF203529), Color(0xFF314D3A)],
        ).createShader(rect),
    );

    final Paint grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _Brand.cream.withValues(alpha: 0.055);
    for (double x = -size.width; x < size.width * 1.4; x += 46) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), grid);
    }
    for (double y = 20; y < size.height; y += 42) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y - 28), grid);
    }

    final Paint route = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = _Brand.orangeBright;
    final Path path = Path()
      ..moveTo(size.width * 0.16, size.height * 0.70)
      ..cubicTo(
        size.width * 0.30,
        size.height * 0.48,
        size.width * 0.48,
        size.height * 0.78,
        size.width * 0.62,
        size.height * 0.44,
      )
      ..cubicTo(
        size.width * 0.70,
        size.height * 0.24,
        size.width * 0.82,
        size.height * 0.34,
        size.width * 0.88,
        size.height * 0.20,
      );
    canvas.drawPath(path, route);

    final Paint pin = Paint()..color = _Brand.cream;
    for (final Offset p in <Offset>[
      Offset(size.width * 0.16, size.height * 0.70),
      Offset(size.width * 0.62, size.height * 0.44),
      Offset(size.width * 0.88, size.height * 0.20),
    ]) {
      canvas.drawCircle(p, 9, Paint()..color = _Brand.orange);
      canvas.drawCircle(p, 4, pin);
    }
  }

  @override
  bool shouldRepaint(covariant _MiniMapPainter oldDelegate) => false;
}

// ===========================================================================
// Topographic-contour backdrop — concentric, slightly irregular rings that
// evoke an elevation map. Drawn at very low opacity so text stays crisp.
// ===========================================================================
class _TopoPainter extends CustomPainter {
  const _TopoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Vertical depth gradient first.
    final Rect rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[_Brand.greenDeep, _Brand.greenDark],
        ).createShader(rect),
    );

    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = _Brand.cream.withValues(alpha: 0.05);

    // Two contour "basins": one off the top-right, one off the bottom-left.
    _contours(canvas, Offset(size.width * 0.86, size.height * 0.08), 14, line);
    _contours(canvas, Offset(size.width * 0.08, size.height * 0.92), 12, line);
  }

  void _contours(Canvas canvas, Offset center, int rings, Paint paint) {
    for (int i = 1; i <= rings; i++) {
      final double r = i * 46.0;
      final Path path = Path();
      const int steps = 60;
      for (int s = 0; s <= steps; s++) {
        final double t = (s / steps) * math.pi * 2;
        // A little per-ring wobble so the rings read as terrain, not targets.
        final double wob = 1 + 0.06 * math.sin(t * 3 + i * 0.7);
        final double x = center.dx + math.cos(t) * r * wob;
        final double y = center.dy + math.sin(t) * r * wob * 0.82;
        if (s == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TopoPainter oldDelegate) => false;
}
