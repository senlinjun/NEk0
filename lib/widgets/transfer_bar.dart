import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/ft_service.dart';

/// Bottom transfer progress strip for the file manager screen: one compact
/// row while transferring (tap for details), finished history accessible via
/// the same sheet. Hidden entirely when there is nothing to show.
class TransferBar extends StatelessWidget {
  /// Clears finished rows from the service (dismiss button).
  final VoidCallback onClearFinished;

  const TransferBar({super.key, required this.onClearFinished});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FtTransferService.instance,
      builder: (context, _) {
        final jobs = FtTransferService.instance.jobs;
        if (jobs.isEmpty) {
          // Nothing to show, but keep the bottom inset reserved (transparent)
          // so list content does not slide under the gesture-nav area — the
          // screen's SafeArea no longer pads the bottom.
          return SafeArea(top: false, child: const SizedBox.shrink());
        }
        final active = jobs.where((j) => j.isActive).toList();
        final headline = active.isNotEmpty
            ? active.last
            : jobs.last; // most recently updated row

        final al = AppLocalizations.of(context);
        return Material(
          type: MaterialType.transparency,
          // The bar extends into the gesture-nav inset (the screen's SafeArea
          // no longer pads the bottom); the content stays above the inset.
          child: ColoredBox(
            color: const Color(0xFF1A1A2E),
            child: SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: () => _showDetailsSheet(context, al, jobs),
                      child: Row(
                        children: [
                          Icon(
                            headline.kind == TransferKind.upload
                                ? Icons.upload_outlined
                                : Icons.download_outlined,
                            size: 16,
                            color: Colors.blueAccent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              headline.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Text(
                            '${(headline.progress * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                          if (active.length > 1)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(
                                '+${active.length - 1}',
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.keyboard_arrow_up,
                            size: 16,
                            color: Colors.grey,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: headline.state == TransferState.active
                                  ? (headline.progress > 0
                                        ? headline.progress
                                        : null)
                                  : 1,
                              minHeight: 5,
                              color: Colors.blue,
                              backgroundColor: const Color(0xFF2A2A4A),
                            ),
                          ),
                        ),
                        if (headline.isActive)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            tooltip: al.fmCancelTransfer,
                            icon: const Icon(
                              Icons.close,
                              size: 16,
                              color: Colors.redAccent,
                            ),
                            onPressed: () => FtTransferService.instance.cancel(
                              headline.taskId,
                            ),
                          )
                        else ...[
                          const Spacer(),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              minimumSize: Size.zero,
                              foregroundColor: Colors.grey,
                            ),
                            onPressed: () {
                              FtTransferService.instance.clearFinished();
                              onClearFinished();
                            },
                            icon: const Icon(Icons.clear_all, size: 14),
                            label: Text(
                              al.fmClearHistory,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showDetailsSheet(
    BuildContext context,
    AppLocalizations al,
    List<TransferJob> jobs,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: FtTransferService.instance,
          builder: (context, _) {
            final current = FtTransferService.instance.jobs;
            return Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      al.fmTransfersTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF2A2A4A)),
                  if (current.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        al.fmEmpty,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: current.length,
                        itemBuilder: (context, index) {
                          final job = current[index];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              job.kind == TransferKind.upload
                                  ? Icons.upload_outlined
                                  : Icons.download_outlined,
                              size: 18,
                              color: Colors.blueAccent,
                            ),
                            title: Text(
                              job.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                            subtitle: LinearProgressIndicator(
                              value: job.isActive
                                  ? (job.progress > 0 ? job.progress : null)
                                  : 1,
                              minHeight: 3,
                              color: job.state == TransferState.error
                                  ? Colors.redAccent
                                  : Colors.blue,
                              backgroundColor: const Color(0xFF2A2A4A),
                            ),
                            trailing: job.isActive
                                ? IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.close,
                                      size: 16,
                                      color: Colors.redAccent,
                                    ),
                                    onPressed: () => FtTransferService.instance
                                        .cancel(job.taskId),
                                  )
                                : Text(
                                    _stateLabel(job, al),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: job.state == TransferState.done
                                          ? Colors.green
                                          : Colors.redAccent,
                                    ),
                                  ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static String _stateLabel(TransferJob job, AppLocalizations al) {
    switch (job.state) {
      case TransferState.done:
        return al.fmStateDone;
      case TransferState.error:
        return al.fmStateError;
      case TransferState.canceled:
        return al.fmStateCanceled;
      case TransferState.active:
        return '';
    }
  }
}
