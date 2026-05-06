enum RemoteHostConnectionStatus {
  unreachable,
  connecting,
  ready,
  upgradeRequired,
  failed,
}

class RemoteHostStatus {
  final String host;
  final RemoteHostConnectionStatus status;
  final int? tunnelPort;
  final String? failureMessage;

  const RemoteHostStatus({
    required this.host,
    required this.status,
    this.tunnelPort,
    this.failureMessage,
  });

  factory RemoteHostStatus.fromJson(Map<String, dynamic> json) {
    final parsedStatus = _parseStatus(json['status']);
    return RemoteHostStatus(
      host: json['host'] as String,
      status: parsedStatus.status,
      tunnelPort: json['tunnel_port'] as int?,
      failureMessage: parsedStatus.failureMessage,
    );
  }

  String get label {
    return switch (status) {
      RemoteHostConnectionStatus.unreachable => 'Unreachable',
      RemoteHostConnectionStatus.connecting => 'Connecting',
      RemoteHostConnectionStatus.ready => 'Ready',
      RemoteHostConnectionStatus.upgradeRequired => 'Upgrade required',
      RemoteHostConnectionStatus.failed => 'Failed',
    };
  }

  bool get isConnectingOrReady =>
      status == RemoteHostConnectionStatus.connecting ||
      status == RemoteHostConnectionStatus.ready;
}

({RemoteHostConnectionStatus status, String? failureMessage}) _parseStatus(
  Object? value,
) {
  if (value is Map<String, dynamic> && value.containsKey('failed')) {
    return (
      status: RemoteHostConnectionStatus.failed,
      failureMessage: value['failed'] as String?,
    );
  }

  return (
    status: switch (value) {
      'connecting' => RemoteHostConnectionStatus.connecting,
      'ready' => RemoteHostConnectionStatus.ready,
      'upgrade_required' => RemoteHostConnectionStatus.upgradeRequired,
      'failed' => RemoteHostConnectionStatus.failed,
      _ => RemoteHostConnectionStatus.unreachable,
    },
    failureMessage: null,
  );
}
