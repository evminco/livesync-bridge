import {
  mutateWithFreshRevision,
  type RevisionDatabase,
  type RevisionedDocument,
  writeWithFreshRevision,
} from "./conflictSafeMetadata.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`expected ${e}, received ${a}`);
}

interface Doc extends RevisionedDocument {
  value: string;
  deleted?: boolean;
}

class FakeDatabase implements RevisionDatabase<Doc> {
  current?: Doc;
  getCalls = 0;
  getOptions: unknown[] = [];
  putCalls = 0;
  bulkDocsCalls = 0;
  allDocsCalls = 0;
  conflictsRemaining = 0;
  alwaysConflict = false;
  directGetMissingAttachment = false;

  constructor(current?: Doc) {
    this.current = current && { ...current };
  }

  async get(id: string, options?: unknown): Promise<Doc> {
    this.getCalls++;
    this.getOptions.push(options);
    if (this.directGetMissingAttachment) {
      throw {
        status: 404,
        name: "not_found",
        message: "Document is missing attachment",
      };
    }
    if (!this.current || this.current._id !== id) {
      throw { status: 404, name: "not_found" };
    }
    return { ...this.current };
  }

  async allDocs(options: { keys: string[]; include_docs: true }) {
    this.allDocsCalls++;
    const id = options.keys[0];
    if (!this.current || this.current._id !== id) {
      return { rows: [{ error: "not_found" }] };
    }
    return {
      rows: [{
        doc: { ...this.current },
        value: { rev: this.current._rev, deleted: this.current._deleted },
      }],
    };
  }

  async put(document: Doc) {
    this.putCalls++;
    if (this.alwaysConflict || this.conflictsRemaining-- > 0) {
      if (this.current) {
        this.current._rev = `${
          Number(this.current._rev?.split("-")[0] ?? 0) + 1
        }-external`;
      }
      throw { status: 409, name: "conflict" };
    }
    if (this.current && document._rev !== this.current._rev) {
      throw { status: 409, name: "conflict" };
    }
    const generation = Number(document._rev?.split("-")[0] ?? 0) + 1;
    const rev = `${generation}-written`;
    this.current = { ...document, _rev: rev };
    return { ok: true, id: document._id, rev };
  }

  async bulkDocs(documents: Doc[]) {
    this.bulkDocsCalls++;
    try {
      return [await this.put(documents[0])];
    } catch (error) {
      return [{ id: documents[0]._id, ...(error as object) }];
    }
  }
}

const noBackoff = { backoffMs: () => 0 };

Deno.test("normal create succeeds without a revision", async () => {
  const db = new FakeDatabase();
  const result = await writeWithFreshRevision(
    db,
    { _id: "a", value: "new" },
    noBackoff,
  );
  assertEquals(result.status, "written");
  assertEquals(db.current?._rev, "1-written");
});

Deno.test("plain latest-revision lookup passes a PouchDB-safe options object", async () => {
  const db = new FakeDatabase();
  const result = await writeWithFreshRevision(
    db,
    { _id: "a", value: "new" },
    noBackoff,
  );
  assertEquals(result.status, "written");
  assertEquals(db.getOptions, [{}]);
});

Deno.test("normal update uses the current revision", async () => {
  const db = new FakeDatabase({ _id: "a", _rev: "4-old", value: "old" });
  const result = await writeWithFreshRevision(db, {
    _id: "a",
    _rev: "1-stale",
    value: "new",
  }, noBackoff);
  assertEquals(result.status, "written");
  assertEquals(db.current?._rev, "5-written");
  assertEquals(db.current?.value, "new");
});

Deno.test("missing-attachment GET falls back to keyed allDocs revision", async () => {
  const db = new FakeDatabase({ _id: "a", _rev: "4-old", value: "old" });
  db.directGetMissingAttachment = true;
  const result = await writeWithFreshRevision(
    db,
    { _id: "a", value: "new" },
    noBackoff,
  );
  assertEquals(result.status, "written");
  assertEquals(db.bulkDocsCalls, 1);
  assertEquals(db.allDocsCalls, 1);
  assertEquals(db.current?._rev, "5-written");
});

Deno.test("stale-revision conflict refetches then succeeds", async () => {
  const db = new FakeDatabase({ _id: "a", _rev: "1-old", value: "old" });
  db.conflictsRemaining = 1;
  const result = await writeWithFreshRevision(
    db,
    { _id: "a", value: "new" },
    noBackoff,
  );
  assertEquals(result.status, "written");
  assertEquals(db.getCalls, 2);
  assertEquals(db.putCalls, 2);
  assertEquals(db.current?._rev, "3-written");
});

Deno.test("persistent conflict stops after exactly three attempts", async () => {
  const db = new FakeDatabase({ _id: "a", _rev: "1-old", value: "old" });
  db.alwaysConflict = true;
  const result = await writeWithFreshRevision(
    db,
    { _id: "a", value: "new" },
    noBackoff,
  );
  assertEquals(result.status, "conflict");
  assertEquals(db.getCalls, 3);
  assertEquals(db.putCalls, 3);
  assertEquals(db.bulkDocsCalls, 3);
});

Deno.test("delete conflict refetches and succeeds", async () => {
  const db = new FakeDatabase({ _id: "a", _rev: "1-old", value: "old" });
  db.conflictsRemaining = 1;
  const result = await mutateWithFreshRevision(
    db,
    "a",
    (doc) => ({ ...doc, deleted: true }),
    undefined,
    noBackoff,
  );
  assertEquals(result.status, "written");
  assertEquals(db.getCalls, 2);
  assertEquals(db.current?.deleted, true);
});

Deno.test("already-deleted delete is idempotent", async () => {
  const db = new FakeDatabase({
    _id: "a",
    _rev: "2-deleted",
    _deleted: true,
    value: "old",
  });
  const result = await mutateWithFreshRevision(
    db,
    "a",
    (doc) => ({ ...doc, deleted: true }),
    undefined,
    noBackoff,
  );
  assertEquals(result.status, "missing");
  assertEquals(db.putCalls, 0);
});

Deno.test("already-missing delete is idempotent", async () => {
  const db = new FakeDatabase();
  const result = await mutateWithFreshRevision(
    db,
    "missing",
    (doc) => ({ ...doc, deleted: true }),
    undefined,
    noBackoff,
  );
  assertEquals(result.status, "missing");
  assertEquals(db.putCalls, 0);
});

Deno.test("unsupported mutation is skipped without writing", async () => {
  const db = new FakeDatabase({ _id: "a", _rev: "1-old", value: "old" });
  const result = await mutateWithFreshRevision(
    db,
    "a",
    () => false,
    undefined,
    noBackoff,
  );
  assertEquals(result.status, "skipped");
  assertEquals(db.putCalls, 0);
});
