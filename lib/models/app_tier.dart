enum AppTier { free, pro }

extension AppTierX on AppTier {
  String get label {
    switch (this) {
      case AppTier.free:
        return 'Free';
      case AppTier.pro:
        return 'Pro';
    }
  }

  bool get hasOfflineGeocoding => this == AppTier.pro;
}
