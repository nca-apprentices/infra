# Bootstrapping the cluster

The first install of this repository onto the existing Hetzner Cloud server,
step by step. [operations.md](operations.md) explains the layout and day-to-day
changes.

Run every command from the repository root, in fish. `mise install` installs
every tool the steps use.

```fish
mise install
set ip 2.28.199.18    # public IPv4 of the node
set server 167807597  # Hetzner server ID
```

## 1. Create the age keys

The escrow key recovers everything. Your own key is the one you work with.
`age-keygen` prints each public key.

```fish
age-keygen -o escrow.age.txt
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/nca.txt
set -x SOPS_AGE_KEY_FILE ~/.config/sops/age/nca.txt
```

In `.sops.yaml`, put the two public keys in `keys`, the escrow key first, each
anchored under a name, and in every rule. Put
`escrow.age.txt` in escrow as [operations.md](operations.md#escrow) describes,
then delete the local copy.

## 2. Create the accounts and credentials

| Credential                                         | Where                                      |
| -------------------------------------------------- | ------------------------------------------ |
| Hetzner Cloud API token with read and write access | Console, project, Security, API tokens     |
| Bucket `nca-tofu` in `nbg1`, and an S3 key pair    | Console, Object Storage                    |
| Cloudflare account on the Free plan, and its ID    | `dash.cloudflare.com`, Account home        |
| Cloudflare API token, see below                    | `dash.cloudflare.com`, Profile, API Tokens |
| One S3 key pair per backup bucket, six in all      | Console, Object Storage                    |
| The project's numeric ID                           | Console, the project's URL                 |

The Cloudflare token is a custom token that may edit Zone, DNS, Zone
Settings, and Zone WAF, for all zones of the account, and Workers Scripts, for
the account. Editing Zone lets tofu create the zone. Zone WAF lets it set the
rate limit. Workers Scripts lets it put the status page's Worker on
`status.nca-apprentices.dev`.

## 3. Write the tofu credentials

Write the file, then encrypt it before anything else reads the directory.

```fish
mkdir -p secrets
$EDITOR secrets/tofu.enc.env
sops --encrypt --in-place secrets/tofu.enc.env
```

```sh
TF_VAR_hcloud_token=...
TF_VAR_cloudflare_api_token=...
TF_VAR_cloudflare_account_id=...
TF_VAR_operator_cidrs=["203.0.113.7/32"]
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
TF_VAR_object_storage_project_id=...
TF_VAR_backup_keys={"jjforge-prod-db"="...","ncaleague-prod-db"="...","jjforge-prod-seaweedfs"="...","jjforge-prod-redpanda"="...","metrics"="...","logs"="..."}
```

`TF_VAR_backup_keys` names each backup key by its access key only. The secret
halves go into the cluster secrets in step 5.

## 4. Generate the Talos secrets

```fish
talhelper gensecret >talos/talsecret.sops.yaml
sops --encrypt --in-place talos/talsecret.sops.yaml
```

## 5. Create the cluster secrets

`mise run bootstrap` applies the Secrets in `secrets/bootstrap/` before Argo CD
starts. Every other secret is a SopsSecret, which Argo CD syncs and
sops-secrets-operator decrypts with the cluster key, as
[operations.md](operations.md#in-the-cluster) describes. Argo CD reads this
repository as a GitHub App, since the organization allows no deploy keys. The apps' charts and images on GHCR
are public, so pulling them takes no credentials.

Create the app at
<https://github.com/organizations/nca-apprentices/settings/apps/new>: no
webhook, and installable only on this account. Set the Contents and Pull
requests repository permissions to read-only, and Deployments to read and
write. Note its App ID, generate a private key, and install it on the `infra`
and `jjforge` repositories only. The installation ID is the number at the end
of the installation's settings URL. Argo CD reads `infra` with it, lists
jjforge's PRs for previews, and records each deployment in `jjforge`.

The cluster key comes first. Put the public key it prints in `.sops.yaml` as
the `cluster` key, so the files below are encrypted to it:

```fish
mkdir -p secrets/bootstrap secrets/platform secrets/apps/jjforge/prod \
    secrets/apps/jjforge/dev secrets/apps/ncaleague/prod
age-keygen 2>/dev/null |
    kubectl create secret generic sops-age --namespace sops \
        --from-file keys.txt=/dev/stdin --dry-run=client -o yaml \
    >secrets/bootstrap/sops-age.enc.yaml
yq '.data["keys.txt"]' secrets/bootstrap/sops-age.enc.yaml | base64 -d | age-keygen -y
```

```fish
set app_id 123456             # App ID
set installation_id 12345678  # installation ID
set app_key ~/Downloads/nca-argocd.*.private-key.pem
```

```fish
kubectl create secret generic infra-repo --namespace argocd \
    --from-literal type=git \
    --from-literal url=https://github.com/nca-apprentices/infra.git \
    --from-literal githubAppID=$app_id \
    --from-literal githubAppInstallationID=$installation_id \
    --from-file githubAppPrivateKey=$app_key \
    --dry-run=client -o yaml |
    kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    >secrets/bootstrap/infra-repo.enc.yaml
kubectl create secret generic argocd-notifications-secret --namespace argocd \
    --from-literal github-appID=$app_id \
    --from-literal github-installationID=$installation_id \
    --from-file github-privateKey=$app_key \
    --dry-run=client -o yaml |
    yq --from-file secrets/sopssecret.yq >secrets/platform/argocd-notifications-secret.enc.yaml
```

The SeaweedFS S3 identities, one set per environment. Every S3 request needs a
key, and an app's identity reaches only its own bucket. Start with an
administrator identity:

```fish
for env in prod dev
    set ak (openssl rand -hex 16)
    set sk (openssl rand -base64 30 | tr -d '/+=')
    printf '{"identities":[{"name":"admin","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","List","Tagging","Write"]}]}' $ak $sk |
        kubectl create secret generic seaweedfs-s3-config --namespace jjforge-$env \
            --from-file seaweedfs_s3_config=/dev/stdin \
            --dry-run=client -o yaml |
        yq --from-file secrets/sopssecret.yq >secrets/apps/jjforge/$env/seaweedfs-s3-config.enc.yaml
end
set -e ak sk
```

Each store's backup key, from step 2, into the store's namespace:

```fish
function backup-secret -a name namespace dir
    read -P "$name access key: " key
    read -s -P "$name secret key: " secret
    kubectl create secret generic $name --namespace $namespace \
        --from-literal AWS_ACCESS_KEY_ID=$key \
        --from-literal AWS_SECRET_ACCESS_KEY=$secret \
        --from-literal AWS_REGION=fsn1 \
        --dry-run=client -o yaml |
        yq --from-file secrets/sopssecret.yq >secrets/$dir/$name.enc.yaml
end

backup-secret jjforge-backup-s3 jjforge-prod apps/jjforge/prod
backup-secret ncaleague-backup-s3 ncaleague-prod apps/ncaleague/prod
backup-secret seaweedfs-backup-s3 jjforge-prod apps/jjforge/prod
backup-secret redpanda-backup-s3 jjforge-prod apps/jjforge/prod
backup-secret metrics-backup-s3 observability platform
backup-secret logs-backup-s3 observability platform
```

The GitHub login of `ops.nca-apprentices.dev`, which Argo CD, Grafana, and
`oauth2-proxy` share. Create an OAuth 2.0 app at
<https://github.com/organizations/nca-apprentices/settings/applications/new>
with the homepage `https://ops.nca-apprentices.dev`, add these callback URLs,
and generate a client secret:

- `https://ops.nca-apprentices.dev/argocd/api/dex/callback`
- `https://ops.nca-apprentices.dev/grafana/login/github`
- `https://ops.nca-apprentices.dev/oauth2/callback`

```fish
read -P 'OAuth client ID: ' id
read -s -P 'OAuth client secret: ' secret

kubectl create secret generic argocd-github --namespace argocd \
    --from-literal clientID=$id \
    --from-literal clientSecret=$secret \
    --dry-run=client -o yaml |
    kubectl label --local -f - app.kubernetes.io/part-of=argocd -o yaml |
    yq --from-file secrets/sopssecret.yq >secrets/platform/argocd-github.enc.yaml

kubectl create secret generic grafana-github --namespace observability \
    --from-literal clientID=$id \
    --from-literal clientSecret=$secret \
    --dry-run=client -o yaml |
    yq --from-file secrets/sopssecret.yq >secrets/platform/grafana-github.enc.yaml

kubectl create secret generic oauth2-proxy --namespace ops \
    --from-literal client-id=$id \
    --from-literal client-secret=$secret \
    --from-literal cookie-secret=(openssl rand -hex 16) \
    --dry-run=client -o yaml |
    yq --from-file secrets/sopssecret.yq >secrets/platform/oauth2-proxy.enc.yaml
```

The GitHub login of the app environments has an OAuth 2.0 app of its own, so
its cookie, which every app host receives, never opens the ops portal. Create
a second app the same way, with the homepage `https://ops.nca-apprentices.dev`
and the callback URL `https://ops.nca-apprentices.dev/apps-oauth2/callback`:

```fish
read -P 'OAuth client ID: ' id
read -s -P 'OAuth client secret: ' secret

kubectl create secret generic oauth2-proxy-apps --namespace ops \
    --from-literal client-id=$id \
    --from-literal client-secret=$secret \
    --from-literal cookie-secret=(openssl rand -hex 16) \
    --dry-run=client -o yaml |
    yq --from-file secrets/sopssecret.yq >secrets/platform/oauth2-proxy-apps.enc.yaml
```

Encrypt them all, remove the plain-text key, and commit `.sops.yaml`,
`secrets/`, and `talos/talsecret.sops.yaml`:

```fish
for f in secrets/**.enc.yaml
    sops --encrypt --in-place $f
end
rm $app_key
set -e secret
```

## 6. Set the domain and publish the release

Set `domain` in `tofu/terraform.tfvars`, and replace `example.com` in
every `cluster/apps/*/*/application.yaml` with it.

Argo CD deploys the chart version in each `cluster/apps/<app>/*/application.yaml`,
so that version must exist before the first sync. If a release is missing, tag
it in a clone of the app's repository, such as
[nca-apprentices/jjforge](https://github.com/nca-apprentices/jjforge), next to
this one. Each app's release workflow publishes its images, its chart, and a
GitHub release:

```fish
for app in jjforge ncaleague
    set version v(yq .spec.source.targetRevision cluster/apps/$app/prod/application.yaml)
    git -C ../$app tag -s $version -m $version
    git -C ../$app push origin $version
    gh run watch -R nca-apprentices/$app
end
```

## 7. Upload the Talos image

```fish
mise run image
```

## 8. Put the server under tofu

Do this before the rebuild. Talos waits for its configuration on port 50000,
and the firewall must already limit that port to the operator addresses.

In the console, detach every firewall from the server. Then:

```fish
talhelper genconfig \
    --config-file talos/talconfig.yaml \
    --secret-file talos/talsecret.sops.yaml \
    --out-dir talos/clusterconfig
sops exec-env secrets/tofu.enc.env "
    export TF_VAR_s3_access_key=\$AWS_ACCESS_KEY_ID TF_VAR_s3_secret_key=\$AWS_SECRET_ACCESS_KEY &&
    tofu -chdir=tofu init -input=false &&
    tofu -chdir=tofu import 'hcloud_server.node[0]' $server
"
mise run apply
```

Before you confirm, read the plan. It updates the server in place, with a new
name and the private network, and creates the network, the subnet, the
firewall, the volume, and the Cloudflare zone with its records. If it replaces
the server, answer no.

At Porkbun, the registrar, set the domain's name servers to the
`cloudflare_name_servers` output, in the domain's Details. Then add the DS
record of the `dnssec_ds` output under DNSSEC there.

## 9. Rebuild the server with Talos

In the console, open the server, then Rebuild, Snapshots, and pick the
snapshot labeled `os=talos`. The rebuild erases Ubuntu.

Talos boots without a configuration. Once the first command answers, send it
one. The node installs itself and reboots.

```fish
talosctl get disks --insecure -n $ip
talosctl apply-config --insecure -n $ip \
    --file talos/clusterconfig/nca-nca-1.yaml
```

## 10. Bootstrap the cluster

```fish
mise run bootstrap
```

## 11. Check the result

```fish
set -x TALOSCONFIG (pwd)/talos/clusterconfig/talosconfig
talosctl config endpoint $ip
talosctl config node $ip

talosctl health
kubectl -n argocd get applications
```

Every application reaches `Synced` and `Healthy`.
<https://ops.nca-apprentices.dev> links to Argo CD and the other tools, as
[operations.md](operations.md#ops-portal) describes.

## Operators

An operator holds three things: an age key, which decrypts the secrets, an
address in the firewall, and a Talos client certificate, which also yields a
Kubernetes kubeconfig with full access.

### Add an operator

1. The new operator creates an age key and sends its public key and their IPv4
   address:

   ```fish
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/nca.txt
   ```

2. An existing operator adds the public key to `keys` in `.sops.yaml`,
   anchored under its owner's name, and to every rule. Then they re-encrypt
   every file to the new set of keys:

   ```fish
   for f in secrets/**.enc.* talos/talsecret.sops.yaml
       sops updatekeys --yes $f
   end
   ```

3. Add the address to `TF_VAR_operator_cidrs`, then apply:

   ```fish
   sops edit secrets/tofu.enc.env
   mise run apply
   ```

4. Issue a Talos client certificate and encrypt it to the new operator's key:

   ```fish
   set name alice
   talosctl config new $name.talosconfig --roles os:admin --crt-ttl 2160h
   age -r age1<their key> -o $name.talosconfig.age $name.talosconfig
   rm $name.talosconfig
   ```

5. Commit and push `.sops.yaml` and the re-encrypted files, and send
   `$name.talosconfig.age` to the new operator.

6. The new operator sets up access:

   ```fish
   set -x SOPS_AGE_KEY_FILE ~/.config/sops/age/nca.txt
   mkdir -p ~/.talos talos/clusterconfig
   age -d -i $SOPS_AGE_KEY_FILE -o ~/.talos/nca alice.talosconfig.age
   set -x TALOSCONFIG ~/.talos/nca
   talosctl config endpoint 2.28.199.18
   talosctl config node 2.28.199.18

   talosctl kubeconfig talos/clusterconfig/kubeconfig
   kubectl config set-cluster nca --server https://2.28.199.18:6443
   ```

### Remove an operator

1. Remove their key from `.sops.yaml` and run the `sops updatekeys` loop.
2. Rotate every credential in `secrets/`, and replace the cluster key as
   [operations.md](operations.md#in-the-cluster) describes. They could read
   them in plain text.
3. Remove their address from `TF_VAR_operator_cidrs` and run `mise run apply`.
4. Talos can't revoke one client certificate, but the firewall already cuts
   them off. For full revocation, rotate the cluster CAs with
   `talosctl rotate-ca`.

### App users

Accounts inside an app, such as jjforge users and their SSH keys, belong to
that app, not to this repository. jjforge has none yet.
