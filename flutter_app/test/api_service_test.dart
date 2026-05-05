import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tether/services/api_service.dart';

void main() {
  test('deployRemoteHost posts to the single-host deploy endpoint', () async {
    final seen = <http.Request>[];
    final api = ApiService(
      baseUrl: 'http://tether.test',
      client: MockClient((request) async {
        seen.add(request);
        return http.Response('{}', 200);
      }),
    );

    await api.deployRemoteHost('osmo_9000');

    expect(seen, hasLength(1));
    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/api/remote/hosts/osmo_9000/deploy');
  });
}
