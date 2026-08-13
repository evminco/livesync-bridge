export interface RevisionedDocument {
  _id: string;
  _rev?: string;
  _deleted?: boolean;
}

export interface WriteResponse {
  id: string;
  ok: boolean;
  rev: string;
}

export interface RevisionDatabase<T extends RevisionedDocument> {
  get(id: string, options?: unknown): Promise<T>;
  put(document: T): Promise<WriteResponse>;
  allDocs?(options: {
    keys: string[];
    include_docs: true;
  }): Promise<{
    rows: Array<{
      doc?: T;
      error?: string;
      value?: { rev?: string; deleted?: boolean };
    }>;
  }>;
}

export interface ConflictAttempt {
  attempt: number;
  maxAttempts: number;
  willRetry: boolean;
}

export interface ConflictOptions {
  maxAttempts?: number;
  backoffMs?: (attempt: number) => number;
  onConflict?: (event: ConflictAttempt) => void;
}

export type FreshWriteResult<T extends RevisionedDocument> =
  | { status: "written"; document: T; response: WriteResponse }
  | { status: "missing" }
  | { status: "skipped" }
  | { status: "conflict" };

export function isConflictError(error: unknown): boolean {
  const value = error as
    | { status?: number; name?: string; error?: string }
    | null;
  return value?.status === 409 || value?.name === "conflict" ||
    value?.error === "conflict";
}

export function isMissingError(error: unknown): boolean {
  const value = error as
    | { status?: number; name?: string; error?: string }
    | null;
  return value?.status === 404 || value?.name === "not_found" ||
    value?.error === "not_found";
}

async function backoff(
  options: ConflictOptions,
  attempt: number,
): Promise<void> {
  const delayMs = options.backoffMs?.(attempt) ?? attempt * 250;
  if (delayMs > 0) {
    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
}

function conflictEvent(
  options: ConflictOptions,
  attempt: number,
  maxAttempts: number,
): void {
  options.onConflict?.({
    attempt,
    maxAttempts,
    willRetry: attempt < maxAttempts,
  });
}

async function putDocument<T extends RevisionedDocument>(
  database: RevisionDatabase<T>,
  document: T,
): Promise<WriteResponse> {
  // The HTTP adapter's single-document PUT puts the encoded document ID in
  // the URL. Proxies may decode %2F before CouchDB sees it, causing IDs with
  // slashes to be interpreted as document/attachment routes. _bulk_docs keeps
  // the ID in JSON and avoids that ambiguity while retaining normal edits.
  const bulkDocs = (database as unknown as {
    bulkDocs?: (documents: T[]) => Promise<
      Array<
        WriteResponse | {
          id: string;
          status?: number;
          name?: string;
          error?: string;
          reason?: string;
        }
      >
    >;
  }).bulkDocs;
  if (bulkDocs) {
    const [result] = await bulkDocs.call(database, [document]);
    if (result && "ok" in result && result.ok) return result;
    throw result ?? new Error("bulkDocs returned no result");
  }
  return await database.put(document);
}

type CurrentDocument<T extends RevisionedDocument> =
  | { status: "found"; document: T }
  | { status: "deleted"; document: T }
  | { status: "missing" };

async function getCurrentDocument<T extends RevisionedDocument>(
  database: RevisionDatabase<T>,
  id: string,
  getOptions?: unknown,
): Promise<CurrentDocument<T>> {
  try {
    // pouchdb-adapter-http 9 assumes the options object is always present and
    // can throw `Cannot read properties of undefined (reading 'revs')` before
    // making the HTTP request. Always pass an object, even for a plain latest
    // winning-revision lookup.
    const document = await database.get(id, getOptions ?? {});
    return document._deleted
      ? { status: "deleted", document }
      : { status: "found", document };
  } catch (error) {
    if (!isMissingError(error)) throw error;
  }

  // Some HTTP proxies return a misleading 404 "missing attachment" for a
  // direct document GET while _all_docs still exposes the winning revision.
  // Fall back to one keyed _all_docs lookup before treating the document as
  // absent; this is also the only safe way to avoid blind create→409 loops.
  if (database.allDocs) {
    const result = await database.allDocs({ keys: [id], include_docs: true });
    const row = result.rows[0];
    if (row && !row.error) {
      // A direct GET may reject the same winning revision as a missing
      // attachment. Prefer the keyed allDocs document body when available;
      // using only the revision stub would discard existing metadata fields.
      const document = row.doc;
      if (document) {
        return document._deleted || row.value?.deleted
          ? { status: "deleted", document }
          : { status: "found", document };
      }
    }
  }
  return { status: "missing" };
}

export async function writeWithFreshRevision<T extends RevisionedDocument>(
  database: RevisionDatabase<T>,
  desiredDocument: T,
  options: ConflictOptions = {},
): Promise<FreshWriteResult<T>> {
  const maxAttempts = options.maxAttempts ?? 3;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const candidate = { ...desiredDocument };
    delete candidate._rev;
    try {
      const current = await getCurrentDocument(database, candidate._id);
      if (current.status !== "missing") candidate._rev = current.document._rev;
      const response = await putDocument(database, candidate);
      return { status: "written", document: candidate, response };
    } catch (error) {
      if (!isConflictError(error)) throw error;
      conflictEvent(options, attempt, maxAttempts);
      if (attempt === maxAttempts) return { status: "conflict" };
      await backoff(options, attempt);
    }
  }
  return { status: "conflict" };
}

export async function mutateWithFreshRevision<T extends RevisionedDocument>(
  database: RevisionDatabase<T>,
  id: string,
  mutate: (current: T) => T | false,
  _getOptions: unknown,
  options: ConflictOptions = {},
): Promise<FreshWriteResult<T>> {
  const maxAttempts = options.maxAttempts ?? 3;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const current = await getCurrentDocument(database, id);
      if (current.status === "missing" || current.status === "deleted") {
        return { status: "missing" };
      }
      const candidate = mutate({ ...current.document });
      if (candidate === false) return { status: "skipped" };
      const response = await putDocument(database, candidate);
      return { status: "written", document: candidate, response };
    } catch (error) {
      if (!isConflictError(error)) throw error;
      conflictEvent(options, attempt, maxAttempts);
      if (attempt === maxAttempts) return { status: "conflict" };
      await backoff(options, attempt);
    }
  }
  return { status: "conflict" };
}
