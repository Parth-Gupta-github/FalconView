import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'screens/landing_screen.dart';
import 'screens/map_screen.dart';
import 'services/subscription_service.dart';
import 'theme/tactical_theme.dart';

void main() {
  // Catch absolutely anything that bubbles up so a single bad future or
  // platform exception can't take the process down.
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // On Windows/Linux desktop, the sqflite plugin doesn't ship a native
      // implementation — we have to wire up the FFI variant explicitly.
      // No-op on Android/iOS (their native sqflite plugin handles itself).
      if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }

      // Widget-tree errors → log only, no red screen on release.
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.dumpErrorToConsole(details);
      };

      // Native engine errors (rendering, platform channels, etc.) → log only.
      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        debugPrint('Uncaught platform error: $error\n$stack');
        return true; // swallowed — don't escalate
      };

      try {
        if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
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
        }
      } catch (e, s) {
        debugPrint('System UI configuration failed: $e\n$s');
      }

      // Best-effort: if SharedPreferences chokes on first launch we still
      // boot with default tier instead of never reaching runApp.
      try {
        await subscriptionService.load();
      } catch (e, s) {
        debugPrint('subscriptionService.load failed: $e\n$s');
      }

      runApp(const FalconViewApp());
    },
    (Object error, StackTrace stack) {
      debugPrint('Uncaught zone error: $error\n$stack');
    },
  );
}

class FalconViewApp extends StatelessWidget {
  const FalconViewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FalconView',
      debugShowCheckedModeBanner: false,
      theme: buildFalconViewTheme(),
      // Web visitors land on the download/intro page first and tap through to
      // the in-browser map. Native builds (mobile/desktop) open the map
      // directly — there's nothing to download there.
      home: kIsWeb ? const LandingScreen() : const MapScreen(),
    );
  }
}
