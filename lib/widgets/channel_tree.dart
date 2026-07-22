import 'package:flutter/material.dart';
import '../models/channel.dart';

class ChannelTree extends StatefulWidget {
  final List<TsChannel> channels;
  final int? selectedChannelId;
  final ValueChanged<int> onChannelTap;

  const ChannelTree({
    super.key,
    required this.channels,
    this.selectedChannelId,
    required this.onChannelTap,
  });

  @override
  State<ChannelTree> createState() => _ChannelTreeState();
}

class _ChannelTreeState extends State<ChannelTree> {
  final Set<int> _expanded = {};

  List<TsChannel> get _roots =>
      widget.channels.where((c) => c.parentId == 0).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

  @override
  Widget build(BuildContext context) {
    if (widget.channels.isEmpty) {
      return const Center(
        child: Text(
          'No channels',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _roots.length,
      itemBuilder: (context, index) => _buildTile(_roots[index], 0),
    );
  }

  Widget _buildTile(TsChannel channel, int depth) {
    final children = channel.children(widget.channels);
    final isSelected = channel.id == widget.selectedChannelId;
    final hasChildren = children.isNotEmpty;
    final isExpanded = _expanded.contains(channel.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Channel row
        Material(
          color: isSelected
              ? Colors.blue.withValues(alpha: 0.15)
              : Colors.transparent,
          child: InkWell(
            onTap: () {
              widget.onChannelTap(channel.id);
              // Auto-expand parent when selecting a channel
              if (hasChildren && !_expanded.contains(channel.id)) {
                setState(() => _expanded.add(channel.id));
              }
            },
            child: Padding(
              padding: EdgeInsets.only(
                left: 8.0 + depth * 20.0,
                top: 10,
                bottom: 10,
                right: 8,
              ),
              child: Row(
                children: [
                  // Expand/collapse arrow for channels with children
                  if (hasChildren)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          if (_expanded.contains(channel.id)) {
                            _expanded.remove(channel.id);
                          } else {
                            _expanded.add(channel.id);
                          }
                        });
                      },
                      child: Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 18,
                        color: Colors.grey,
                      ),
                    )
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 4),
                  // Channel icon
                  Icon(
                    hasChildren ? Icons.folder : Icons.tag,
                    size: 16,
                    color: isSelected ? Colors.blue : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  // Channel name
                  Expanded(
                    child: Text(
                      channel.name,
                      style: TextStyle(
                        color: isSelected ? Colors.blue : Colors.white,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Client count badge
                  if (channel.clientCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${channel.clientCount}',
                        style: TextStyle(
                          color: isSelected ? Colors.blue : Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        // Children (only if expanded)
        if (hasChildren && isExpanded)
          ...children.map((ch) => _buildTile(ch, depth + 1)),
      ],
    );
  }
}
