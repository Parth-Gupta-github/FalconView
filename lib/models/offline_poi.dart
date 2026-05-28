class OfflinePoi {
  final String osmType;   // 'node' | 'way' | 'relation'
  final int osmId;
  final String name;
  final String category;  // 'hospital', 'tourism:hotel', 'shop:supermarket', ...
  final double latitude;
  final double longitude;
  final String regionName;
  final int regionId;

  OfflinePoi({
    required this.osmType,
    required this.osmId,
    required this.name,
    required this.category,
    required this.latitude,
    required this.longitude,
    required this.regionName,
    required this.regionId,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    't': osmType,
    'i': osmId,
    'n': name,
    'c': category,
    'lat': latitude,
    'lng': longitude,
    'rn': regionName,
    'rid': regionId,
  };

  factory OfflinePoi.fromJson(Map<String, dynamic> json) => OfflinePoi(
    osmType: json['t'] as String,
    osmId: (json['i'] as num).toInt(),
    name: json['n'] as String,
    category: json['c'] as String,
    latitude: (json['lat'] as num).toDouble(),
    longitude: (json['lng'] as num).toDouble(),
    regionName: json['rn'] as String,
    regionId: (json['rid'] as num).toInt(),
  );
}
