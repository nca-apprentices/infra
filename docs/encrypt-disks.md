# Encrypt the disks

Run once, to move the node built before `talos/talconfig.yaml` asked for
LUKS2 onto encrypted volumes. Talos encrypts a volume only when it creates
it, so the node is rebuilt and every production store comes back from its
backup. Dev stores have no backup and come back empty.

Every app is down from step 3 until its store is restored. Don't run
`talosctl apply-config` with the new configuration on the old node: its
volumes exist in plain text and would no longer mount.

## 1. Take fresh backups

A base backup of each production database, so recovery replays little WAL:

```fish
for app in jjforge ncaleague
    printf '%s\n' \
        'apiVersion: postgresql.cnpg.io/v1' \
        'kind: Backup' \
        "metadata: { name: $app-db-encrypt, namespace: $app-prod }" \
        'spec:' \
        "  cluster: { name: $app-db }" \
        '  method: plugin' \
        '  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }' |
        kubectl apply -f -
end
kubectl -n observability create job --from=cronjob/metrics-backup metrics-encrypt
kubectl -n observability create job --from=cronjob/logs-backup logs-encrypt
```

Wait until both `Backup`s are `completed` and both Jobs succeed. The
SeaweedFS and Redpanda mirrors trail by seconds, and no `BackupMirrorDown`
alert may fire.

## 2. Prepare the database recovery

Barman refuses to archive into a path that already holds a server's WAL, so
each restored database archives under a new server name. In both
`cluster/apps/<app>/prod/manifests/database/cluster.yaml`, replace
`bootstrap` and `plugins` with the following, shown for ncaleague:

```yaml
bootstrap:
  recovery:
    source: origin
    database: ncaleague
    owner: ncaleague
externalClusters:
  - name: origin
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: ncaleague-db
        serverName: ncaleague-db
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: ncaleague-db
      serverName: ncaleague-db-2
```

Open the PR, but merge it in step 3, once the old cluster is gone. Update
`serverName` in [restore-drill.md](restore-drill.md) to match.

## 3. Rebuild the node

1. Run `mise run apply`. It regenerates `talos/clusterconfig`. Tofu ignores
   changes to the user data, so it leaves the server alone.
2. Rebuild the server from the Talos snapshot, as in
   [bootstrap.md](bootstrap.md#9-rebuild-the-server-with-talos). Before
   `apply-config`, wipe the data volume, which `get disks` lists with the
   model `Volume`:

   ```fish
   talosctl get disks --insecure -n $ip
   talosctl wipe disk --insecure -n $ip <device>
   ```

3. Merge the PR from step 2.
4. Run [bootstrap.md](bootstrap.md#10-bootstrap-the-cluster) steps 10 and
   11.
5. Check that `talosctl get volumestatus -o yaml` reports
   `encryptionProvider: luks2` for `STATE`, `EPHEMERAL`, and `u-data`.

## 4. Restore the stores

Follow [restore-drill.md](restore-drill.md) into the originals instead of the
scratch targets:

- **Postgres** recovers on its own. Wait for `Cluster in healthy state` and
  compare the row counts from step 1.
- **SeaweedFS:** `rclone copy` each bucket from
  `nca-backup-jjforge-prod-seaweedfs/<bucket>` into the same bucket in
  production.
- **Redpanda:** create each topic with its partition count and replay it as
  the drill does, with `meta _topic = $path.index(0)` so records land in the
  original topics.
- **VictoriaMetrics and VictoriaLogs** hold history only. Restore them if the
  history matters.

## 5. Record

Note the downtime and anything done by hand, then delete the `*-encrypt`
Backups and Jobs.
