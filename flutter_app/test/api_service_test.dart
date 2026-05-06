import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tether/models/remote_host_status.dart';
import 'package:tether/services/api_service.dart';

void main() {
  test('listRemoteHosts parses remote host statuses', () async {
    final api = ApiService(
      baseUrl: 'http://tether.test',
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/remote/hosts');
        return http.Response(
          '[{"host":"osmo_9000","status":"ready","tunnel_port":49152}]',
          200,
        );
      }),
    );

    final statuses = await api.listRemoteHosts();

    expect(statuses, hasLength(1));
    expect(statuses.single.host, 'osmo_9000');
    expect(statuses.single.status, RemoteHostConnectionStatus.ready);
    expect(statuses.single.tunnelPort, 49152);
  });

  test(
    'connect deploy and restart post to single-host remote endpoints',
    () async {
      final seen = <http.Request>[];
      final api = ApiService(
        baseUrl: 'http://tether.test',
        client: MockClient((request) async {
          seen.add(request);
          return http.Response(
            '{"host":"osmo_9000","status":"connecting","tunnel_port":null}',
            200,
          );
        }),
      );

      await api.connectRemoteHost('osmo_9000');
      await api.deployRemoteHost('osmo_9000');
      await api.restartRemoteHost('osmo_9000');

      expect(seen.map((request) => request.method), ['POST', 'POST', 'POST']);
      expect(seen.map((request) => request.url.path), [
        '/api/remote/hosts/osmo_9000/connect',
        '/api/remote/hosts/osmo_9000/deploy',
        '/api/remote/hosts/osmo_9000/restart',
      ]);
    },
  );

  test('deployRemoteHost posts to the single-host deploy endpoint', () async {
    final seen = <http.Request>[];
    final api = ApiService(
      baseUrl: 'http://tether.test',
      client: MockClient((request) async {
        seen.add(request);
        return http.Response(
          '{"host":"osmo_9000","status":"ready","tunnel_port":49152}',
          200,
        );
      }),
    );

    final status = await api.deployRemoteHost('osmo_9000');

    expect(seen, hasLength(1));
    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/api/remote/hosts/osmo_9000/deploy');
    expect(status.status, RemoteHostConnectionStatus.ready);
  });
}
