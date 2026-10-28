# diagrams/

draw.io files. Open them in [app.diagrams.net](https://app.diagrams.net) or the
draw.io desktop app. Each is plain, uncompressed XML, so a change shows up as a
readable diff.

| Diagram | Shows | Read it when |
|---|---|---|
| [architecture](architecture.drawio) | What runs where, and what talks to what: the lab, the cluster, GitHub, AWS, Cloudflare, Slack | You are new here, or explaining the lab to someone who is |
| [argocd](argocd.drawio) | Every Argo CD Application in sync-wave order, and why the order matters | Adding an Application, or a rebuild hangs on a wave |
| [access-controls](access-controls.drawio) | Five enforcement layers, outside in, and what each cannot see | Changing a firewall, ufw or NetworkPolicy rule, or the tunnel |
| [security-awareness](security-awareness.drawio) | What generates a signal, where it lands, who it reaches | Adding a detector, or asking "would we notice?" |
| [shift-left](shift-left.drawio) | Every gate between a keystroke and a change in AWS or the cluster | Changing CI, a required check, or an SCP |
| [access](access.drawio) | The bootstrap order, from the first SSH key to remote access | Building from nothing; see also [REBUILD.md](../docs/REBUILD.md) |

All six were brought up to date on 2026-10-28. The wave ladder in `argocd` was
generated from `cluster/argocd/applications/*.yaml`; regenerate it rather than
hand-editing when Applications change. The prose companion to the three
security diagrams is [docs/08-security.md](../docs/08-security.md).
