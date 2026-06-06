// Opens an external URL in a new browser tab/window.
//
// Uses a conditional import so the app compiles on every platform: the web
// build pulls in the `dart:html` implementation, every other build gets the
// no-op stub (the landing page that calls this is only ever shown on web).
export 'external_link_stub.dart'
    if (dart.library.html) 'external_link_web.dart';
