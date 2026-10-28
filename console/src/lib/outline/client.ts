// Thin wrapper around Outline's API. Outline's endpoints are POST-only,
// JSON in/out, shaped like `POST /api/<resource>.<action>`.
//
// NOTE: field names below (collectionId, parentDocumentId, doc.text, etc.)
// are written from general knowledge of Outline's API shape and have not
// been verified against a live instance yet - check response shapes on
// first real run against OUTLINE_API_URL and adjust getDocumentText /
// listCollectionDocuments if anything doesn't line up.

function baseUrl(): string {
  const url = process.env.OUTLINE_API_URL;
  if (!url) throw new Error("OUTLINE_API_URL is not set");
  return url.replace(/\/+$/, "");
}

async function outlineFetch<T>(path: string, body: Record<string, unknown> = {}): Promise<T> {
  const token = process.env.OUTLINE_API_TOKEN;
  if (!token) throw new Error("OUTLINE_API_TOKEN is not set");

  const res = await fetch(`${baseUrl()}/api/${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    cache: "no-store",
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Outline API ${path} failed: ${res.status} ${text}`);
  }

  return res.json() as Promise<T>;
}

interface OutlineDocumentSummary {
  id: string;
  title: string;
  url: string;
}

interface OutlineDocument extends OutlineDocumentSummary {
  text: string;
}

/** All documents directly in a collection (does not recurse into nested docs). */
export async function listCollectionDocuments(
  collectionId: string
): Promise<OutlineDocumentSummary[]> {
  const res = await outlineFetch<{ data: OutlineDocumentSummary[] }>("documents.list", {
    collectionId,
    limit: 100, // Outline's default page is 25; no pagination loop yet
  });
  return res.data;
}

export async function getDocument(id: string): Promise<OutlineDocument> {
  const res = await outlineFetch<{ data: OutlineDocument }>("documents.info", { id });
  return res.data;
}

export async function updateDocumentText(id: string, text: string): Promise<void> {
  await outlineFetch("documents.update", { id, text });
}
