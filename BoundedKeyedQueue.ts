import { Semaphore } from "octagonal-wheels/concurrency/semaphore";

export class BoundedKeyedQueue {
  private readonly slots;
  private readonly tails = new Map<string, Promise<void>>();

  constructor(readonly concurrency: number) {
    if (!Number.isInteger(concurrency) || concurrency < 1) {
      throw new Error("concurrency must be a positive integer");
    }
    this.slots = Semaphore(concurrency);
  }

  run<T>(key: string, operation: () => Promise<T> | T): Promise<T> {
    const previous = this.tails.get(key) ?? Promise.resolve();
    const result = previous.catch(() => undefined).then(async () => {
      const release = await this.slots.acquire();
      try {
        return await Promise.resolve(operation());
      } finally {
        release();
      }
    });
    const tail = result.then(() => undefined, () => undefined);
    this.tails.set(key, tail);
    void tail.finally(() => {
      if (this.tails.get(key) === tail) {
        this.tails.delete(key);
      }
    });
    return result;
  }
}
