# Restoring a CNPG Postgres cluster from Backblaze B2

Every CNPG cluster archives WAL continuously and takes a daily base backup to the
`vingilot-cnpg-backups` B2 bucket via the Barman Cloud CNPG-I plugin. This is how
you get data back out.

Validated end-to-end against `harbor-postgresql` on 2026-08-14: a full restore
into a scratch cluster completed in **~2 minutes** and matched production exactly
(49 tables, 3 `project` rows, timestamps identical to the microsecond).

> Restores are rare enough that the details go stale. Trust the commands here only
> as far as they match the current manifests in `kubernetes/apps/<app>/`.

## Before you start

You do **not** restore in place. You bootstrap a *new* Cluster from the object
store, verify it, and then decide what to do with it. The original is untouched
throughout, which is what makes this safe to practise.

Two facts that change how you read everything below:

- **`ObjectStore` is namespaced**, and the plugin resolves `barmanObjectName`
  against the Cluster's own namespace. The restore Cluster must therefore live in
  the **same namespace** as the source — that is how it reaches the existing
  ObjectStore and B2 credential without copying secrets around.
- **Backup CRs are only Kubernetes-side records.** Deleting them does not touch
  B2, and recovery does not consult them — barman lists the bucket directly. If
  `kubectl get backup` is empty, that says nothing about what is restorable.

## Restore to the latest available point

Apply this with `kubectl` directly. It is throwaway — do **not** commit it, or
Flux will keep recreating it.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: harbor-restoretest        # any name except the live one
  namespace: harbor               # MUST match the source cluster's namespace
spec:
  instances: 1
  storage:
    size: 8Gi                     # >= the source's storage
    storageClass: nfs-scratch
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {memory: 512Mi}
  bootstrap:
    recovery:
      source: origin
  # NO spec.plugins here, deliberately. A clone with an archiver would write
  # into the live cluster's object store alongside the real backups.
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: harbor-postgresql-b2
          # REQUIRED. serverName defaults to THIS cluster's name, which has no
          # backups — omit it and recovery silently looks in the wrong prefix.
          serverName: harbor-postgresql
```

Watch it come up:

```sh
kubectl -n harbor get cluster harbor-restoretest \
  -o jsonpath='{.status.phase} ready={.status.readyInstances}{"\n"}'
```

It walks `Setting up primary` → `Waiting for the instances to become active` →
`Cluster in healthy state`.

## Point-in-time recovery

Same manifest, plus a target under `bootstrap.recovery`:

```yaml
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "2026-08-13T18:30:00Z"   # always use an explicit Z
```

The target must fall after a base backup and inside the archived WAL range.
Bare timestamps are interpreted as UTC, but upstream flags the ambiguity — write
the `Z`.

Other targets exist (`targetLSN`, `targetXID`, `targetName`), but `targetTime` is
the one you want for "undo what happened at 14:05".

## Verify before trusting it

Compare against the source rather than eyeballing that it started:

```sh
for c in harbor-postgresql harbor-restoretest; do
  echo "-- $c"
  kubectl -n harbor exec $c-1 -c postgres -- psql -U postgres -d registry -tAc \
    "select count(*) from information_schema.tables where table_schema='public'"
done
```

Then check a table with real rows in it, not just the schema.

## Promoting a restore to be the real cluster

If the restore is the one you want to keep, the live cluster has to be replaced —
apps connect by service name (`<cluster>-rw`), so the names matter.

1. Scale the consuming app to zero so nothing writes to the old database.
2. Delete the old `Cluster`, remove its manifest from git, and let Flux prune.
3. Rebuild the restore under the original name (a Cluster cannot be renamed),
   this time *with* its `plugins` stanza so it resumes archiving.
4. Scale the app back up.

Do not skip step 3's plugin stanza — a promoted cluster without an archiver is a
cluster with no backups.

## Per-cluster gotchas

- **immich** — a restore Cluster **must** pin the same image as production
  (`ghcr.io/tensorchord/cloudnative-vectorchord:16.9-0.4.3`) plus
  `postgresql.shared_preload_libraries: [vchord.so]`. Replaying its WAL needs
  `vchord.so` loadable; the operator's default image fails to start.
- **yavanna** — its ObjectStore and ScheduledBackup live in the homelab repo, but
  the Cluster itself is in `github.com/swerdick/yavanna` under `deploy/`.

## Cleaning up a drill

```sh
kubectl -n harbor delete cluster harbor-restoretest
```

`nfs-scratch` sets `archiveOnDelete: true`, so the PVC directory is **renamed,
not deleted**. Clear it or it accumulates:

```sh
ssh nfs "sudo rm -rf /scratch/k3s-pvs/archived-harbor-harbor-restoretest-*"
```

## When a restore will not start

- **`serverName` wrong or missing** — barman looks in a prefix that does not
  exist and finds no base backup. The single most likely mistake.
- **Sidecar OOMKilled** — surfaces as `rpc error: code = Unavailable ... EOF`,
  which looks like a network fault. Check the container's `lastState` for exit
  137. The limit lives in `instanceSidecarConfiguration.resources` (currently
  512Mi; measured peaks are 64–135Mi).
- **Editing sidecar resources does nothing on a running cluster** — CNPG reports
  "Cluster in healthy state" while pods keep their old limits. Force it:
  `kubectl -n <ns> annotate cluster <c> cnpg.io/restartedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite`
- **`status.firstRecoverabilityPoint` is always empty.** The plugin does not
  maintain CNPG's in-tree status fields. Use the bucket, or the
  `barman_cloud_cloudnative_pg_io_*` metrics — not that field.

## Reading the bucket directly

Sometimes the fastest answer to "is there actually a backup" is to look:

```sh
eval "$(sops --decrypt kubernetes/apps/_shared/cnpg-b2-credentials.yaml \
  | awk '/ACCESS_KEY_ID:/{print "export AWS_ACCESS_KEY_ID="$2}
         /ACCESS_SECRET_KEY:/{print "export AWS_SECRET_ACCESS_KEY="$2}' | head -2)"

aws s3 ls --endpoint-url https://s3.us-east-005.backblazeb2.com \
  s3://vingilot-cnpg-backups/ --recursive
```

Layout is `<cluster>/base/<timestamp>/data.tar.gz` and `<cluster>/wals/...`.
A `base/<ts>/` holding only `backup.info` with no `data.tar.gz` is the residue of
a failed backup, not a usable one.
