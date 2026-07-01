import { defaultLoggerEnv } from "./lib/src/common/logger.ts";
import { LOG_LEVEL_DEBUG } from "./lib/src/common/logger.ts";
import { Hub } from "./Hub.ts";
import { Config } from "./types.ts";
import { parseArgs } from "jsr:@std/cli";
import { EventEmitter } from "node:events";

// Bulk vault sync can fan out many HTTPS requests at once. Keep Node's
// listener leak warning useful without tripping on normal bridge batches.
EventEmitter.defaultMaxListeners = 50;

// Deno's Node-compat `node-fetch` occasionally throws a secondary
// `cancelHandleRid` error while cleaning up a failed HTTPS request. The bridge
// already retries CouchDB polling; without this guard the secondary cleanup bug
// kills the whole service. Keep this deliberately narrow so real bugs still fail.
const isTransientNodeFetchCleanupBug = (err: unknown): boolean => {
    const text = `${err instanceof Error ? `${err.name}: ${err.message}\n${err.stack ?? ""}` : err}`;
    return text.includes("cancelHandleRid") ||
        (text.includes("FetchError") && text.includes("sync.lz-osync.uk/locul"));
};

globalThis.addEventListener("error", (event) => {
    if (isTransientNodeFetchCleanupBug(event.error ?? event.message)) {
        console.error("Suppressed transient CouchDB/node-fetch cleanup error; bridge will retry.", event.error ?? event.message);
        event.preventDefault();
    }
});

globalThis.addEventListener("unhandledrejection", (event) => {
    if (isTransientNodeFetchCleanupBug(event.reason)) {
        console.error("Suppressed transient CouchDB/node-fetch rejection; bridge will retry.", event.reason);
        event.preventDefault();
    }
});

const KEY = "LSB_"
defaultLoggerEnv.minLogLevel = LOG_LEVEL_DEBUG;
const configFile = Deno.env.get(`${KEY}CONFIG`) || "./dat/config.json";

console.log("LiveSync Bridge is now starting...");
let config: Config = { peers: [] };
const flags = parseArgs(Deno.args, {
    boolean: ["reset"],
    // string: ["version"],
    default: { reset: false },
});
if (flags.reset) {
    localStorage.clear();
}
try {
    const confText = await Deno.readTextFile(configFile);
    config = JSON.parse(confText);
} catch (ex) {
    console.error("Could not parse configuration!");
    console.error(ex);
}
console.log("LiveSync Bridge is now started!");
const hub = new Hub(config);
await hub.start();