import 'dart:async';
import 'dart:isolate';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/utils/isolate_pool.dart';

void main() {
  group('ComputeGate', () {
    test('limits concurrent work', () async {
      final gate = ComputeGate.forTesting(maxConcurrentTasks: 1);
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var activeTasks = 0;
      var maxActiveTasks = 0;

      final Future<void> first = gate.run(() async {
        activeTasks++;
        maxActiveTasks =
            activeTasks > maxActiveTasks ? activeTasks : maxActiveTasks;
        firstStarted.complete();
        await releaseFirst.future;
        activeTasks--;
      });

      await firstStarted.future;

      final Future<void> second = gate.run(() async {
        activeTasks++;
        maxActiveTasks =
            activeTasks > maxActiveTasks ? activeTasks : maxActiveTasks;
        activeTasks--;
      });

      await Future<void>.delayed(Duration.zero);
      expect(maxActiveTasks, 1);

      releaseFirst.complete();
      await Future.wait([first, second]);

      expect(maxActiveTasks, 1);
    });

    test('names the isolate it runs work in', () async {
      final gate = ComputeGate.forTesting(maxConcurrentTasks: 1);

      final name = await gate.runIsolate(
        () => Isolate.current.debugName,
        debugName: 'compute-gate-probe',
      );

      expect(name, 'compute-gate-probe');
    });

    test('a time limit covers queueing as well as execution', () {
      fakeAsync((async) {
        final gate = ComputeGate.forTesting(maxConcurrentTasks: 1);
        final holder = Completer<void>();
        gate.run(() => holder.future);
        final task = Completer<int>();
        Object? outcome;
        gate
            .run(() => task.future, timeout: const Duration(seconds: 1))
            .then<void>(
              (value) => outcome = value,
              onError: (Object e) => outcome = e,
            );

        // 本改版：排队时间计入预算 —— 名额被长期占住时先超时，
        // 而不是无限等下去把整个闸门毒死。
        async.elapse(const Duration(seconds: 5));
        expect(outcome, isA<ComputeGateTimeout>());
        expect(gate.debugQueuedTasks, 0);

        holder.complete();
        task.complete(7);
        async.flushMicrotasks();
        expect(outcome, isA<ComputeGateTimeout>());
      });
    });

    test('a timed out task returns its permit while it keeps running', () {
      fakeAsync((async) {
        final gate = ComputeGate.forTesting(maxConcurrentTasks: 1);
        final stuck = Completer<void>();
        Object? error;
        gate
            .run(() => stuck.future, timeout: const Duration(seconds: 1))
            .catchError((Object e) => error = e);
        var next = false;
        gate.run(() => next = true);

        async.elapse(const Duration(seconds: 1));

        expect(error, isA<ComputeGateTimeout>());
        expect(next, isTrue);
        stuck.complete();
      });
    });

    test('runCompute applies its time limit to the compute', () async {
      final gate = ComputeGate.forTesting(maxConcurrentTasks: 1);

      Object? error;
      fakeAsync((async) {
        gate
            .runCompute(_echo, 7, timeout: const Duration(seconds: 1))
            .then<void>((_) {}, onError: (Object e) => error = e);
        // isolate 回包是真实事件，假时钟推进期间到不了，时限必然先到期
        async.elapse(const Duration(seconds: 1));
      });
      expect(error, isA<ComputeGateTimeout>());
      expect(await gate.runCompute(_echo, 8), 8);
    });

    test('keeps default concurrency within processor-safe bounds', () {
      expect(ComputeGate.defaultMaxConcurrentTasks(processorCount: 1), 1);
      expect(ComputeGate.defaultMaxConcurrentTasks(processorCount: 2), 1);
      expect(ComputeGate.defaultMaxConcurrentTasks(processorCount: 8), 3);
    });
  });
}

int _echo(int value) => value;