---
title: "API key portal"
---

The key portal is the self-service LiteLLM virtual-key surface at `https://portal.<domain>`. It is
protected by Dex through oauth2-proxy forward-auth, then it trusts the `X-Auth-Request-Email` header
that oauth2-proxy injects. A NetworkPolicy only allows the gateway data plane to reach the portal
Service, so clients cannot bypass the SSO header path.

## What it does

The deployed chart is `litellm-key-portal` `0.2.0`. For the signed-in user it can:

- list their own keys
- create a key with a label, budget cap, budget duration, and model allowlist
- rotate a key and show the new plaintext once
- revoke a key after confirmation

Ownership is enforced server-side by querying LiteLLM for keys scoped to the signed-in email before any
rotate or revoke. The portal holds the LiteLLM master key in-cluster; the master key never leaves the
server.

An empty first screen means the user has no self-service keys yet. It does not mean lifecycle support is
absent.

## Sign out

The portal itself is stateless. Browser login state is the oauth2-proxy cookie, so sign-out is handled by
oauth2-proxy:

```text
https://portal.<domain>/oauth2/sign_out?rd=https://portal.<domain>/
```

If the browser still has a Dex session, the next login may be silent. For a full identity-provider logout,
also end the Dex or upstream IdP session.

## Known UX gaps

The current portal is functional, not polished. Product work still worth doing:

- visible sign-out control instead of requiring the oauth2-proxy URL
- clearer empty state when there are no keys
- copy-to-clipboard for newly created or rotated keys
- better grouping for spend, budget, and model allowlist

These are portal chart/application changes, not Kubernetes wiring changes.
