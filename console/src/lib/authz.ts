/**
 * Authorization. This file is the entire access-control story -- review it
 * before anything else in the console.
 *
 * Rules:
 *   1. Being signed in is NOT enough. Every page and API route must call
 *      requireViewer() or requireAdmin(); middleware only keeps anonymous
 *      browsers on the sign-in page and is not the gate.
 *   2. Mutating operations call requireAdmin(), which re-validates group
 *      membership against Pocket ID instead of trusting the session, so
 *      revoking admin takes effect immediately, not at session expiry.
 *   3. Fail closed: unset group config, a missing/expired access token, or an
 *      unreachable provider all deny.
 *
 * Groups (Pocket ID user groups, carried in the `groups` claim):
 *   CONSOLE_VIEWER_GROUP  may open the console
 *   CONSOLE_ADMIN_GROUP   may also run mutating actions; implies viewer
 */
import { getServerSession } from "next-auth";
import { authOptions } from "@/lib/auth";

export class AuthzError extends Error {
  constructor(
    message: string,
    readonly status: 401 | 403,
  ) {
    super(message);
  }
}

export interface Principal {
  sub: string;
  email?: string;
  name?: string;
  groups: string[];
  isAdmin: boolean;
}

function requiredGroup(name: "CONSOLE_VIEWER_GROUP" | "CONSOLE_ADMIN_GROUP"): string {
  const value = process.env[name];
  if (!value) throw new AuthzError(`${name} is not configured`, 403);
  return value;
}

/** Pure decision over a group list; throws if either group is unconfigured. */
export function evaluateGroups(groups: string[]): { viewer: boolean; admin: boolean } {
  const adminGroup = requiredGroup("CONSOLE_ADMIN_GROUP");
  const viewerGroup = requiredGroup("CONSOLE_VIEWER_GROUP");
  const admin = groups.includes(adminGroup);
  return { viewer: admin || groups.includes(viewerGroup), admin };
}

/** Anyone allowed to open the console. Session groups are good enough for reads. */
export async function requireViewer(): Promise<Principal> {
  const session = await getServerSession(authOptions);
  const sub = session?.user?.sub;
  if (!session || !sub) throw new AuthzError("Not authenticated", 401);

  const groups = session.user.groups ?? [];
  const { viewer, admin } = evaluateGroups(groups);
  if (!viewer) throw new AuthzError("Not in a group permitted to use this console", 403);

  return {
    sub,
    email: session.user.email ?? undefined,
    name: session.user.name ?? undefined,
    groups,
    isAdmin: admin,
  };
}

/** Admin for mutating actions: groups are re-fetched from Pocket ID, not read from the session. */
export async function requireAdmin(): Promise<Principal> {
  const principal = await requireViewer();

  const session = await getServerSession(authOptions);
  const accessToken = session?.accessToken;
  if (!accessToken) throw new AuthzError("Cannot verify group membership", 403);

  const expires = session?.accessTokenExpires;
  if (expires && expires * 1000 < Date.now()) {
    // The provider token the session carries has lapsed, so it can't be used to
    // re-check groups. Make the user sign in again rather than falling back to
    // the session's own copy of the claim.
    throw new AuthzError("Sign in again to confirm admin access", 401);
  }

  const groups = await fetchGroupsFromProvider(accessToken);
  if (!evaluateGroups(groups).admin) throw new AuthzError("Requires the admin group", 403);
  return { ...principal, groups, isAdmin: true };
}

let userinfoEndpoint: { url: string; fetchedAt: number } | undefined;

async function resolveUserinfoEndpoint(): Promise<string> {
  const base = process.env.POCKET_ID_URL?.replace(/\/$/, "");
  if (!base) throw new AuthzError("POCKET_ID_URL not configured", 403);

  if (userinfoEndpoint && Date.now() - userinfoEndpoint.fetchedAt < 10 * 60_000) {
    return userinfoEndpoint.url;
  }
  // Read the endpoint from OIDC discovery rather than assuming a path.
  const res = await fetch(`${base}/.well-known/openid-configuration`, { cache: "no-store" });
  if (!res.ok) throw new AuthzError("OIDC discovery failed", 403);
  const doc = (await res.json()) as { userinfo_endpoint?: string };
  if (!doc.userinfo_endpoint) throw new AuthzError("Provider has no userinfo endpoint", 403);
  userinfoEndpoint = { url: doc.userinfo_endpoint, fetchedAt: Date.now() };
  return doc.userinfo_endpoint;
}

async function fetchGroupsFromProvider(accessToken: string): Promise<string[]> {
  const res = await fetch(await resolveUserinfoEndpoint(), {
    headers: { Authorization: `Bearer ${accessToken}` },
    cache: "no-store",
  });
  if (!res.ok) throw new AuthzError("Group revalidation failed", 403);
  const claims = (await res.json()) as { groups?: unknown };
  return Array.isArray(claims.groups)
    ? claims.groups.filter((g): g is string => typeof g === "string")
    : [];
}

/** Maps an AuthzError to a JSON Response; rethrows anything else. */
export function authzResponse(err: unknown): Response {
  if (err instanceof AuthzError) {
    return Response.json({ error: err.message }, { status: err.status });
  }
  throw err;
}
