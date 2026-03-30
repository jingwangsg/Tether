class SshHost {
  final String host;
  final String? hostname;
  final String? user;
  final int? port;
  final String? identityFile;
  final bool? reachable;

  SshHost({
    required this.host,
    this.hostname,
    this.user,
    this.port,
    this.identityFile,
    this.reachable,
  });

  factory SshHost.fromJson(Map<String, dynamic> json) {
    return SshHost(
      host: json['host'] as String,
      hostname: json['hostname'] as String?,
      user: json['user'] as String?,
      port: json['port'] as int?,
      identityFile: json['identity_file'] as String?,
      reachable: json['reachable'] as bool?,
    );
  }

  String get displayString {
    final parts = <String>[];
    if (user != null) {
      parts.add('$user@');
    }
    parts.add(hostname ?? host);
    if (port != null && port != 22) {
      parts.add(':$port');
    }
    return parts.join();
  }
}
