import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/map_screen.dart';
import 'theme/tactical_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
  ));
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
