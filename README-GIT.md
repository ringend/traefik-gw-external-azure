# traefik external gateway backup repo

This folder is intended to be pushed to `ringend/traefik-gw-external-azeus2` as a backup of non-secret Traefik configuration and scripts.

The live local gateway folder remains the source of truth. GitHub is only the backup copy of files that are safe to store there.

## What belongs in the repo

- `docker-start.sh`
- `traefik-gateway-external.service`
- `README.txt`
- `config/traefik.yml`
- `config/routes.yml`
- non-secret files under `config-backup/`
- `.gitignore`
- this `README-GIT.md`

## What stays local

- `data/`
- `config/dns-key.file`
- `config/k3s-api-token.file`
- `config/k3s-ca.crt`
- `config/k3s-kubeconfig`
- `config/.nfs*`
- `config-backup/acme.json`

If another file later gains tokens, certificates, kubeconfig data, ACME account data, or other secret material, keep it out of Git too.

## GitHub setup

Assume `ringend/traefik-gw-external-azeus2` already exists on GitHub.

Here, `origin` means the GitHub repository URL, not another local folder.

If this local folder is not connected to that GitHub repo yet:

```powershell
git init
git branch -M main
git remote add origin https://github.com/ringend/traefik-gw-external-azeus2.git
```

If `origin` already exists locally, update it instead:

```powershell
git remote set-url origin https://github.com/ringend/traefik-gw-external-azeus2.git
```

## First push

```powershell
git add .
git status --short
git commit -m "Initial traefik external gateway backup"
git push -u origin main
```

Before committing, review the staged file list and make sure no credential or certificate files are included.