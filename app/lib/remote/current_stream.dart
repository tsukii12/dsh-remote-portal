import 'dart:async';

Stream<T> currentStream<T>(T Function() current, Stream<T> changes) => Stream.multi((controller) {
  final subscription = changes.listen(controller.add, onError: controller.addError, onDone: controller.close);
  controller.add(current());
  controller.onCancel = subscription.cancel;
});
