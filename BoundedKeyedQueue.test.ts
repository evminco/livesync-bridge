import { BoundedKeyedQueue } from "./BoundedKeyedQueue.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}
function assertEquals(actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`expected ${e}, received ${a}`);
}
async function assertRejects(
  operation: () => Promise<unknown>,
  message: string,
): Promise<void> {
  try {
    await operation();
  } catch (error) {
    assert(
      error instanceof Error && error.message.includes(message),
      `unexpected rejection: ${error}`,
    );
    return;
  }
  throw new Error("expected operation to reject");
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((r) => resolve = r);
  return { promise, resolve };
}

Deno.test("same key is serialized in submission order", async () => {
  const queue = new BoundedKeyedQueue(4);
  const gate = deferred<void>();
  const events: string[] = [];
  const first = queue.run("a", async () => {
    events.push("first-start");
    await gate.promise;
    events.push("first-end");
  });
  const second = queue.run("a", async () => events.push("second"));
  while (events.length === 0) await Promise.resolve();
  assertEquals(events, ["first-start"]);
  gate.resolve();
  await Promise.all([first, second]);
  assertEquals(events, ["first-start", "first-end", "second"]);
});

Deno.test("different keys are bounded and concurrent", async () => {
  const queue = new BoundedKeyedQueue(2);
  const gate = deferred<void>();
  let active = 0;
  let maxActive = 0;
  let started = 0;
  const operations = ["a", "b", "c", "d"].map((key) =>
    queue.run(key, async () => {
      active++;
      started++;
      maxActive = Math.max(maxActive, active);
      await gate.promise;
      active--;
    })
  );
  while (started < 2) await Promise.resolve();
  assertEquals(started, 2);
  assertEquals(maxActive, 2);
  gate.resolve();
  await Promise.all(operations);
  assertEquals(maxActive, 2);
});

Deno.test("one rejection does not poison a key", async () => {
  const queue = new BoundedKeyedQueue(1);
  const rejected = queue.run("a", async () => {
    throw new Error("expected");
  });
  const recovered = queue.run("a", async () => 42);
  await assertRejects(() => rejected, "expected");
  assertEquals(await recovered, 42);
  assert(true);
});
