// Cloudflare Worker serving the cluster's OIDC discovery documents at
// https://oidc.eightbitsaxlounge.com, in front of the S3 bucket the cluster
// publishes into.
//
// Deploy: Cloudflare dashboard -> Workers & Pages -> Create -> paste this,
// then add a route for oidc.<domain>/*. Full instructions and the DNS record
// it needs: docs/06-aws-federation.md.
//
// Why a Worker and not a CNAME to S3:
//
//   - The bucket policy denies aws:SecureTransport=false, so the S3 *website*
//     endpoint (HTTP-only) is refused outright. That closes off the usual
//     "CNAME to the website endpoint with Flexible SSL" shortcut, which is
//     just as well — it would put the discovery document on a plaintext hop.
//   - The S3 *REST* endpoint speaks HTTPS but presents a certificate for
//     *.s3.<region>.amazonaws.com. Proxying to it by CNAME means either an
//     Enterprise-only SNI override, or dropping to Full (non-strict) SSL and
//     no longer validating the origin at all.
//   - A Worker fetches the origin by its real hostname, so TLS validates
//     normally end to end, and it re-states the two-path allowlist that the
//     bucket policy already enforces. Defence in depth on the one thing that
//     matters here: this hostname must never become a general file host.
//
// Load is negligible. STS caches the JWKS, so this serves a handful of
// requests a day and sits far inside the free tier.

const ORIGIN_HOST = "nineteenseventytwo-oidc-972034964468.s3.eu-west-2.amazonaws.com";

// Exactly the two paths the OIDC protocol defines. Anything else is 404 —
// not proxied and then denied by S3, but never sent upstream at all.
const ALLOWED_PATHS = new Set([
  "/.well-known/openid-configuration",
  "/openid/v1/jwks",
]);

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("method not allowed", {
        status: 405,
        headers: { allow: "GET, HEAD" },
      });
    }

    if (!ALLOWED_PATHS.has(url.pathname)) {
      return new Response("not found", { status: 404 });
    }

    const origin = `https://${ORIGIN_HOST}${url.pathname}`;

    // Five minutes at the edge. Long enough that STS almost never reaches S3,
    // short enough that republishing after a signing-key rotation propagates
    // before anything times out. Do not raise this without also revisiting the
    // rotation runbook: a stale JWKS during a rotation is a total outage of
    // the cluster's AWS access, not a degradation.
    const response = await fetch(origin, {
      method: request.method,
      cf: { cacheTtl: 300, cacheEverything: true },
    });

    if (!response.ok) {
      // Do not pass S3's XML error body through. It names the bucket and the
      // request id, which is more than a public endpoint needs to say.
      return new Response("not found", { status: 404 });
    }

    return new Response(response.body, {
      status: 200,
      headers: {
        "content-type": "application/json",
        "cache-control": "public, max-age=300",
        "x-content-type-options": "nosniff",
      },
    });
  },
};
