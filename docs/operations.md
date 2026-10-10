# Operating the cluster

This repository is the shared cluster on Hetzner, Talos, and Argo CD. The
platform, such as networking, ingress, storage, databases, and observability,
serves every app. Each app is an installation of released artifacts only,
never of paths in the app's own repository. A [preview](#previews) of a
jjforge PR is the one exception.

## Layout

One cluster runs every app. An app's environments, such as `dev` and `prod`,
are namespaces in it, named `<app>-<env>`.

| Path                                  | What it is                                          | Applied by                             |
| ------------------------------------- | --------------------------------------------------- | -------------------------------------- |
| `tofu/`                               | Network, firewall, volume, node, DNS roots          | `mise run apply`                       |
| `talos/`                              | Machine configuration, as talhelper input           | `mise run apply`                       |
| `cluster/bootstrap/`                  | Argo CD and the root Application                    | `mise run bootstrap`                   |
| `cluster/platform/`                   | One Argo CD Application per platform component      | Argo CD                                |
| `cluster/platform/manifests/`         | Plain manifests a platform Application points at    | Argo CD                                |
| `cluster/platform/charts/`            | Helm charts every environment renders               | Argo CD                                |
| `cluster/apps/<app>/<env>/`           | The namespace, AppProject, and Applications         | Argo CD                                |
| `cluster/apps/<app>/<env>/manifests/` | Plain manifests an app Application points at        | Argo CD                                |
| `cluster/apps/<app>/<env>/stores/`    | Helm values of the environment's stores             | Argo CD                                |
| `cluster/apps/<app>/<env>/network/`   | Helm values of its network policies                 | Argo CD                                |
| `cluster/apps/<app>/<env>/database/`  | Helm values of its Postgres cluster                 | Argo CD                                |
| `cluster/apps/jjforge/preview/`       | The ApplicationSets of jjforge's PR previews        | Argo CD                                |
| `secrets/bootstrap/`                  | SOPS-encrypted Secrets Argo CD needs to start       | `mise run bootstrap`                   |
| `secrets/platform/`                   | SOPS-encrypted platform credentials, as SopsSecrets | Argo CD                                |
| `secrets/apps/<app>/<env>/`           | SOPS-encrypted app credentials, as SopsSecrets      | Argo CD                                |
| `secrets/tofu.enc.env`                | SOPS-encrypted cloud credentials                    | `mise run apply`, `mise run bootstrap` |

The root Application syncs the files in `platform/`. Among them, the `apps`
ApplicationSet creates one Application per directory in `apps/<app>/`, named
`app-<app>-<env>`, which syncs the files directly in that directory. A
directory that isn't an environment works the same way.

Sync waves order the platform. Cilium comes first, then operators and storage,
then what runs on them, then the apps.

## Apps

Each environment of an app gets its own AppProject, such as `jjforge-prod`.
The project admits the app's chart and this repository as sources, the
environment's namespace as the only destination, and no cluster-scoped
objects. A `dev` Application can't deploy into `prod`. The namespace itself
lives in the environment's directory, where the `apps` ApplicationSet applies
it under the platform's project.

The platform also sets three limits in each environment's directory, outside
the app's reach:

- `network/values.yaml` sets the environment's network policies, which the
  `network` ApplicationSet renders from `platform/charts/network` under the
  platform's project. They admit ingress from the namespace itself and from the
  platform only. `jjforge-dev` can't reach `jjforge-prod`. Within the
  namespace, only the app's client, such as ncaleague's `backend`, reaches
  the database and Redpanda. Every pod reaches SeaweedFS's S3 port, which
  checks a key, and nothing else of it.
  Outbound, pods reach only their namespace, DNS, the API server, and the
  OpenTelemetry Collector, see [Telemetry](#telemetry). In `prod` the backups
  also reach their bucket, and no pod reaches anything else outside the
  cluster.
- `limits.yaml` holds a ResourceQuota and default requests. Dev also gets a
  default memory limit.
- `namespace.yaml` enforces the restricted Pod Security level, so every pod
  runs as non-root, without capabilities, and with seccomp.
- Prod pods set `priorityClassName: prod`, so they schedule ahead of dev and
  outlast it when the node runs short of memory.

Every dev environment admits members of the GitHub organization only. Its
`login.yaml` holds `github-login`, which asks `oauth2-proxy-apps` about every
request, and `application.yaml` names it in the chart's `ingress.middlewares`.
Each host signs in on its own, and the sign-in's cookie covers that host
alone, so a public prod app never receives it and can't replay a member's
session into dev. GitHub returns to the host's `/apps-oauth2/callback`, which
`platform/manifests/ops/apps-login.yaml` routes for the hosts behind the
login only. The ops portal has its own
sign-in, `oauth2-proxy`, with its own cookie on the ops host alone, so an app
that reads its cookie can't open the portal. Every jjforge environment's
`cookies.yaml` holds `no-cookies`, which removes the sign-in's cookie before a
request reaches the app, so code from a branch never reads a member's
session. Dev names it after `github-login`, and the public `jjforge-prod`
names it alone. ncaleague has none: the middleware removes every cookie, and
ncaleague needs its own, so ncaleague-dev sees the sign-in's cookie for its
host.

Each environment runs its own Redpanda and SeaweedFS, so no environment
reaches the topics and buckets of another. A file in the environment's
`stores/` directory, such as `stores/redpanda.yaml`, opts it in. The
ApplicationSet of the same name in `platform/` installs the store in the
environment's namespace, with the values in `platform/stores/` first and the
environment's file over them.

`database/values.yaml` gives an environment its Postgres cluster. The
`database` ApplicationSet renders it from `platform/charts/database` under
the environment's project, with WAL archiving and a nightly backup where
`backup` is on. Argo CD never deletes an environment's database cluster: the
volumes go with it. A preview's cluster sets `keep: false`, so it goes with
the preview.

Every ApplicationSet but the three of jjforge's previews keeps what it deployed
when one of its Applications disappears, such as after a renamed directory.

### Previews

A jjforge PR with the `preview` label runs at
`https://jjforge-pr-<number>.nca-apprentices.dev`, behind the GitHub login.
jjforge's CI pushes the images of the head commit of the PR, tagged with
the commit. The `jjforge-preview` ApplicationSet in `apps/jjforge/preview/` asks
GitHub for labeled PRs every minute and creates `jjforge-pr-<number>` from the
chart at that commit. Each new commit on the PR replaces the images in place.

A preview runs a PR's code, so it gets a namespace of its own,
`jjforge-pr-<number>`, and reaches no Secret of dev or of another preview. The
`jjforge-preview-environment` ApplicationSet creates the namespace from
`platform/charts/preview`, with its limits, `github-login`, and `no-cookies`,
and its network policies from `platform/charts/network`, under the platform's
project. The app and its database run there under a project of their own,
which admits that namespace alone and forbids `traefik.io` objects, so the PR's
chart can neither reach another namespace nor replace its login. The
`jjforge-preview-database` ApplicationSet gives it a Postgres cluster of its
own, `jjforge-pr-<number>-db`, because the chart migrates its database
before it deploys, and the migrations of a PR must never reach dev's
database. Its pods
request little, since the node has almost none left to give, and the node
evicts them first when memory runs short. cert-manager issues its certificate
from the Ingress. The certificate authority allows 50 per week for the whole
domain.

When the PR merges, closes, or loses the label, the ApplicationSets delete the
Applications, and Argo CD deletes the namespace with everything in it: pods,
Service, Ingress, certificate, and database cluster with its data.
cert-manager then deletes the TLS secret. Fork PRs get no preview, since their
CI can't push images.

### Deployments

Argo CD records each sync as a GitHub deployment, through the `deployment`
trigger in `cluster/bootstrap/kustomization.yaml`:

| Application           | Repository | Environment           | Reference                  |
| --------------------- | ---------- | --------------------- | -------------------------- |
| `jjforge-<env>`       | `jjforge`  | `jjforge-<env>`       | The tag `v<chart version>` |
| `jjforge-pr-<number>` | `jjforge`  | `jjforge-pr-<number>` | The head commit of the PR  |
| `app-<app>-<env>`     | `infra`    | `<app>-<env>`         | The infra commit synced    |

A deployment succeeds once its revision is synced and healthy, and fails when
the sync fails or the app degrades. A deleted preview turns its deployment
inactive. An Application opts in with the annotation
`notifications.argoproj.io/subscribe.deployment.github: ""`. The `infra-repo`
GitHub App writes them, so it needs Deployments write access and an
installation on each repository.

### Add an app or an environment

1. Copy `cluster/apps/jjforge/prod/` to `cluster/apps/<app>/<env>/`.
2. Replace `jjforge-prod` with `<app>-<env>` in every file, and point
   `application.yaml` at the app's chart and version. The host is
   `<app>.<domain>` in `prod` and `<app>-<env>.<domain>` elsewhere, which the
   wildcard DNS record already covers.
3. Keep only the stores the environment needs, and `database/` if it needs
   Postgres. In `network/values.yaml`, set `client` to the component label of
   the pods that use the database and Redpanda. Every environment keeps
   `cookies.yaml`. An environment for the public names `no-cookies` alone in
   `application.yaml`. Any other also takes `login.yaml` from
   `cluster/apps/jjforge/dev/`, names `github-login, no-cookies`, and adds its
   host to `platform/manifests/ops/apps-login.yaml`.
4. Add the environment's secrets under `secrets/apps/<app>/<env>/`, then run
   `mise run bootstrap` to apply them.
5. Merge. Argo CD picks the directory up without any other change.

A chart in a private registry needs a repository secret in `argocd` per
environment. Scope it with a `project: <app>-<env>` entry, so no other project
can use it.

## Changing it

- **A platform component:** add or edit a file in `platform/`. Argo CD syncs
  it on merge. Removing a file deletes what its Application created only when
  the Application has `resources-finalizer.argocd.argoproj.io`. The stateless
  tools have it. The operators, the stores, the policies, and Cilium don't, so
  removing or renaming one of their files leaves its resources running and
  can't delete data or the network. Delete those resources by hand.
- **An app release:** bump `targetRevision` in `dev/application.yaml`, then in
  `prod/application.yaml` once `dev` works. Renovate opens those PRs when a new
  chart is published.
- **Cloud:** edit `tofu/`, then `mise run apply`.
- **Talos configuration:** edit `talos/talconfig.yaml`, then `mise run talos`.
  It shows how the node's running configuration would change and applies it
  once you confirm. `mise run apply` doesn't reach the node: tofu ignores
  changes to the user data, which only a new node boots from.
- **Talos release:** set `talosVersion` in `talconfig.yaml`, then run
  `mise run image` for the next rebuild, and upgrade the node. The upgrade
  reboots it, and with one node every app is down until it returns. The
  image's schematic is empty, so the stock installer matches it:

  ```fish
  set -x TALOSCONFIG talos/clusterconfig/talosconfig
  set ip (sops exec-env secrets/tofu.enc.env "tofu -chdir=tofu output -raw node_ipv4")
  talosctl -e $ip -n $ip upgrade --image ghcr.io/siderolabs/installer:(yq .talosVersion talos/talconfig.yaml)
  ```

- **Kubernetes release:** after the Talos release that supports it, set
  `kubernetesVersion` in `talconfig.yaml`, then, with `TALOSCONFIG` and `ip`
  set as in the Talos release step:

  ```fish
  talosctl -e $ip -n $ip upgrade-k8s --to (yq .kubernetesVersion talos/talconfig.yaml)
  ```

  It updates the control plane and the node agent one component at a time.

`mise run check` validates all of it without credentials, and CI runs it on
every PR. CI also comments on every PR how each Argo CD Application's rendered
manifests change.

## Ops portal

<https://ops.nca-apprentices.dev> links to the tools below. Each has a host of
its own, so a flaw in one tool's pages can't act with a session in another, such
as Argo CD's. Only members of the `nca-apprentices` organization on GitHub
get in, and two of its teams grant more:

- `admins`: administrator in Argo CD and Grafana. Every operator belongs here.
- `dev`: the apprentices. They also sync `jjforge-dev` and `ncaleague-dev` and
  set their Helm parameters in Argo CD.

| Host                     | Tool             | Signs in with        | Everyone else in the organization                           |
| ------------------------ | ---------------- | -------------------- | ----------------------------------------------------------- |
| `argocd`                 | Argo CD          | Its own GitHub login | Reads                                                       |
| `grafana`                | Grafana          | Its own GitHub login | Reads, searches logs and traces in Explore, and sees alerts |
| `headlamp`               | Headlamp         | `oauth2-proxy`       | Reads everything except Secrets                             |
| `logs`                   | VictoriaLogs     | `oauth2-proxy`       | Searches the logs                                           |
| `redpanda-dev`           | Redpanda Console | `oauth2-proxy`       | Reads, writes, and deletes topics in `jjforge-dev`          |
| `seaweedfs-dev`          | SeaweedFS        | `oauth2-proxy`       | Changes buckets, files, and S3 users in `jjforge-dev`       |

The three logins share one GitHub OAuth app, so GitHub asks once. Grafana and
the portal's Argo CD link then go to GitHub and back without a click. Only
members of `admins` silence alerts, under Alerting in Grafana.
The prod stores have no UI.

Headlamp acts as its own account for everyone, bound to the `view` role. For
more, use kubectl. Argo CD has no administrator password, so kubectl is also the way
in when the GitHub login fails.

To see the flows the network policies drop, run `cilium hubble port-forward`,
then `hubble observe --verdict DROPPED`.

In `jjforge-dev`, a Helm parameter set in the Argo CD UI, such as an image tag,
stays until someone removes it. Git still sets the chart version and values.
The `apps` ApplicationSet grants that to `dev` directories only.

Argo CD reads its settings from `cluster/bootstrap/`, so a change there takes
`mise run bootstrap`, not a merge. The server reads `argocd-cmd-params-cm` only
when it starts, so a change to it also takes
`kubectl -n argocd rollout restart deployment argocd-server`.

## First install

Run the tasks from the repository root.

```text
mise run image      # upload the Talos release as a Hetzner snapshot
mise run apply      # generate the node config, create network, firewall, volume and node
mise run bootstrap  # bootstrap etcd, install Cilium, apply secrets, install Argo CD
```

Argo CD owns the cluster after that. [bootstrap.md](bootstrap.md) walks
through every step, including the credentials, and adding and removing
operators.

## Secrets

Encrypted with SOPS and age. Run `sops` from the repository root, where
`.sops.yaml` lives. The cloud credentials and the Talos secrets are decrypted
on the operator's machine while a task runs. The cluster's secrets are
decrypted in the cluster, see [In the cluster](#in-the-cluster).

### Escrow

The age private key exists in one place, offline: printed and stored
physically, plus on a hardware key. Load it into `SOPS_AGE_KEY_FILE` only while
a task runs.

Losing it means every encrypted file in this repository is scrap and every
secret has to be reissued. That is recoverable but slow, which is the point of
writing it down here rather than discovering it during an outage.

The cluster key needs no escrow of its own. Its private half is in
`secrets/bootstrap/sops-age.enc.yaml`, which the escrow key decrypts.

### Created once, by hand

1. The age key: `age-keygen`, put the private half in escrow and the public
   half in `keys` and every rule of `.sops.yaml`.
2. The tofu state bucket `nca-tofu` in Hetzner Object Storage, `nbg1`.
3. `secrets/tofu.enc.env`, a dotenv file with the variables below,
   encrypted with `sops --encrypt --in-place`.
4. The Talos cluster secrets: `talhelper gensecret >
   talos/talsecret.sops.yaml`, then encrypt it the same way.
5. One Object Storage key per backup bucket in [Backups](#backups), in the
   same project as `nca-tofu`. Hetzner has no API for keys.

| Variable                           | What it is                                                                   |
| ---------------------------------- | ---------------------------------------------------------------------------- |
| `TF_VAR_hcloud_token`              | Hetzner Cloud API token with read and write access                           |
| `TF_VAR_cloudflare_api_token`      | Cloudflare API token that edits the zone, its DNS, its settings, and its WAF |
| `TF_VAR_cloudflare_account_id`     | ID of the Cloudflare account                                                 |
| `TF_VAR_operator_cidrs`            | Where talosctl and kubectl run from, as a list                               |
| `AWS_ACCESS_KEY_ID`                | Object Storage key for the tofu state and buckets                            |
| `AWS_SECRET_ACCESS_KEY`            | Object Storage secret for the tofu state and buckets                         |
| `TF_VAR_object_storage_project_id` | Numeric ID of the Hetzner project                                            |
| `TF_VAR_backup_keys`               | Access key per backup bucket, as `{"metrics"="...", ...}`                    |

### Secrets that must exist before the first sync

`mise run bootstrap` applies each file in `secrets/bootstrap/`. It also creates
every namespace a file under `secrets/` names, since the `secrets` Application
syncs before the Applications that own most of them.

| Secret       | Namespace | What it is                                                 |
| ------------ | --------- | ---------------------------------------------------------- |
| `infra-repo` | `argocd`  | GitHub App key Argo CD reads this repository with          |
| `sops-age`   | `sops`    | The cluster key, which decrypts the secrets in the cluster |

To change one, `sops edit` the file and run `mise run bootstrap`.

### In the cluster

Every other secret is a `SopsSecret` under `secrets/platform/` or
`secrets/apps/`. The `secrets` Application syncs them, and
sops-secrets-operator in the `sops` namespace decrypts each into the Secret of
the same name, with the cluster key.

| Secret                        | Namespace       | Directory               | What it is                                                 |
| ----------------------------- | --------------- | ----------------------- | ---------------------------------------------------------- |
| `argocd-notifications-secret` | `argocd`        | `platform/`             | The `infra-repo` GitHub App key, which records deployments |
| `<store>-backup-s3`           | The store's     | See [Backups](#backups) | The store's key for its backup bucket                      |
| `seaweedfs-s3-config`         | `<app>-<env>`   | `apps/<app>/<env>/`     | The S3 identities and the buckets each may use             |
| `argocd-github`               | `argocd`        | `platform/`             | The GitHub OAuth 2.0 app of the ops portal                 |
| `grafana-github`              | `observability` | `platform/`             | The same OAuth 2.0 app                                     |
| `oauth2-proxy`                | `ops`           | `platform/`             | The same OAuth 2.0 app, and a cookie secret                |
| `oauth2-proxy-apps`           | `ops`           | `platform/`             | The apps' OAuth 2.0 app, and a cookie secret               |
| `github-alerts`               | `observability` | `platform/`             | The token that opens alert issues, see [Alerts](#alerts)   |
| `status-heartbeat`            | `observability` | `platform/`             | The token Watchdog posts to the status page with           |

To change a secret, `sops edit` its file, then commit and push. The operator
updates the Secret as soon as Argo CD syncs the file. A pod that reads the Secret as
environment variables needs a restart. To add one, convert the Secret and
encrypt it:

```sh
kubectl -n <namespace> create secret generic <name> --from-literal <key>=<value> \
  --dry-run=client -o yaml | yq --from-file secrets/sopssecret.yq \
  > secrets/<dir>/<name>.enc.yaml
sops --encrypt --in-place secrets/<dir>/<name>.enc.yaml
```

If the operator can't decrypt a file, the Secret keeps its last data, and the
`secrets` Application turns Degraded, which opens an `ArgoAppUnhealthy` issue.

Four limits keep the cluster key from reaching more than the cluster holds:

- `.sops.yaml` encrypts only the files under `secrets/platform/` and
  `secrets/apps/` to it, never `secrets/bootstrap/`, the cloud credentials,
  or the Talos secrets.
- The operator decrypts a `SopsSecret` into whatever namespace holds it, and
  doesn't check the sops MAC. A copy of an encrypted file would decrypt in any
  namespace its author can read. So only the `secrets` Application may create
  a `SopsSecret`: the `sopssecrets` admission policy checks Argo CD's tracking
  annotation, and the app projects deny the kind.
- The `sops` namespace accepts no connections and reaches the API server
  alone.
- Only `admins` read Secrets in `sops`. Headlamp hides Secrets, and Argo CD
  masks their data.

Replace the cluster key when it leaks or an operator leaves:

1. Create a new key as [bootstrap.md](bootstrap.md#5-create-the-cluster-secrets)
   describes, and replace the `cluster` key in `.sops.yaml` with its public
   half.
2. Re-encrypt the cluster's secrets to it, and rotate each credential they
   hold, since the old key reads every earlier version in Git:

   ```fish
   for f in secrets/platform/**.enc.yaml secrets/apps/**.enc.yaml
       sops updatekeys --yes $f
   end
   ```

3. Run `mise run bootstrap`, then commit and push. Until the push, the
   operator fails on the old files and keeps the Secrets as they are.

## Backups

The cluster keeps state in six stores. Each backs itself up to its own
Hetzner bucket in `fsn1`, away from the node in `nbg1`. Everything else is
rebuilt from this repository, so nothing else is backed up.

| Store                   | Bucket                              | Method                                            | Loses at most                 | Secret                                    |
| ----------------------- | ----------------------------------- | ------------------------------------------------- | ----------------------------- | ----------------------------------------- |
| jjforge-prod Postgres   | `nca-backup-jjforge-prod-db`        | WAL and nightly base backups through Barman Cloud | Seconds                       | `jjforge-backup-s3` in `jjforge-prod`     |
| ncaleague-prod Postgres | `nca-backup-ncaleague-prod-db`      | WAL and nightly base backups through Barman Cloud | Seconds                       | `ncaleague-backup-s3` in `ncaleague-prod` |
| jjforge-prod SeaweedFS  | `nca-backup-jjforge-prod-seaweedfs` | `weed filer.backup` mirrors every change          | Seconds                       | `seaweedfs-backup-s3` in `jjforge-prod`   |
| jjforge-prod Redpanda   | `nca-backup-jjforge-prod-redpanda`  | Redpanda Connect copies every record              | Seconds, and consumer offsets | `redpanda-backup-s3` in `jjforge-prod`    |
| VictoriaMetrics         | `nca-backup-metrics`                | `vmbackup` nightly                                | A day                         | `metrics-backup-s3` in `observability`    |
| VictoriaLogs            | `nca-backup-logs`                   | Partition snapshots and `rclone` nightly          | A day                         | `logs-backup-s3` in `observability`       |

`tofu/backup.tf` creates the buckets. Each bucket keeps replaced and deleted
objects for 30 days, and its policy admits only its store's key and the tofu
key. Each secret holds `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and
`AWS_REGION`.

Dev stores have no backup. The `BackupJobStale`, `BackupMirrorDown`,
`WalArchivingFailing`, and `BaseBackupStale` alerts fire when a backup stops,
see [Alerts](#alerts).

### Restore

Every store restores itself. A store whose volume is empty, as every one is on
a new node, takes its last backup before it serves anything, and a store that
holds data is left alone:

- Postgres bootstraps from its base backup and the WAL after it. Each prod
  `database/values.yaml` counts the cluster's `generation`, and a lost cluster
  comes back as the next one, see the chart's values. That is the one edit a
  node move takes.
- The metrics and logs stores run an init container that copies the backup in
  when the volume is empty, see `cluster/platform/observability.yaml` and
  `logs.yaml`.
- SeaweedFS and Redpanda run a Job once per cluster, next to their backups in
  `apps/jjforge/prod/manifests/backup/`, which copies the mirror back when the
  store is empty. Redpanda's recreates the topics as they were and replays
  every record. Consumer offsets are lost. A Job runs once, so a store lost
  on a running cluster needs its Job deleted. Argo CD creates it again, and
  the guard decides.

The node move of 2026-10-08 proved the Postgres path. To prove another store's,
scale it down right after its nightly backup, delete its volume, and let it
come back.

A store that collected since the loss can't take the copy, as it would replace
what the store holds. `mise run restore metrics <until>` and
`mise run restore logs` merge the backup into the running store through its
API instead, which takes hours per gigabyte. `until` is when the store started
collecting, so nothing arrives twice.

[encrypt-disks.md](encrypt-disks.md) explains what the disk encryption
covers and when it applies.

## Telemetry

An app sends traces, metrics, and logs over OTLP to the OpenTelemetry
Collector in `platform/telemetry.yaml`. It sets two environment variables,
and the Collector adds the pod, namespace, and workload:

```text
OTEL_EXPORTER_OTLP_ENDPOINT=http://telemetry.observability.svc:4318
OTEL_SERVICE_NAME=<app>-<component>
```

| Signal  | Also arrives through                        | Store           | Kept    | Backup  |
| ------- | ------------------------------------------- | --------------- | ------- | ------- |
| Traces  |                                             | VictoriaTraces  | 7 days  | None    |
| Metrics | A `VMPodScrape` in `scrapes.yaml`           | VictoriaMetrics | 90 days | Nightly |
| Logs    | Container output, read by the log collector | VictoriaLogs    | 30 days | Nightly |

The Collector only receives, so every pod in the cluster reaches it on ports
4317 and 4318. The stores stay out of reach. In Grafana, a log line with a
`trace_id` field links to its trace. `TelemetryExportFailing` fires when a
store refuses what the Collector sends.

Beyla, in `platform/ebpf-collector.yaml`, traces the HTTP, gRPC, SQL, Redis,
and Kafka calls of every app in a `-dev` or `-prod` namespace through eBPF,
without a change to the app. It sends the spans to the Collector, and writes
request rate, error, and duration metrics to VictoriaMetrics.

## Alerts

The rules live in `cluster/platform/manifests/alerts/`, next to the scrapes and
the `nca overview` dashboard in Grafana. Every alert except the info alerts
opens an issue labeled `alert` in this repository, and the issue closes when
the alert resolves. Watch the repository to get the notifications.

<https://status.nca-apprentices.dev> shows the uptime of the production
apps and of the alert pipeline. A Cloudflare Worker in
[nca-apprentices/status](https://github.com/nca-apprentices/status) checks
the apps every 10 seconds, so it keeps working when the node is down.
Alertmanager posts the always-firing `Watchdog` to it every minute, and the
page shows the alert pipeline down after 5 minutes without a post. An outage
there opens an issue labeled `alert` in this repository as well, so a dead
alert pipeline still reaches people.

The `status-heartbeat` secret holds the token Alertmanager sends, the same as
the Worker's `HEARTBEAT_TOKEN`. To rotate it, set `token` with
`sops edit secrets/platform/status-heartbeat.enc.yaml`, then commit and push.
Then set the same token in the Worker with `mise run secret` in the status
repository. Alertmanager reads the file on each send, so it needs no
restart.

`github-alerts` holds a fine-grained token that expires. When it expires, alerts
stop opening issues without any error in Grafana. To renew it:

1. As an organization owner, create a fine-grained token on GitHub with
   `nca-apprentices` as the resource owner, access to `infra` only, and
   read and write access to Issues. Remind the admins team a week before it
   expires.
2. Set `token` with `sops edit secrets/platform/github-alerts.enc.yaml`,
   then commit and push. Once Argo CD has synced, restart the receiver:

   ```sh
   kubectl -n observability rollout restart deployment github-alerts
   ```

3. Set the same token in the status Worker with `mise run github` in the
   status repository.
