import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_tier.dart';

/// Holds the user's current tier. Currently a local stub; swap for
/// in-app-purchase / RevenueCat / Razorpay later without touching callers.
class SubscriptionService extends ChangeNotifier {
  static const String _kTierKey = 'app_tier';

  AppTier _tier = AppTier.free;
  AppTier get tier => _tier;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? idx = prefs.getInt(_kTierKey);
      if (idx != null && idx >= 0 && idx < AppTier.values.length) {
        _tier = AppTier.values[idx];
        notifyListeners();
      }
    } catch (e, s) {
      debugPrint('SubscriptionService.load failed: $e\n$s');
    }
  }

  Future<void> setTier(AppTier tier) async {
    if (_tier == tier) return;
    _tier = tier;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kTierKey, tier.index);
    } catch (e, s) {
      debugPrint('SubscriptionService.setTier persist failed: $e\n$s');
    }
  }
}

/// Global singleton — keeps callers from having to thread a provider through.
/// (For a real app, swap to provider/riverpod; this matches the
/// flat-state style of the rest of the codebase.)
final SubscriptionService subscriptionService = SubscriptionService();
