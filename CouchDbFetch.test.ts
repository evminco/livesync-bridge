import {
    COUCHDB_MAX_TOTAL_SOCKETS,
    couchDbHttpsAgent,
    createCouchDbFetch,
} from "./lib/src/pouchdb/couchdbFetch.ts";

function assert(condition: unknown, message = "assertion failed"): asserts condition {
    if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown): void {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    if (a !== e) throw new Error(`expected ${e}, received ${a}`);
}

Deno.test("shared CouchDB HTTPS agent has the approved socket ceiling", () => {
    assertEquals(COUCHDB_MAX_TOTAL_SOCKETS, 64);
    assertEquals(couchDbHttpsAgent.maxTotalSockets, 64);
    assertEquals(couchDbHttpsAgent.options.keepAlive, true);
});

Deno.test("CouchDB fetch injects the shared agent and preserves request options", async () => {
    const calls: Array<{ input: string | Request; init: RequestInit & { agent?: unknown } }> = [];
    const fetchImplementation = async (
        input: string | Request,
        init: RequestInit & { agent?: unknown } = {},
    ): Promise<Response> => {
        calls.push({ input, init });
        return new Response("ok", { status: 200 });
    };
    const fetch = createCouchDbFetch(fetchImplementation);
    const controller = new AbortController();

    const response = await fetch("https://sync.example/locul", {
        method: "POST",
        body: "{}",
        signal: controller.signal,
        headers: { "content-type": "application/json" },
    });

    assertEquals(response.status, 200);
    assertEquals(calls.length, 1);
    assertEquals(calls[0].input, "https://sync.example/locul");
    assertEquals(calls[0].init.method, "POST");
    assertEquals(calls[0].init.body, "{}");
    assert(calls[0].init.signal === controller.signal, "AbortSignal was not preserved");
    assert(calls[0].init.agent === couchDbHttpsAgent, "shared HTTPS agent was not injected");
});
