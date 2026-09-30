# Operating the cluster

This repository is the shared cluster on Hetzner, Talos, and Argo CD. The
platform, such as networking, ingress, storage, databases, and observability,
serves every app. Each app is an installation of released artifacts only,
never of paths in the app's own repository.

## Layout

One cluster runs every app. An app's environments, such as `dev` and `prod`,
are namespaces in it, named `<app>-<env>`.

| Path                                     | What it is                                         | Applied by                             |
| ---------------------------------------- | -------------------------------------------------- | -------------------------------------- |
| `tofu/`                                  | Network, firewall, volume, node, DNS roots         | `mise run apply`                       |
| `talos/`                                 | Machine configuration, as talhelper input          | `mise run apply`                       |
| `cluster/bootstrap/`                     | Argo CD and the root Application                   | `mise run bootstrap`                   |
| `cluster/platform/`                      | One Argo CD Application per platform component     | Argo CD                                |
| `cluster/platform/manifests/`            | Plain manifests a platform Application points at   | Argo CD                                |
| `cluster/apps/<app>/<env>/`              | The namespace, AppProject, and Applications        | Argo CD                                |
| `cluster/apps/<app>/<env>/manifests/`    | Plain manifests an app Application points at       | Argo CD                                |
| `secrets/platform/`                      | SOPS-encrypted platform credentials                | `mise run bootstrap`                   |
| `secrets/apps/<app>/<env>/`              | SOPS-encrypted app credentials                     | `mise run bootstrap`                   |
| `secrets/tofu.enc.env`                   | SOPS-encrypted cloud credentials                   | `mise run apply`, `mise run bootstrap` |

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

- `network-policy.yaml` admits ingress from the namespace itself and from the
  platform only. `jjforge-dev` can't reach `jjforge-prod`.
- `limits.yaml` holds a ResourceQuota and default requests. Dev also gets a
  default memory limit.
- Prod pods set `priorityClassName: prod`, so they schedule ahead of dev and
  outlast it when the node runs short of memory. The jjforge chart needs a value
  for it before its own pods do.

The data plane in the `storage` namespace admits only namespaces labeled
`nca/data-plane: "true"`. An app that needs the object store sets that label
on its namespace.

### Add an app or an environment

1. Copy `cluster/apps/jjforge/prod/` to `cluster/apps/<app>/<env>/`.
2. Replace `jjforge-prod` with `<app>-<env>` in every file, and point
   `application.yaml` at the app's chart and version. The host is
   `<app>.<domain>` in `prod` and `<app>-<env>.<domain>` elsewhere, which the
   wildcard DNS record already covers.
3. Keep only the manifests the environment needs, such as a database.
4. Add the environment's secrets under `secrets/apps/<app>/<env>/`, then run
   `mise run bootstrap` to apply them.
5. Merge. Argo CD picks the directory up without any other change.

A chart in a private registry needs a repository secret in `argocd` per
environment. Scope it with a `project: <app>-<env>` entry, so no other project
can use it.

## Changing it

- **A platform component:** add or edit a file in `platform/`. Argo CD syncs
  it on merge.
- **An app release:** bump `targetRevision` in `dev/application.yaml`, then in
  `prod/application.yaml` once `dev` works. Renovate opens those PRs when a new
  chart is published.
- **Cloud or Talos:** edit `tofu/` or `talos/`, then `mise run apply`.

`mise run check` validates all of it without credentials, and CI runs it on
every PR.

## Ops portal

<https://ops.nca-apprentices.dev> links to the tools below. Only members of
the `nca-apprentices` organization on GitHub get in, and two of its teams
grant more:

- `admins`: administrator in Argo CD and Grafana. Every operator belongs here.
- `dev`: the apprentices. They also sync `jjforge-dev` and set its Helm
  parameters in Argo CD.

| Path        | Tool          | Signs in with          | Everyone else in the organization         |
| ----------- | ------------- | ---------------------- | ----------------------------------------- |
| `/argocd`   | Argo CD       | Its own GitHub login   | Reads                                     |
| `/grafana`  | Grafana       | Its own GitHub login   | Reads, and searches the logs in Explore   |
| `/headlamp` | Headlamp      | `oauth2-proxy`         | Reads everything except Secrets           |
| `/logs`     | VictoriaLogs  | `oauth2-proxy`         | Searches the logs                         |

Headlamp acts as its own account for everyone, bound to the `view` role. For
more, use kubectl. Argo CD has no administrator password, so kubectl is also the way
in when the GitHub login fails.

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

Encrypted with SOPS and age, and decrypted on the operator's machine while a
task runs. Run `sops` from the repository root, where `.sops.yaml` lives.

### Escrow

The age private key exists in one place, offline: printed and stored
physically, plus on a hardware key. Load it into `SOPS_AGE_KEY_FILE` only while
a task runs.

Losing it means every encrypted file in this repository is scrap and every
secret has to be reissued. That is recoverable but slow, which is the point of
writing it down here rather than discovering it during an outage.

### Created once, by hand

1. The age key: `age-keygen`, put the private half in escrow and the public
   half in the `recipients` list of `.sops.yaml`.
2. The tofu state bucket `nca-tofu` in Hetzner Object Storage, `nbg1`.
3. `secrets/tofu.enc.env`, a dotenv file with the variables below,
   encrypted with `sops --encrypt --in-place`.
4. The Talos cluster secrets: `talhelper gensecret >
   talos/talsecret.sops.yaml`, then encrypt it the same way.
5. One Object Storage key per backup bucket in [Backups](#backups), in the
   same project as `nca-tofu`. Hetzner has no API for keys.

| Variable                           | What it is                                                  |
| ---------------------------------- | ----------------------------------------------------------- |
| `TF_VAR_hcloud_token`              | Hetzner Cloud API token with read and write access          |
| `TF_VAR_porkbun_api_key`           | Porkbun API key                                             |
| `TF_VAR_porkbun_secret_key`        | Porkbun secret key                                          |
| `TF_VAR_operator_cidrs`            | Where talosctl and kubectl run from, as a list              |
| `AWS_ACCESS_KEY_ID`                | Object Storage key for the tofu state and buckets           |
| `AWS_SECRET_ACCESS_KEY`            | Object Storage secret for the tofu state and buckets        |
| `TF_VAR_object_storage_project_id` | Numeric ID of the Hetzner project                           |
| `TF_VAR_backup_keys`               | Access key per backup bucket, as `{"seaweedfs"="...", ...}` |

### Secrets that must exist before the first sync

`mise run bootstrap` applies every `*.enc.yaml` under `secrets/`, each
into the namespace it names, and creates that namespace first.

| Secret                | Namespace       | Directory               | What it is                                        |
| --------------------- | --------------- | ----------------------- | ------------------------------------------------- |
| `infra-repo`          | `argocd`        | `platform/`             | GitHub App key Argo CD reads this repository with |
| `jjforge-<env>-chart` | `argocd`        | `apps/jjforge/<env>/`   | GHCR token Argo CD pulls the chart with           |
| `ghcr`                | `jjforge-<env>` | `apps/jjforge/<env>/`   | GHCR token the jjforge images are pulled with     |
| `<store>-backup-s3`   | The store's     | See [Backups](#backups) | The store's key for its backup bucket             |
| `argocd-github`       | `argocd`        | `platform/`             | The GitHub OAuth 2.0 app of the ops portal        |
| `grafana-github`      | `observability` | `platform/`             | The same OAuth 2.0 app                            |
| `oauth2-proxy`        | `ops`           | `platform/`             | The same OAuth 2.0 app, and a cookie secret       |

Everything else in the cluster comes from Git.

## Backups

The cluster keeps state in five stores. Each backs itself up to its own
Hetzner bucket in `fsn1`, away from the node in `nbg1`. Everything else is
rebuilt from this repository, so nothing else is backed up.

| Store                 | Bucket                       | Method                                            | Loses at most                 | Secret                                 |
| --------------------- | ---------------------------- | ------------------------------------------------- | ----------------------------- | -------------------------------------- |
| jjforge-prod Postgres | `nca-backup-jjforge-prod-db` | WAL and nightly base backups through Barman Cloud | Seconds                       | `jjforge-backup-s3` in `jjforge-prod`  |
| SeaweedFS             | `nca-backup-seaweedfs`       | `weed filer.backup` mirrors every change          | Seconds                       | `seaweedfs-backup-s3` in `storage`     |
| Redpanda              | `nca-backup-redpanda`        | Redpanda Connect copies every record              | Seconds, and consumer offsets | `redpanda-backup-s3` in `streaming`    |
| VictoriaMetrics       | `nca-backup-metrics`         | `vmbackup` nightly                                | A day                         | `metrics-backup-s3` in `observability` |
| VictoriaLogs          | `nca-backup-logs`            | Partition snapshots and `rclone` nightly          | A day                         | `logs-backup-s3` in `observability`    |

`tofu/backup.tf` creates the buckets. Each bucket keeps replaced and deleted
objects for 30 days, and its policy admits only its store's key and the tofu
key. Each secret holds `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and
`AWS_REGION`.

Dev databases have no backup. The `BackupJobStale`, `BackupMirrorDown`, and
`WalArchivingFailing` alerts fire when a backup stops. No alert receiver is set
up yet, so they show in vmalert and Grafana only.

The quarterly [restore drill](restore-drill.md) restores each store.
