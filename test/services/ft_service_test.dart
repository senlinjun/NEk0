import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/services/ft_service.dart';

void main() {
  group('TransferJob.progress', () {
    test('clamps into 0..1', () {
      final job = TransferJob(
        taskId: 1,
        kind: TransferKind.download,
        displayName: 'f',
        total: 100,
      );
      expect(job.progress, 0.0);
      job.transferred = 50;
      expect(job.progress, 0.5);
      // The server may report more than the announced total near the end.
      job.transferred = 150;
      expect(job.progress, 1.0);
    });

    test('an unknown total reports zero progress', () {
      final job = TransferJob(
        taskId: 1,
        kind: TransferKind.download,
        displayName: 'f',
        total: 0,
      );
      job.transferred = 10;
      expect(job.progress, 0.0);
    });
  });

  group('FolderProgress.row', () {
    FolderProgress fp() => FolderProgress(
      kind: TransferKind.upload,
      label: 'pics/',
      totalBytes: 1000,
    )..rowTaskId = -1;

    test('while collecting the row is active', () {
      final f = fp();
      f.steps = 2;
      expect(f.isRunning, isTrue);
      final row = f.row();
      expect(row.state, TransferState.active);
      expect(row.kind, TransferKind.upload);
      expect(row.displayName, 'pics/');
      expect(row.total, 1000);
    });

    test('all steps done closes the row as done', () {
      final f = fp();
      f.steps = 2;
      f.doneSteps = 2;
      f.collecting = false;
      final row = f.row();
      expect(row.state, TransferState.done);
      expect(row.isActive, isFalse);
      expect(f.isRunning, isFalse);
    });

    test('a failed step surfaces as an error row', () {
      final f = fp();
      f.steps = 1;
      f.doneSteps = 1;
      f.collecting = false;
      f.error = true;
      final row = f.row();
      expect(row.state, TransferState.error);
      expect(row.error, 'folder');
    });

    test('cancel beats completion', () {
      final f = fp();
      f.steps = 1;
      f.doneSteps = 1;
      f.collecting = false;
      f.canceled = true;
      expect(f.row().state, TransferState.canceled);
      expect(f.isRunning, isFalse);
    });
  });

  test('FtEntry.isParent', () {
    expect(
      FtEntry(name: '..', size: 0, datetime: -1, isFile: false).isParent,
      isTrue,
    );
    expect(
      FtEntry(name: 'a.txt', size: 1, datetime: 1, isFile: true).isParent,
      isFalse,
    );
  });

  // The service is a process-wide singleton; every test below uses its own
  // task ids so bookkeeping never collides. Only the pure event paths are
  // driven — nothing here may reach TsNative.
  group('FtTransferService events', () {
    test('hidden task resolves on ft_done and removes its row', () async {
      final svc = FtTransferService.instance;
      const taskId = 983001;
      final future = svc.trackHiddenTask(
        taskId,
        'avatar.bin',
        timeout: const Duration(seconds: 5),
      );
      await Future<void>.delayed(Duration.zero);
      svc.handleEvent({
        'type': 'ft_done',
        'task_id': taskId,
        'ok': true,
        'transferred': 12,
      });
      await future;
      expect(svc.jobs.any((j) => j.taskId == taskId), isFalse);
    });

    test('a failed transfer throws with the server reason', () async {
      final svc = FtTransferService.instance;
      const taskId = 983002;
      final future = svc.trackHiddenTask(
        taskId,
        'avatar.bin',
        timeout: const Duration(seconds: 5),
      );
      await Future<void>.delayed(Duration.zero);
      svc.handleEvent({
        'type': 'ft_done',
        'task_id': taskId,
        'ok': false,
        'transferred': 3,
        'error': 'disk full',
      });
      await expectLater(
        future,
        throwsA(
          isA<TransferException>().having(
            (e) => e.reason,
            'reason',
            'disk full',
          ),
        ),
      );
    });

    test('a canceled transfer throws a canceled TransferException', () async {
      final svc = FtTransferService.instance;
      const taskId = 983003;
      final future = svc.trackHiddenTask(
        taskId,
        'avatar.bin',
        timeout: const Duration(seconds: 5),
      );
      await Future<void>.delayed(Duration.zero);
      svc.handleEvent({
        'type': 'ft_done',
        'task_id': taskId,
        'ok': false,
        'transferred': 1,
        'error': 'canceled',
      });
      await expectLater(
        future,
        throwsA(
          isA<TransferException>().having(
            (e) => e.canceled,
            'canceled',
            isTrue,
          ),
        ),
      );
    });

    test('disconnect rejects a pending transfer waiter', () async {
      final svc = FtTransferService.instance;
      const taskId = 983004;
      final future = svc.trackHiddenTask(
        taskId,
        'avatar.bin',
        timeout: const Duration(seconds: 5),
      );
      await Future<void>.delayed(Duration.zero);
      svc.handleEvent({'type': 'disconnected'});
      await expectLater(future, throwsA(anything));
      expect(svc.hasActiveJobs, isFalse);
    });
  });
}
