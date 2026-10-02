# Guide for apprentices

You develop jjforge in its own repository. This one runs it on the shared
cluster. <https://ops.nca-apprentices.dev> shows you how it runs, and lets you
try another image in dev.

## Get access

1. Accept the invitation to the `nca-apprentices` organization on GitHub.
2. Ask @kevin-nca to add you to the `dev` team.
3. Open <https://ops.nca-apprentices.dev> and sign in with GitHub.

## Find your way

jjforge runs at <https://jjforge-dev.nca-apprentices.dev> and
<https://jjforge.nca-apprentices.dev>, behind the same GitHub sign-in. The ops
page links to these tools:

| Tool         | Use it to                                                           |
| ------------ | ------------------------------------------------------------------- |
| Argo CD      | See which version runs where, sync `jjforge-dev`, and try an image  |
| Grafana      | Watch the metrics, and search the logs under Explore                |
| Headlamp     | Look at pods, events, and live logs                                 |
| VictoriaLogs | Search the logs of the last 30 days                                 |

To search the logs, start from these queries:

```text
{kubernetes.pod_namespace="jjforge-dev"}
{kubernetes.pod_namespace="jjforge-dev", kubernetes.container_name="server"} error
_time:1h {kubernetes.pod_namespace="jjforge-prod"}
```

## Try another image in dev

1. In Argo CD, open `jjforge-dev`, then App Details, Parameters, and Edit.
2. Set the image tag to any tag published to GHCR, and save. Argo CD deploys
   it.
3. To go back to the release in Git, remove the parameter again.

## Ship a release

1. Release jjforge from its repository. The release publishes a new chart.
2. Renovate opens a pull request here that raises `targetRevision` in
   `cluster/apps/jjforge/dev/application.yaml`.
3. Once @kevin-nca merges it, Argo CD deploys the release within a few minutes.
4. Once dev works, the same happens for `prod`.

Every other change is a pull request too. Never push to `main`, because Argo CD
applies whatever lands there.
