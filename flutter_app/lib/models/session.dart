class Session {
  final String id;
  final String groupId;
  final String name;
  final String shell;
  final int cols;
  final int rows;
  final String cwd;
  final bool isAlive;
  final String createdAt;
  final String lastActive;
  final int sortOrder;
  final String? foregroundProcess;
  final String? oscTitle;

  Session({
    required this.id,
    required this.groupId,
    required this.name,
    required this.shell,
    required this.cols,
    required this.rows,
    required this.cwd,
    required this.isAlive,
    required this.createdAt,
    required this.lastActive,
    this.sortOrder = 0,
    this.foregroundProcess,
    this.oscTitle,
  });

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      id: json['id'] as String,
      groupId: json['group_id'] as String,
      name: json['name'] as String,
      shell: json['shell'] as String? ?? '',
      cols: json['cols'] as int? ?? 80,
      rows: json['rows'] as int? ?? 24,
      cwd: json['cwd'] as String? ?? '',
      isAlive: json['is_alive'] as bool? ?? false,
      createdAt: json['created_at'] as String? ?? '',
      lastActive: json['last_active'] as String? ?? '',
      sortOrder: json['sort_order'] as int? ?? 0,
      foregroundProcess: json['foreground_process'] as String?,
      oscTitle: json['osc_title'] as String?,
    );
  }

  Session copyWith({
    String? name,
    String? groupId,
    bool? isAlive,
    int? sortOrder,
    String? foregroundProcess,
    String? oscTitle,
    bool clearForeground = false,
  }) {
    return Session(
      id: id,
      groupId: groupId ?? this.groupId,
      name: name ?? this.name,
      shell: shell,
      cols: cols,
      rows: rows,
      cwd: cwd,
      isAlive: isAlive ?? this.isAlive,
      createdAt: createdAt,
      lastActive: lastActive,
      sortOrder: sortOrder ?? this.sortOrder,
      foregroundProcess:
          clearForeground
              ? null
              : (foregroundProcess ?? this.foregroundProcess),
      oscTitle: clearForeground ? null : (oscTitle ?? this.oscTitle),
    );
  }
}
