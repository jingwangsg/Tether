class Group {
  final String id;
  final String name;
  final String? parentId;
  final int sortOrder;
  final String? defaultCwd;
  final String? sshHost;

  Group({
    required this.id,
    required this.name,
    this.parentId,
    this.sortOrder = 0,
    this.defaultCwd,
    this.sshHost,
  });

  factory Group.fromJson(Map<String, dynamic> json) {
    return Group(
      id: json['id'] as String,
      name: json['name'] as String,
      parentId: json['parent_id'] as String?,
      sortOrder: json['sort_order'] as int? ?? 0,
      defaultCwd: json['default_cwd'] as String?,
      sshHost: json['ssh_host'] as String?,
    );
  }

  Group copyWith({
    String? name,
    String? parentId,
    int? sortOrder,
    String? defaultCwd,
    String? sshHost,
    bool clearSshHost = false,
  }) {
    return Group(
      id: id,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      sortOrder: sortOrder ?? this.sortOrder,
      defaultCwd: defaultCwd ?? this.defaultCwd,
      sshHost: clearSshHost ? null : (sshHost ?? this.sshHost),
    );
  }
}
