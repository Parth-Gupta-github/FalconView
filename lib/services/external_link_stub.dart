// Non-web stub for [openExternal]. The landing page that calls it is only
// shown on web, so on mobile/desktop this is never invoked — but it must exist
// so the conditional export in `external_link.dart` resolves on every platform.
void openExternal(String url) {
  // No-op off the web.
}
