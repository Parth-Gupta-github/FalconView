// Web implementation for [openExternal]: opens [url] in a new browser tab.
//
// `dart:html` is the lightest way to do this with no extra dependency, and this
// file is only ever compiled into the web build (selected via the conditional
// import in `external_link.dart`), so the web-library lints don't apply.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

void openExternal(String url) {
  html.window.open(url, '_blank');
}
