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

In `.sops.yaml`, put the two public keys in the `recipients` list, the escrow
key first, each with a comment that names it. Put
`escrow.age.txt` in escrow as [operations.md](operations.md#escrow) describes,
then delete the local copy.

## 2. Create the accounts and credentials

| Credential                                         | Where                                  |
| -------------------------------------------------- | -------------------------------------- |
| Hetzner Cloud API token with read and write access | Console, project, Security, API tokens |
| Bucket `nca-tofu` in `nbg1`, and an S3 key pair    | Console, Object Storage                |
| Porkbun API key and secret key                     | `porkbun.com`, Account, API Access     |
| API access for the domain                          | `porkbun.com`, the domain's Details    |
| One S3 key pair per backup bucket, five in all     | Console, Object Storage                |
| The project's numeric ID                           | Console, the project's URL             |

## 3. Write the tofu credentials

Write the file, then encrypt it before anything else reads the directory.

```fish
mkdir -p secrets
$EDITOR secrets/tofu.enc.env
sops --encrypt --in-place secrets/tofu.enc.env
```

```sh
TF_VAR_hcloud_token=...
TF_VAR_porkbun_api_key=...
TF_VAR_porkbun_secret_key=...
TF_VAR_operator_cidrs=["203.0.113.7/32"]
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
TF_VAR_object_storage_project_id=...
TF_VAR_backup_keys={"jjforge-prod-db"="...","seaweedfs"="...","redpanda"="...","metrics"="...","logs"="..."}
```

`TF_VAR_backup_keys` names each backup key by its access key only. The secret
halves go into the cluster secrets in step 5.

## 4. Generate the Talos secrets

```fish
talhelper gensecret >talos/talsecret.sops.yaml
sops --encrypt --in-place talos/talsecret.sops.yaml
```

## 5. Create the cluster secrets

`mise run bootstrap` applies every `*.enc.yaml` under `secrets/` before
Argo CD starts. Argo CD reads this private repository with a read-only deploy
key, and the cluster pulls the jjforge chart and images from GHCR with a token.

```fish
mkdir -p secrets/platform secrets/apps/jjforge/prod secrets/apps/jjforge/dev
ssh-keygen -t ed25519 -N '' -C argocd@nca -f argocd-deploy
gh repo deploy-key add argocd-deploy.pub --repo nca-apprentices/infra --title argocd
```

Create a classic token with only the `read:packages` scope at
<https://github.com/settings/tokens/new?scopes=read:packages>, then:

```fish
read -s -P 'GHCR token: ' token

kubectl create secret generic infra-repo --namespace argocd \
    --from-literal type=git \
    --from-literal url=git@github.com:nca-apprentices/infra.git \
    --from-file sshPrivateKey=argocd-deploy \
    --dry-run=client -o yaml |
    kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    >secrets/platform/infra-repo.enc.yaml

for env in prod dev
    kubectl create secret generic jjforge-$env-chart --namespace argocd \
        --from-literal type=oci \
        --from-literal url=oci://ghcr.io/nca-apprentices/charts/jjforge \
        --from-literal project=jjforge-$env \
        --from-literal username=kevin-nca \
        --from-literal password=$token \
        --dry-run=client -o yaml |
        kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
        >secrets/apps/jjforge/$env/jjforge-chart.enc.yaml

    kubectl create secret docker-registry ghcr --namespace jjforge-$env \
        --docker-server ghcr.io \
        --docker-username kevin-nca \
        --docker-password $token \
        --dry-run=client -o yaml >secrets/apps/jjforge/$env/ghcr.enc.yaml
end
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
        --dry-run=client -o yaml >secrets/$dir/$name.enc.yaml
end

backup-secret jjforge-backup-s3 jjforge-prod apps/jjforge/prod
backup-secret seaweedfs-backup-s3 storage platform
backup-secret redpanda-backup-s3 streaming platform
backup-secret metrics-backup-s3 observability platform
backup-secret logs-backup-s3 observability platform
```

Encrypt them all, remove the plain-text key, and commit `.sops.yaml`,
`secrets/`, and `talos/talsecret.sops.yaml`:

```fish
for f in secrets/**.enc.yaml
    sops --encrypt --in-place $f
end
rm argocd-deploy argocd-deploy.pub
set -e token
```

## 6. Set the domain and publish the release

Set `domain` in `tofu/terraform.tfvars`, and replace `example.com` in
every `cluster/apps/*/*/application.yaml` with it.

Argo CD deploys the chart version in `cluster/apps/jjforge/*/application.yaml`,
so that version must exist before the first sync. In a clone of
[nca-apprentices/jjforge](https://github.com/nca-apprentices/jjforge), tag it:

```fish
git tag v0.1.0
git push origin v0.1.0
gh run watch
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
    tofu -chdir=tofu init -input=false &&
    tofu -chdir=tofu import 'hcloud_server.node[0]' $server
"
mise run apply
```

Before you confirm, read the plan. It updates the server in place, with a new
name and the private network, and creates the network, the subnet, the
firewall, the volume, and two DNS records. If it replaces the server, answer
no.

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
set -x KUBECONFIG (pwd)/talos/clusterconfig/kubeconfig
talosctl config endpoint $ip
talosctl config node $ip

talosctl health
kubectl -n argocd get applications
```

Every application reaches `Synced` and `Healthy`. To open the Argo CD UI at
<https://localhost:8080>, sign in as `admin` with this password:

```fish
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

## Known gaps

- The `seaweedfs` Application configures no S3 identities, so any namespace
  admitted to the data plane can read and write every bucket.

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

2. An existing operator adds the public key to the `recipients` list in
   `.sops.yaml`, with a comment that names its owner, then re-encrypts every
   file to the new set of keys:

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
   mkdir -p ~/.talos ~/.kube
   age -d -i $SOPS_AGE_KEY_FILE -o ~/.talos/nca alice.talosconfig.age
   set -x TALOSCONFIG ~/.talos/nca
   talosctl config endpoint 2.28.199.18
   talosctl config node 2.28.199.18

   set -x KUBECONFIG ~/.kube/nca
   talosctl kubeconfig $KUBECONFIG
   kubectl config set-cluster nca --server https://2.28.199.18:6443
   ```

### Remove an operator

1. Remove their key from `.sops.yaml` and run the `sops updatekeys` loop.
2. Rotate every credential in `secrets/`. They could read them in plain
   text.
3. Remove their address from `TF_VAR_operator_cidrs` and run `mise run apply`.
4. Talos can't revoke one client certificate, but the firewall already cuts
   them off. For full revocation, rotate the cluster CAs with
   `talosctl rotate-ca`.

### App users

Accounts inside an app, such as jjforge users and their SSH keys, belong to
that app, not to this repository. jjforge has none yet.
