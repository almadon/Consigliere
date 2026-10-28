import type { NextAuthOptions } from "next-auth";

// Pocket ID (https://github.com/pocket-id/pocket-id) speaks standard OIDC,
// so this is a generic OAuth provider pointed at its discovery document
// rather than anything Pocket-ID-specific.
//
// The `groups` scope/claim gates access -- see lib/authz.ts.
// NOTE: `profile()` below assumes standard OIDC claims (sub/name/email/
// picture) - verify against what Pocket ID's userinfo endpoint actually
// returns on first login and adjust if needed.
export const authOptions: NextAuthOptions = {
  providers: [
    {
      id: "pocket-id",
      name: "Pocket ID",
      type: "oauth",
      wellKnown: `${process.env.POCKET_ID_URL}/.well-known/openid-configuration`,
      clientId: process.env.POCKET_ID_CLIENT_ID,
      clientSecret: process.env.POCKET_ID_CLIENT_SECRET,
      authorization: { params: { scope: "openid email profile groups" } },
      idToken: true,
      checks: ["pkce", "state"],
      profile(profile: { sub: string; name?: string; preferred_username?: string; email?: string; picture?: string }) {
        return {
          id: profile.sub,
          name: profile.name ?? profile.preferred_username ?? profile.sub,
          email: profile.email,
          image: profile.picture,
        };
      },
    },
  ],
  // Short on purpose: group membership is re-validated for mutating actions
  // (lib/authz.ts), but a short session limits the blast radius of the rest.
  session: { strategy: "jwt", maxAge: 60 * 60 * 8 },
  callbacks: {
    async jwt({ token, account, profile }) {
      if (account) {
        token.accessToken = account.access_token;
        token.accessTokenExpires = account.expires_at;
      }
      if (profile) {
        const p = profile as { sub?: string; groups?: unknown };
        token.sub = p.sub ?? token.sub;
        token.groups = Array.isArray(p.groups)
          ? p.groups.filter((g): g is string => typeof g === "string")
          : [];
      }
      return token;
    },
    async session({ session, token }) {
      session.user.sub = token.sub as string;
      // Convenience only -- never the basis for an admin decision (lib/authz.ts).
      session.user.groups = token.groups ?? [];
      session.accessToken = token.accessToken;
      session.accessTokenExpires = token.accessTokenExpires;
      return session;
    },
  },
  secret: process.env.NEXTAUTH_SECRET,
};
