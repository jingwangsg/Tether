import 'dart:typed_data';

import '../../models/group.dart';
import '../../models/session.dart';
import '../../services/api_service.dart';

typedef ClipboardImageUploader =
    Future<UploadedClipboardImage> Function({
      required String sessionId,
      required String mimeType,
      required Uint8List data,
    });

enum TerminalImagePasteTool { codex, claude }

class ClipboardImagePayload {
  final Uint8List data;
  final String mimeType;

  const ClipboardImagePayload({required this.data, required this.mimeType});
}

class TerminalImagePasteOutcome {
  final String? injectedText;
  final String? errorMessage;

  const TerminalImagePasteOutcome._({this.injectedText, this.errorMessage});

  const TerminalImagePasteOutcome.injected(String text)
    : this._(injectedText: text);

  const TerminalImagePasteOutcome.error(String message)
    : this._(errorMessage: message);

  const TerminalImagePasteOutcome.ignored() : this._();
}

TerminalImagePasteTool? imagePasteToolForSession(Session? session) {
  final process = session?.foregroundProcess?.trim().toLowerCase();
  switch (process) {
    case 'codex':
      return TerminalImagePasteTool.codex;
    case 'claude':
      return TerminalImagePasteTool.claude;
    default:
      return null;
  }
}

bool shouldEnableImagePasteBridge({
  required Session? session,
  required Group? group,
}) {
  return group?.isRemote == true && imagePasteToolForSession(session) != null;
}

class TerminalImagePasteCoordinator {
  final ClipboardImageUploader upload;

  const TerminalImagePasteCoordinator({required this.upload});

  Future<TerminalImagePasteOutcome> handle({
    required String sessionId,
    required Session? session,
    required Group? group,
    required ClipboardImagePayload image,
  }) async {
    final tool = imagePasteToolForSession(session);
    if (tool == null || group?.isRemote != true) {
      return const TerminalImagePasteOutcome.ignored();
    }

    try {
      final uploaded = await upload(
        sessionId: sessionId,
        mimeType: image.mimeType,
        data: image.data,
      );
      return TerminalImagePasteOutcome.injected(
        buildImagePastePrompt(tool, uploaded.remotePath),
      );
    } on ApiException catch (error) {
      if (error.statusCode == 503 &&
          error.body.trim() == 'remote_host_connecting') {
        return const TerminalImagePasteOutcome.error('Remote host connecting…');
      }

      final body = error.body.trim();
      if (body.isEmpty) {
        return TerminalImagePasteOutcome.error(
          'Image paste failed: HTTP ${error.statusCode}.',
        );
      }

      return TerminalImagePasteOutcome.error('Image paste failed: $body');
    } catch (error) {
      return TerminalImagePasteOutcome.error('Image paste failed: $error');
    }
  }
}

String buildImagePastePrompt(TerminalImagePasteTool tool, String remotePath) {
  final quotedPath = '"${remotePath.replaceAll('"', r'\"')}"';
  switch (tool) {
    case TerminalImagePasteTool.codex:
      return 'Analyze this image: $quotedPath ';
    case TerminalImagePasteTool.claude:
      return 'Analyze this image: $quotedPath ';
  }
}
