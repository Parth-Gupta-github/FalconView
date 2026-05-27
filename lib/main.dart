import 'package:flutter/material.dart';

import 'screens/map_screen.dart';
import 'theme/tactical_theme.dart';

void main() {
  runApp(const FalconMapApp());
}

class FalconMapApp extends StatelessWidget {
  const FalconMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FalconMap',
      debugShowCheckedModeBanner: false,
      theme: buildFalconMapTheme(),
      home: const MapScreen(),
    );
  }
}
