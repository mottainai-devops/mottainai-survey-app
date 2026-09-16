const String _arcgisMobileApiKey = String.fromEnvironment('ARCGIS_MOBILE_API_KEY');

String arcgisMobileApiKey() {
  if (_arcgisMobileApiKey.trim().isEmpty) {
    throw StateError('ArcGIS mobile configuration is unavailable.');
  }
  return _arcgisMobileApiKey;
}
