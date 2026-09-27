/// Non-web platforms: no browser, so no user agent and no webdriver.
String userAgent() => '';
bool isWebdriver() => false;
String referrer() => '';
String deviceKind() => 'app';
void setPageHideHandler(void Function()? cb) {}
bool sendBeacon(String url, String body, [Map<String, String>? headers]) =>
    false;
