import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/group.dart';
import '../../models/ssh_host.dart';
import '../../providers/server_provider.dart';
import '../../services/api_service.dart';

final groupDialogServerStateProvider = Provider<ServerState>((ref) {
  return ref.watch(serverProvider);
});

class GroupDialog extends ConsumerStatefulWidget {
  final Group? group;

  const GroupDialog({super.key, this.group});

  @override
  ConsumerState<GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends ConsumerState<GroupDialog> {
  static const _completionPopupMaxHeight = 150.0;
  late final TextEditingController _nameController;
  late final TextEditingController _pathController;
  String? _selectedSshHost;
  List<String> _completions = [];
  List<GlobalKey> _completionItemKeys = [];
  final ScrollController _completionScrollController = ScrollController();
  Timer? _debounce;
  bool _showCompletions = false;
  bool _isSaving = false;
  int _highlightedCompletionIndex = -1;
  int _completionRequestId = 0;
  String? _completionStatusMessage;
  bool _completionStatusIsError = false;
  String? _nameError;

  bool get _isEdit => widget.group != null;
  bool get _lockHostSelection => _isEdit;
  bool get _completionShortcutsEnabled =>
      _showCompletions && _completions.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.group?.name ?? '');
    _pathController = TextEditingController(
      text: widget.group?.defaultCwd ?? '~/',
    );
    _selectedSshHost = widget.group?.sshHost;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchCompletions(_pathController.text);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _completionScrollController.dispose();
    _nameController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  SshHost? _selectedHostState(ServerState serverState) {
    final selectedHost = _selectedSshHost;
    if (selectedHost == null) return null;
    for (final host in serverState.sshHosts) {
      if (host.host == selectedHost) return host;
    }
    return null;
  }

  List<SshHost> _hostOptions(ServerState serverState) {
    final reachableHosts =
        serverState.sshHosts.where((host) => host.reachable == true).toList();
    if (!_isEdit) return reachableHosts;

    final selectedHost = _selectedHostState(serverState);
    if (selectedHost != null) {
      return [
        selectedHost,
        ...reachableHosts.where((host) => host.host != selectedHost.host),
      ];
    }

    final selectedHostAlias = _selectedSshHost;
    if (selectedHostAlias == null) return reachableHosts;

    return [
      SshHost(host: selectedHostAlias),
      ...reachableHosts.where((host) => host.host != selectedHostAlias),
    ];
  }

  void _setCompletionState({
    required List<String> completions,
    required bool showCompletions,
    String? statusMessage,
    bool statusIsError = false,
    int highlightedIndex = -1,
  }) {
    setState(() {
      _completions = completions;
      _completionItemKeys = List.generate(
        completions.length,
        (_) => GlobalKey(),
      );
      _showCompletions = showCompletions;
      _completionStatusMessage = statusMessage;
      _completionStatusIsError = statusIsError;
      _highlightedCompletionIndex =
          completions.isEmpty
              ? -1
              : highlightedIndex.clamp(0, completions.length - 1).toInt();
    });
  }

  void _onPathChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _fetchCompletions(_pathController.text);
    });
  }

  void _moveHighlightedCompletion(int delta) {
    if (!_completionShortcutsEnabled) return;
    final nextIndex =
        (_highlightedCompletionIndex + delta)
            .clamp(0, _completions.length - 1)
            .toInt();
    if (nextIndex == _highlightedCompletionIndex) return;

    setState(() {
      _highlightedCompletionIndex = nextIndex;
    });
    _ensureHighlightedCompletionVisible();
  }

  void _ensureHighlightedCompletionVisible() {
    final index = _highlightedCompletionIndex;
    if (index < 0 || index >= _completionItemKeys.length) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final itemContext = _completionItemKeys[index].currentContext;
      if (itemContext == null) return;
      Scrollable.ensureVisible(
        itemContext,
        duration: Duration.zero,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  Future<void> _fetchCompletions(String text) async {
    final requestId = ++_completionRequestId;
    if (text.isEmpty) {
      _setCompletionState(completions: const [], showCompletions: false);
      return;
    }

    final serverState = ref.read(groupDialogServerStateProvider);
    final api = serverState.api;
    if (api == null) {
      _setCompletionState(completions: const [], showCompletions: false);
      return;
    }

    final selectedHost = _selectedHostState(serverState);
    if (_selectedSshHost != null && selectedHost?.reachable == false) {
      _setCompletionState(
        completions: const [],
        showCompletions: false,
        statusMessage: 'SSH host unreachable',
        statusIsError: true,
      );
      return;
    }

    _setCompletionState(
      completions: const [],
      showCompletions: false,
      statusMessage: 'Loading…',
    );

    try {
      List<String> results;
      if (_selectedSshHost != null) {
        results = await api.completeRemotePath(_selectedSshHost!, text);
      } else {
        results = await api.completePath(text);
      }
      if (!mounted || requestId != _completionRequestId) return;

      _setCompletionState(
        completions: results,
        showCompletions: results.isNotEmpty,
        statusMessage: results.isEmpty ? 'No matching directories' : null,
        highlightedIndex: results.isEmpty ? -1 : 0,
      );
      if (results.isNotEmpty) {
        _ensureHighlightedCompletionVisible();
      }
    } catch (e) {
      if (!mounted || requestId != _completionRequestId) return;

      final remoteStatus =
          _selectedSshHost != null ? _remoteCompletionStatus(e) : null;
      if (remoteStatus != null) {
        _setCompletionState(
          completions: const [],
          showCompletions: false,
          statusMessage: remoteStatus,
        );
        return;
      }

      final statusMessage =
          _selectedSshHost != null
              ? 'Remote completion unavailable: ${_formatCompletionError(e)}'
              : 'Completion unavailable: ${_formatCompletionError(e)}';
      _setCompletionState(
        completions: const [],
        showCompletions: false,
        statusMessage: statusMessage,
        statusIsError: true,
      );
      debugPrint('Path completion error: $e');
    }
  }

  String _formatCompletionError(Object error) {
    if (error is ApiException) {
      final body = error.body.trim();
      if (body.isNotEmpty) return body;
      return 'HTTP ${error.statusCode}';
    }
    return error.toString();
  }

  String? _remoteCompletionStatus(Object error) {
    if (error is ApiException &&
        error.statusCode == 503 &&
        error.body.trim() == 'remote_host_connecting') {
      return 'Remote host connecting…';
    }
    return null;
  }

  void _applyCompletion(String path) {
    _pathController.text = path;
    _pathController.selection = TextSelection.fromPosition(
      TextPosition(offset: path.length),
    );
    _setCompletionState(completions: const [], showCompletions: false);
    _fetchCompletions(path);
  }

  Map<ShortcutActivator, VoidCallback> get _completionShortcuts {
    if (!_completionShortcutsEnabled) {
      return const <ShortcutActivator, VoidCallback>{};
    }

    return <ShortcutActivator, VoidCallback>{
      SingleActivator(LogicalKeyboardKey.arrowDown):
          () => _moveHighlightedCompletion(1),
      SingleActivator(LogicalKeyboardKey.arrowUp):
          () => _moveHighlightedCompletion(-1),
      SingleActivator(LogicalKeyboardKey.tab): () {
        final index =
            _highlightedCompletionIndex >= 0 ? _highlightedCompletionIndex : 0;
        _applyCompletion(_completions[index]);
      },
    };
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Group name is required');
      return;
    }

    setState(() {
      _isSaving = true;
      _nameError = null;
    });

    final path = _pathController.text.trim();
    final defaultCwd = path.isEmpty ? '~' : path;

    try {
      if (_isEdit) {
        await ref
            .read(serverProvider.notifier)
            .updateGroup(widget.group!.id, name: name, defaultCwd: defaultCwd);
      } else {
        await ref
            .read(serverProvider.notifier)
            .createGroup(
              name: name,
              defaultCwd: defaultCwd,
              sshHost: _selectedSshHost,
            );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to ${_isEdit ? "update" : "create"} group: $e',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverState = ref.watch(groupDialogServerStateProvider);
    final sshHosts = _hostOptions(serverState);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: Text(_isEdit ? 'Edit Group' : 'New Group'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Group Name',
                  errorText: _nameError,
                ),
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
                autofocus: !_isEdit,
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _selectedSshHost,
                decoration: InputDecoration(
                  labelText: 'Host',
                  helperText:
                      _lockHostSelection
                          ? 'Host/locality is fixed after creation.'
                          : null,
                ),
                isExpanded: true,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Local'),
                  ),
                  for (final host in sshHosts)
                    DropdownMenuItem<String?>(
                      value: host.host,
                      child: Text(host.host, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged:
                    _lockHostSelection
                        ? null
                        : (value) {
                          _debounce?.cancel();
                          _completionRequestId++;
                          setState(() {
                            _selectedSshHost = value;
                          });
                          _setCompletionState(
                            completions: const [],
                            showCompletions: false,
                          );
                          if (_pathController.text.isNotEmpty) {
                            _fetchCompletions(_pathController.text);
                          }
                        },
              ),
              const SizedBox(height: 12),
              CallbackShortcuts(
                bindings: _completionShortcuts,
                child: TextField(
                  controller: _pathController,
                  onChanged: (_) => _onPathChanged(),
                  decoration: const InputDecoration(
                    labelText: 'Path',
                    hintText: '~/projects',
                  ),
                ),
              ),
              if (_completionStatusMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _completionStatusMessage!,
                    key: const ValueKey('group-dialog-completion-status'),
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          _completionStatusIsError
                              ? Colors.redAccent.shade100
                              : Colors.white54,
                    ),
                  ),
                ),
              if (_showCompletions && _completions.isNotEmpty)
                Container(
                  key: const ValueKey('group-dialog-completions'),
                  constraints: const BoxConstraints(
                    maxHeight: _completionPopupMaxHeight,
                  ),
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2D2D2D),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: ListView.builder(
                    controller: _completionScrollController,
                    shrinkWrap: true,
                    itemCount: _completions.length,
                    itemBuilder: (context, index) {
                      final completion = _completions[index];
                      final isHighlighted =
                          index == _highlightedCompletionIndex;
                      return InkWell(
                        onTap: () => _applyCompletion(completion),
                        child: Container(
                          key: _completionItemKeys[index],
                          color:
                              isHighlighted
                                  ? Colors.white.withValues(alpha: 0.12)
                                  : Colors.transparent,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Text(
                            completion,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              if (bottomInset > 0) SizedBox(height: bottomInset),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSaving ? null : _save,
          child: Text(
            _isSaving
                ? (_isEdit ? 'Saving...' : 'Creating...')
                : (_isEdit ? 'Save' : 'Create'),
          ),
        ),
      ],
    );
  }
}
