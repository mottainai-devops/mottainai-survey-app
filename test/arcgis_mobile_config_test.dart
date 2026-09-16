import 'package:flutter_test/flutter_test.dart';
import 'package:mottainai_survey/config/arcgis_mobile_config.dart';

void main() {
  test('fails closed when the mobile ArcGIS build configuration is absent', () {
    expect(arcgisMobileApiKey, throwsA(isA<StateError>()));
  });
}
