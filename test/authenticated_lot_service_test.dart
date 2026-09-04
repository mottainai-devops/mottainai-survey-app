import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mottainai_survey/services/lot_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('uses a Bearer session and removes caller-supplied user identity from lots.list', () async {
    late http.Request observed;
    final client = MockClient((request) async {
      observed = request;
      return http.Response(jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'lots': [
                  {
                    'lotCode': 'DAL-414',
                    'lotName': 'Lot 414',
                    'companyId': 'franchisee-one',
                    'companyName': 'Franchisee',
                  }
                ],
                'userRole': 'cherry_picker',
                'totalCount': 1,
                'message': 'authorized',
              }
            }
          }
        }
      ]), 200);
    });

    final service = LotService(client: client);
    final lots = await service.getLots('user-1', token: 'survey-jwt', forceRefresh: true);

    expect(lots, hasLength(1));
    expect(observed.headers['authorization'], 'Bearer survey-jwt');
    final encodedInput = observed.url.queryParameters['input']!;
    final payload = jsonDecode(Uri.decodeComponent(encodedInput)) as Map<String, dynamic>;
    expect((payload['0'] as Map<String, dynamic>)['json'], isNot(contains('userId')));
  });

  test('purges cached lots and does not return stale cross-scope data after an authorization failure', () async {
    SharedPreferences.setMockInitialValues({
      'cached_lots_version': '2',
      'cached_lots': jsonEncode({'userId': 'user-1', 'lots': []}),
      'cached_lots_timestamp': DateTime.now().millisecondsSinceEpoch,
      'cached_lots_user_id': 'user-1',
    });
    final service = LotService(client: MockClient((_) async => http.Response('denied', 401)));

    expect(
      () => service.getLots('user-1', token: 'expired', forceRefresh: true),
      throwsA(isA<LotAccessUnauthorizedException>()),
    );
  });

  test('invalidates a populated legacy cache before requesting the authenticated scope', () async {
    SharedPreferences.setMockInitialValues({
      'cached_lots_version': '1',
      'cached_lots': jsonEncode({
        'userId': 'user-1',
        'lots': [
          {'lotCode': 'LEGACY-001', 'lotName': 'Legacy lot', 'companyId': 'legacy-company'}
        ],
      }),
      'cached_lots_timestamp': DateTime.now().millisecondsSinceEpoch,
      'cached_lots_user_id': 'user-1',
    });
    var calls = 0;
    final service = LotService(client: MockClient((_) async {
      calls += 1;
      return http.Response(jsonEncode([
        {
          'result': {
            'data': {'json': {'lots': [], 'totalCount': 0}}
          }
        }
      ]), 200);
    }));

    final lots = await service.getLots('user-1', token: 'fresh-jwt');

    expect(calls, 1);
    expect(lots, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('cached_lots_version'), '2');
  });
}
