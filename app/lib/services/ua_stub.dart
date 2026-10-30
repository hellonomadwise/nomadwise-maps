/// Non-web platforms: no browser, so no user agent and no webdriver.
String userAgent() => '';
bool isWebdriver() => false;
String referrer() => '';
String deviceKind() => 'app';
String timeZone() => '';
void setPageHideHandler(void Function()? cb) {}
bool sendBeacon(String url, String body, [Map<String, String>? headers]) =>
    false;

/// Off the web: the device setting reaches the app through MediaQuery.
bool prefersReducedMotion() => false;

/// Off the web: no browser history; the app's own back handles steps.
bool pushStep(int depth) => false;
void goHistory(int delta) {}
void setStepPopHandler(void Function(int? depth)? cb) {}
int? currentStep() => null;
