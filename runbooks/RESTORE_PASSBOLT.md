# Restore Passbolt

Passbolt restore requires the database plus the `passbolt-gpg` and `passbolt-jwt` PVCs. These volumes contain server-side cryptographic material, so treat both as mandatory and restore them as one consistency set.

## Preconditions

- `backup-passbolt-db`, `backup-passbolt-gpg`, and `backup-passbolt-jwt` have recent successful snapshots.
- `secrets/production.enc.yaml` has been applied.
- The target PVCs exist: `passbolt-db`, `passbolt-gpg`, and `passbolt-jwt`.
- Users are blocked from changing passwords or secrets during the maintenance window.

Check backup state:

```bash
kubectl -n apps get cronjob backup-passbolt-db backup-passbolt-gpg backup-passbolt-jwt
kubectl -n apps create job --from=cronjob/backup-passbolt-db backup-passbolt-db-manual
kubectl -n apps create job --from=cronjob/backup-passbolt-gpg backup-passbolt-gpg-manual
kubectl -n apps create job --from=cronjob/backup-passbolt-jwt backup-passbolt-jwt-manual
kubectl -n apps logs -f job/backup-passbolt-db-manual
kubectl -n apps logs -f job/backup-passbolt-gpg-manual
kubectl -n apps logs -f job/backup-passbolt-jwt-manual
```

## Restore Passbolt Data PVC

Scale Passbolt down before writing restored files:

```bash
kubectl -n apps scale deploy/passbolt --replicas=0
```

Restore the latest PVC snapshot:

```bash
RESTORE_TAG=passbolt-gpg TARGET_PVC=passbolt-gpg CONFIRM_RESTORE=yes make restore-volume
RESTORE_TAG=passbolt-jwt TARGET_PVC=passbolt-jwt CONFIRM_RESTORE=yes make restore-volume
kubectl -n apps get jobs -l app.kubernetes.io/component=restore
```

For a specific snapshot, add `RESTIC_SNAPSHOT=<snapshot-id>`.

## Restore Database

Start the database and keep Passbolt stopped:

```bash
kubectl -n data scale deploy/passbolt-db --replicas=1
kubectl -n data rollout status deploy/passbolt-db
```

Create a restore Job. The init container pulls the SQL dump from Restic, then the MariaDB client container imports it into the running database:

```bash
kubectl -n apps apply -f - <<'MANIFEST'
apiVersion: batch/v1
kind: Job
metadata:
  name: passbolt-db-restore
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      initContainers:
        - name: restic-restore
          image: restic/restic:0.18.1@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76
          command: ["/bin/sh", "-ec"]
          args:
            - restic restore latest --tag passbolt-db --target /restore
          envFrom:
            - secretRef:
                name: backup-s3-secret
          env:
            - name: RESTIC_CACHE_DIR
              value: /cache
          volumeMounts:
            - name: restore
              mountPath: /restore
            - name: cache
              mountPath: /cache
      containers:
        - name: mariadb-import
          image: mariadb:10.11.18@sha256:161be354206906ea8584929bde5ac59cdce0770fbfd5dd76131429f7dd80aab5
          command: ["/bin/sh", "-ec"]
          args:
            - |
              sql_file="$(find /restore/backup -name 'passbolt-*.sql' | sort | tail -1)"
              test -n "${sql_file}"
              mariadb -h passbolt-db.data.svc.cluster.local -u passbolt passbolt < "${sql_file}"
          env:
            - name: MARIADB_PWD
              valueFrom:
                secretKeyRef:
                  name: passbolt-secret
                  key: PASSBOLT_DB_PASSWORD
          volumeMounts:
            - name: restore
              mountPath: /restore
              readOnly: true
      volumes:
        - name: restore
          emptyDir: {}
        - name: cache
          emptyDir: {}
MANIFEST
kubectl -n apps logs -f job/passbolt-db-restore
```

For a specific snapshot, replace `latest` in the Job manifest with the snapshot ID.

Clean up:

```bash
kubectl -n apps delete job passbolt-db-restore
```

## Validate

```bash
kubectl -n apps scale deploy/passbolt --replicas=1
kubectl -n apps rollout status deploy/passbolt
kubectl -n apps logs deploy/passbolt --tail=100
```

Confirm login, user key access, email delivery, and password decrypt operations. Do not close the incident until new manual database, GPG, and JWT backup jobs all succeed.
