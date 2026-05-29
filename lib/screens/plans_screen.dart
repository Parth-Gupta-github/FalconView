import 'package:flutter/material.dart';

import '../models/app_tier.dart';
import '../services/subscription_service.dart';
import '../services/tile_config.dart';
import '../theme/tactical_theme.dart';
import 'payment_screen.dart';

class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key});

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  @override
  void initState() {
    super.initState();
    subscriptionService.addListener(_onTierChanged);
  }

  @override
  void dispose() {
    subscriptionService.removeListener(_onTierChanged);
    super.dispose();
  }

  void _onTierChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _selectTier(AppTier tier) async {
    // Free → Pro routes through the dev-mode payment page. Pro → Free is an
    // instant downgrade (no refund flow needed in dev). Same-tier taps are
    // already short-circuited by the tile's onTap guard.
    if (tier == AppTier.pro && subscriptionService.tier != AppTier.pro) {
      final bool? paid = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => const PaymentScreen(tier: AppTier.pro),
        ),
      );
      if (!mounted) return;
      if (paid == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Welcome to Pro — offline tools unlocked'),
          ),
        );
      }
      return;
    }
    await subscriptionService.setTier(tier);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${tier.label} plan enabled')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppTier current = subscriptionService.tier;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plans'),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _CurrentPlanBanner(tier: current),
          const SizedBox(height: 16),
          _PlanTile(
            tier: AppTier.free,
            current: current,
            title: 'Free',
            subtitle: 'Base map access for everyday testing.',
            features: const [
              'Offline map tiles up to zoom 14',
              'Interactive map zoom up to 16',
              'Online city and district search',
            ],
            onSelect: () => _selectTier(AppTier.free),
          ),
          const SizedBox(height: 12),
          _PlanTile(
            tier: AppTier.pro,
            current: current,
            title: 'Pro',
            subtitle: 'Offline tools and higher zoom limits.',
            features: const [
              'Offline map tiles up to zoom 16',
              'Interactive map zoom up to 22',
              'Offline POI search in downloaded regions',
            ],
            onSelect: () => _selectTier(AppTier.pro),
          ),
        ],
      ),
    );
  }
}

class _CurrentPlanBanner extends StatelessWidget {
  const _CurrentPlanBanner({required this.tier});

  final AppTier tier;

  @override
  Widget build(BuildContext context) {
    final bool isPro = tier == AppTier.pro;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isPro ? TacticalPalette.accentSoft : TacticalPalette.panel,
        border: Border.all(
          color: isPro ? TacticalPalette.accent : TacticalPalette.divider,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isPro ? Icons.workspace_premium : Icons.lock_open,
            color: TacticalPalette.accent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${tier.label} is active',
                  style: const TextStyle(
                    color: TacticalPalette.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'This is a local testing switch. Billing can replace it later.',
                  style: TextStyle(
                    color: TacticalPalette.textDim,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({
    required this.tier,
    required this.current,
    required this.title,
    required this.subtitle,
    required this.features,
    required this.onSelect,
  });

  final AppTier tier;
  final AppTier current;
  final String title;
  final String subtitle;
  final List<String> features;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final bool selected = tier == current;
    final TileConfig cfg = TileConfig.forTier(tier);
    return Material(
      color: TacticalPalette.panel,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: selected ? null : onSelect,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? TacticalPalette.accent : TacticalPalette.divider,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: TacticalPalette.textPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: TacticalPalette.textDim,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: selected
                        ? TacticalPalette.accent
                        : TacticalPalette.textDim,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricChip(label: 'Offline z${cfg.offlineMaxZoom.toInt()}'),
                  _MetricChip(label: 'Map z${cfg.interactiveMaxZoom.toInt()}'),
                ],
              ),
              const SizedBox(height: 14),
              for (final String feature in features) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.check,
                      size: 17,
                      color: TacticalPalette.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        feature,
                        style: const TextStyle(
                          color: TacticalPalette.textPrimary,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: selected ? null : onSelect,
                  icon: Icon(selected ? Icons.done : Icons.swap_horiz),
                  label: Text(selected ? 'Current plan' : 'Switch to $title'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: TacticalPalette.accentSoft,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: TacticalPalette.accent,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
