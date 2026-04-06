import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/group.dart';
import 'package:tether/models/session.dart';
import 'package:tether/services/api_service.dart';
import 'package:tether/widgets/terminal/terminal_image_paste.dart';

void main() {
  Group makeGroup({String? sshHost}) =>
      Group(id: 'group-1', name: 'Group', sshHost: sshHost);

  Session makeSession({String? process}) => Session(
    id: 'session-1',
    groupId: 'group-1',
    name: 'Session',
    shell: '',
    cols: 80,
    rows: 24,
    cwd: '~',
    isAlive: true,
    createdAt: '',
    lastActive: '',
    foregroundProcess: process,
  );

  final image = ClipboardImagePayload(
    mimeType: 'image/png',
    data: Uint8List.fromList(const <int>[0, 1, 2, 3]),
  );

  group('image paste bridge gating', () {
    test('enables only for remote Codex and Claude sessions', () {
      expect(
        shouldEnableImagePasteBridge(
          session: makeSession(process: 'codex'),
          group: makeGroup(sshHost: 'devbox'),
        ),
        isTrue,
      );
      expect(
        shouldEnableImagePasteBridge(
          session: makeSession(process: 'claude'),
          group: makeGroup(sshHost: 'devbox'),
        ),
        isTrue,
      );
      expect(
        shouldEnableImagePasteBridge(
          session: makeSession(process: 'bash'),
          group: makeGroup(sshHost: 'devbox'),
        ),
        isFalse,
      );
      expect(
        shouldEnableImagePasteBridge(
          session: makeSession(process: 'codex'),
          group: makeGroup(),
        ),
        isFalse,
      );
    });
  });

  group('terminal image paste coordinator', () {
    test(
      'uploads a Codex image and injects a prompt with the remote path',
      () async {
        String? uploadedSessionId;
        String? uploadedMimeType;
        Uint8List? uploadedData;

        final coordinator = TerminalImagePasteCoordinator(
          upload: ({
            required String sessionId,
            required String mimeType,
            required Uint8List data,
          }) async {
            uploadedSessionId = sessionId;
            uploadedMimeType = mimeType;
            uploadedData = data;
            return const UploadedClipboardImage(
              remotePath: '/remote/.tether/clipboard/session-1/image.png',
              mimeType: 'image/png',
            );
          },
        );

        final outcome = await coordinator.handle(
          sessionId: 'session-1',
          session: makeSession(process: 'codex'),
          group: makeGroup(sshHost: 'devbox'),
          image: image,
        );

        expect(uploadedSessionId, 'session-1');
        expect(uploadedMimeType, 'image/png');
        expect(uploadedData, image.data);
        expect(
          outcome.injectedText,
          'Analyze this image: "/remote/.tether/clipboard/session-1/image.png" ',
        );
        expect(outcome.errorMessage, isNull);
      },
    );

    test(
      'maps remote host connecting errors to an inline user message',
      () async {
        final coordinator = TerminalImagePasteCoordinator(
          upload: ({
            required String sessionId,
            required String mimeType,
            required Uint8List data,
          }) async {
            throw ApiException(503, 'remote_host_connecting');
          },
        );

        final outcome = await coordinator.handle(
          sessionId: 'session-1',
          session: makeSession(process: 'claude'),
          group: makeGroup(sshHost: 'devbox'),
          image: image,
        );

        expect(outcome.injectedText, isNull);
        expect(outcome.errorMessage, 'Remote host connecting…');
      },
    );

    test('ignores local sessions', () async {
      final coordinator = TerminalImagePasteCoordinator(
        upload: ({
          required String sessionId,
          required String mimeType,
          required Uint8List data,
        }) async {
          fail('upload should not be called for local sessions');
        },
      );

      final outcome = await coordinator.handle(
        sessionId: 'session-1',
        session: makeSession(process: 'codex'),
        group: makeGroup(),
        image: image,
      );

      expect(outcome.injectedText, isNull);
      expect(outcome.errorMessage, isNull);
    });
  });
}
