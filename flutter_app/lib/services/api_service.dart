import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/group.dart';
import '../models/session.dart';
import '../models/ssh_host.dart';

class ApiService {
  final String baseUrl;
  final String? authToken;
  final http.Client _client;

  ApiService({required this.baseUrl, this.authToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (authToken != null && authToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }
    return headers;
  }

  Uri _uri(String path, [Map<String, String>? queryParams]) {
    return Uri.parse('$baseUrl$path').replace(queryParameters: queryParams);
  }

  Future<Map<String, dynamic>> getInfo() async {
    final response = await _client.get(_uri('/api/info'), headers: _headers);
    _checkResponse(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<Group>> listGroups() async {
    final response = await _client.get(_uri('/api/groups'), headers: _headers);
    _checkResponse(response);
    final list = jsonDecode(response.body) as List;
    return list.map((j) => Group.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<Group> createGroup({
    required String name,
    String? parentId,
    String? defaultCwd,
    String? sshHost,
  }) async {
    final body = <String, dynamic>{'name': name};
    if (parentId != null) body['parent_id'] = parentId;
    if (defaultCwd != null) body['default_cwd'] = defaultCwd;
    if (sshHost != null) body['ssh_host'] = sshHost;

    final response = await _client.post(
      _uri('/api/groups'),
      headers: _headers,
      body: jsonEncode(body),
    );
    _checkResponse(response);
    return Group.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> updateGroup(
    String id, {
    String? name,
    int? sortOrder,
    String? defaultCwd,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (sortOrder != null) body['sort_order'] = sortOrder;
    if (defaultCwd != null) body['default_cwd'] = defaultCwd;

    final response = await _client.patch(
      _uri('/api/groups/$id'),
      headers: _headers,
      body: jsonEncode(body),
    );
    _checkResponse(response);
  }

  Future<List<String>> completePath(String path) async {
    final response = await _client.get(
      _uri('/api/completions', {'path': path}),
      headers: _headers,
    );
    _checkResponse(response);
    final list = jsonDecode(response.body) as List;
    return list.cast<String>();
  }

  Future<List<String>> completeRemotePath(String host, String path) async {
    final response = await _client.get(
      _uri('/api/completions/remote', {'host': host, 'path': path}),
      headers: _headers,
    );
    _checkResponse(response);
    final list = jsonDecode(response.body) as List;
    return list.cast<String>();
  }

  Future<void> deleteGroup(String id) async {
    final response = await _client.delete(
      _uri('/api/groups/$id'),
      headers: _headers,
    );
    _checkResponse(response);
  }

  Future<void> reorderGroups(List<Map<String, dynamic>> items) async {
    final response = await _client.post(
      _uri('/api/groups/reorder'),
      headers: _headers,
      body: jsonEncode(items),
    );
    _checkResponse(response);
  }

  Future<List<Session>> listSessions() async {
    final response = await _client.get(
      _uri('/api/sessions'),
      headers: _headers,
    );
    _checkResponse(response);
    final list = jsonDecode(response.body) as List;
    return list
        .map((j) => Session.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  // local=true tells the server to store DB record only — no PTY spawn
  Future<Session> createSession({
    required String groupId,
    String? name,
    String? command,
    String? cwd,
    bool local = true,
  }) async {
    final body = <String, dynamic>{'group_id': groupId};
    if (name != null) body['name'] = name;
    if (command != null) body['command'] = command;
    if (cwd != null) body['cwd'] = cwd;

    final queryParams = local ? {'local': 'true'} : null;
    final response = await _client.post(
      _uri('/api/sessions', queryParams),
      headers: _headers,
      body: jsonEncode(body),
    );
    _checkResponse(response);
    return Session.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> updateSession(
    String id, {
    String? name,
    int? sortOrder,
    String? groupId,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (sortOrder != null) body['sort_order'] = sortOrder;
    if (groupId != null) body['group_id'] = groupId;

    final response = await _client.patch(
      _uri('/api/sessions/$id'),
      headers: _headers,
      body: jsonEncode(body),
    );
    _checkResponse(response);
  }

  Future<void> deleteSession(String id) async {
    final response = await _client.delete(
      _uri('/api/sessions/$id'),
      headers: _headers,
    );
    _checkResponse(response);
  }

  Future<void> reorderSessions(List<Map<String, dynamic>> items) async {
    final response = await _client.post(
      _uri('/api/sessions/reorder'),
      headers: _headers,
      body: jsonEncode(items),
    );
    _checkResponse(response);
  }

  Future<SessionAttentionState> ackSessionAttention(String id) async {
    final response = await _client.post(
      _uri('/api/sessions/$id/attention/ack'),
      headers: _headers,
    );
    _checkResponse(response);
    return SessionAttentionState.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<UploadedClipboardImage> uploadClipboardImage({
    required String sessionId,
    required String mimeType,
    required Uint8List data,
  }) async {
    final response = await _client.post(
      _uri('/api/sessions/$sessionId/clipboard-image'),
      headers: _headers,
      body: jsonEncode({
        'mime_type': mimeType,
        'data_base64': base64Encode(data),
      }),
    );
    _checkResponse(response);
    return UploadedClipboardImage.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<SshHost>> listSshHosts() async {
    await _applyTestListSshHostsDelay();
    final response = await _client.get(
      _uri('/api/ssh/hosts'),
      headers: _headers,
    );
    _checkResponse(response);
    final list = jsonDecode(response.body) as List;
    return list
        .map((j) => SshHost.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<void> deployRemoteHost(String host) async {
    final response = await _client.post(
      _uri('/api/remote/hosts/$host/deploy'),
      headers: _headers,
    );
    _checkResponse(response);
  }

  void _checkResponse(http.Response response) {
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode, response.body);
    }
  }

  void dispose() {
    _client.close();
  }

  Future<void> _applyTestListSshHostsDelay() async {
    final raw = Platform.environment['TETHER_TEST_LIST_SSH_HOSTS_DELAY_MS'];
    final milliseconds = int.tryParse(raw ?? '');
    if (milliseconds == null || milliseconds <= 0) {
      return;
    }
    await Future<void>.delayed(Duration(milliseconds: milliseconds));
  }
}

class SessionAttentionState {
  final int attentionSeq;
  final int attentionAckSeq;

  const SessionAttentionState({
    required this.attentionSeq,
    required this.attentionAckSeq,
  });

  factory SessionAttentionState.fromJson(Map<String, dynamic> json) {
    return SessionAttentionState(
      attentionSeq: json['attention_seq'] as int? ?? 0,
      attentionAckSeq: json['attention_ack_seq'] as int? ?? 0,
    );
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String body;

  ApiException(this.statusCode, this.body);

  @override
  String toString() => 'ApiException($statusCode): $body';
}

class UploadedClipboardImage {
  final String remotePath;
  final String mimeType;

  const UploadedClipboardImage({
    required this.remotePath,
    required this.mimeType,
  });

  factory UploadedClipboardImage.fromJson(Map<String, dynamic> json) {
    return UploadedClipboardImage(
      remotePath: json['remote_path'] as String,
      mimeType: json['mime_type'] as String,
    );
  }
}
