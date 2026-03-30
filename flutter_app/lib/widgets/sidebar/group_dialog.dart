import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/group.dart';
import '../../providers/server_provider.dart';

class GroupDialog extends ConsumerStatefulWidget {
  final Group? group;

  const GroupDialog({super.key, this.group});

  @override
  ConsumerState<GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends ConsumerState<GroupDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _pathController;
  String? _selectedSshHost;
  List<String> _completions = [];
  Timer? _debounce;
  bool _showCompletions = false;
  bool _isSaving = false;
  String? _nameError;

  bool get _isEdit => widget.group != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.group?.name ?? '');
    _pathController = TextEditingController(text: widget.group?.defaultCwd ?? '~/');
    _selectedSshHost = widget.group?.sshHost;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchCompletions(_pathController.text);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _nameController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  void _onPathChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _fetchCompletions(_pathController.text);
    });
  }

  Future<void> _fetchCompletions(String text) async {
    if (text.isEmpty) {
      setState(() {
        _completions = [];
        _showCompletions = false;
      });
      return;
    }

    final api = ref.read(serverProvider).api;
    if (api == null) return;

    try {
      List<String> results;
      if (_selectedSshHost != null) {
        results = await api.completeRemotePath(_selectedSshHost!, text);
      } else {
        results = await api.completePath(text);
      }
      if (mounted) {
        setState(() {
          _completions = results;
          _showCompletions = results.isNotEmpty;
        });
      }
    } catch (e) {
      debugPrint('Path completion error: $e');
    }
  }

  void _selectCompletion(String path) {
    _pathController.text = path;
    _pathController.selection = TextSelection.fromPosition(
      TextPosition(offset: path.length),
    );
    setState(() {
      _showCompletions = false;
    });
    _fetchCompletions(path);
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
        await ref.read(serverProvider.notifier).updateGroup(
          widget.group!.id,
          name: name,
          defaultCwd: defaultCwd,
          sshHost: _selectedSshHost ?? '',
        );
      } else {
        await ref.read(serverProvider.notifier).createGroup(
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
          SnackBar(content: Text('Failed to ${_isEdit ? "update" : "create"} group: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverState = ref.watch(serverProvider);
    final sshHosts = serverState.sshHosts;
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
                value: _selectedSshHost,
                decoration: const InputDecoration(labelText: 'Host'),
                isExpanded: true,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Local'),
                  ),
                  for (final host in sshHosts)
                    DropdownMenuItem<String?>(
                      value: host.host,
                      child: Text(
                        host.host,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedSshHost = value;
                    _completions = [];
                    _showCompletions = false;
                  });
                  if (_pathController.text.isNotEmpty) {
                    _fetchCompletions(_pathController.text);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pathController,
                onChanged: (_) => _onPathChanged(),
                decoration: const InputDecoration(
                  labelText: 'Path',
                  hintText: '~/projects',
                ),
              ),
              if (_showCompletions && _completions.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 150),
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2D2D2D),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _completions.length,
                    itemBuilder: (context, index) {
                      final completion = _completions[index];
                      return InkWell(
                        onTap: () => _selectCompletion(completion),
                        child: Padding(
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
          child: Text(_isSaving
              ? (_isEdit ? 'Saving...' : 'Creating...')
              : (_isEdit ? 'Save' : 'Create')),
        ),
      ],
    );
  }
}
