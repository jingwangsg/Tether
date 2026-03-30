import 'package:flutter/material.dart';
import '../../models/ssh_host.dart';

class SshHostList extends StatefulWidget {
  final List<SshHost> hosts;

  const SshHostList({super.key, required this.hosts});

  @override
  State<SshHostList> createState() => _SshHostListState();
}

class _SshHostListState extends State<SshHostList> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: Colors.white38,
                ),
                const SizedBox(width: 4),
                const Icon(Icons.dns_outlined, size: 16, color: Colors.white54),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'SSH Hosts',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  '${widget.hosts.length}',
                  style: const TextStyle(color: Colors.white24, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final host in widget.hosts) _buildHostTile(context, host),
      ],
    );
  }

  Widget _buildHostTile(BuildContext context, SshHost host) {
    return Padding(
      padding: const EdgeInsets.only(left: 28, right: 8, top: 5, bottom: 5),
      child: Row(
        children: [
          const Icon(Icons.computer, size: 14, color: Colors.white54),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host.host,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
                if (host.hostname != null)
                  Text(
                    host.displayString,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}
