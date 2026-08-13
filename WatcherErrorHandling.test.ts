import { BoundedKeyedQueue } from "./BoundedKeyedQueue.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`expected ${e}, received ${a}`);
}

Deno.test("watcher-style detached handler catches queue rejection", async () => {
  const queue = new BoundedKeyedQueue(1);
  const caught: string[] = [];
  void queue.run("path", async () => {
    throw new Error("handler failed");
  }).catch((error) =>
    caught.push(error instanceof Error ? error.message : String(error))
  );

  for (let i = 0; i < 10 && caught.length === 0; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }

  assertEquals(caught, ["handler failed"]);
  assertEquals(await queue.run("path", () => "recovered"), "recovered");
});
