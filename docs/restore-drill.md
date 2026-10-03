# Restore drill

Run quarterly. Time it, write the number down, and compare it with the last
run: an untested backup is a guess, and a backup whose restore takes a day is a
different product than one whose restore takes an hour.

The drill restores every store from [Backups](operations.md#backups) into a
scratch target in the running cluster, and never touches the originals. After a
real loss, the same steps restore into the originals. Each step runs with the
store's backup key, from the secret named in that table.

## Postgres and SeaweedFS

Blobs and rows are backed up separately, so the only real test is a page that
needs both.

1. Copy `jjforge-backup-s3` and `seaweedfs-backup-s3` into `jjforge-dev`. The
   drill runs there, next to dev's own stores.
2. Create an `ObjectStore` like
   `cluster/apps/jjforge/prod/manifests/database/object-store.yaml` in
   `jjforge-dev`, and a CNPG `Cluster` named `drill-db` that bootstraps from
   it:

   ```yaml
   bootstrap:
     recovery:
       source: jjforge-db
   externalClusters:
     - name: jjforge-db
       plugin:
         name: barman-cloud.cloudnative-pg.io
         parameters:
           barmanObjectName: jjforge-db
           serverName: jjforge-db
   ```

3. Wait for `Cluster in healthy state`, then run
   `SELECT count(*) FROM review_round;` and compare with production.
4. Copy the SeaweedFS mirror into a scratch bucket. `rclone copy` from
   `nca-backup-jjforge-prod-seaweedfs/<bucket>` to the `drill` bucket in dev's
   SeaweedFS.
5. Point a throwaway jjforge release in `jjforge-dev` at both, open one change
   with more than one round, and check that a round diff renders.

## Postgres for ncaleague

1. Copy `ncaleague-backup-s3` into `ncaleague-dev`.
2. Create the `ObjectStore` and the `drill-db` `Cluster` there as for jjforge,
   with `ncaleague-db` in place of `jjforge-db`.
3. Wait for `Cluster in healthy state`, then run
   `SELECT count(*) FROM goals;` and compare with production.

## Redpanda

1. Copy `redpanda-backup-s3` into `jjforge-dev`, and create each topic in dev's
   Redpanda as `drill.<topic>` with the partition count it has in production.
2. Run Redpanda Connect once in `jjforge-dev` with the label
   `app: redpanda-backup`, which the `redpanda` network policy admits, and
   this pipeline. It reads the
   objects in key order, so each partition's records arrive in offset order.
   Record headers travel as metadata, and the control values start with an
   underscore, so a header whose name does too is lost:

   ```yaml
   input:
     aws_s3:
       bucket: nca-backup-jjforge-prod-redpanda
       endpoint: https://fsn1.your-objectstorage.com
       region: fsn1
       force_path_style_urls: true
   pipeline:
     processors:
       - mapping: |
           let path = @s3_key.split("/")
           meta = this.headers.or({})
           meta _topic = "drill." + $path.index(0)
           meta _partition = $path.index(1)
           meta _key = this.key
           root = this.value.decode("base64")
   output:
     kafka_franz:
       seed_brokers: [redpanda:9093]
       tls: { enabled: true, root_cas_file: /etc/redpanda-tls/ca.crt }
       topic: ${! @_topic }
       partitioner: manual
       partition: ${! @_partition }
       key: ${! @_key }
       metadata: { include_patterns: ["^[^_]"] }
       max_in_flight: 1
   ```

3. Compare each topic's high watermark with production.

## VictoriaMetrics

1. Run `vmrestore -src=s3://nca-backup-metrics/latest
   -customS3Endpoint=https://fsn1.your-objectstorage.com
   -storageDataPath=/data` in a pod with an empty volume at `/data`.
2. Start `victoria-metrics -storageDataPath=/data` on that volume and query a
   series from last week.

## VictoriaLogs

1. `rclone copy` one day, `nca-backup-logs/<YYYYMMDD>`, into
   `/storage/partitions/<YYYYMMDD>` of a scratch VictoriaLogs that isn't
   running.
2. Start it and query that day.

## Record

Wall-clock time per store, and anything that had to be done by hand. Delete
`drill-db`, the `drill` bucket, the `drill.` topics, the copied secrets, and the
scratch pods from `jjforge-dev` and `ncaleague-dev` afterwards.
