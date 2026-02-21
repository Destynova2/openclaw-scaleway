---
name: audit-security
description: Audit securite CIS et posture cloud Scaleway — lecture seule
user_invocable: true
---

# Audit Securite — CIS Benchmarks & Posture Cloud

Audit de securite statique des fichiers Terraform et configs du projet. Lecture seule (Read, Grep, Glob uniquement).

## Checklist CIS / Cloud Security

### 1. Identite et acces (IAM)
- [ ] Principe du moindre privilege applique (pas de `AllProductsFullAccess`)
- [ ] CI/CD IAM scope par produit (Instances, VPC, Registry, Containers, Functions, ObjectStorage + IAMManager/ProjectManager)
- [ ] API keys scopees a un projet (pas Organization-wide)
- [ ] Pas de credentials en dur dans les fichiers `.tf`, `.yaml`, `.env`
- [ ] Variables sensibles marquees `sensitive = true`
- [ ] Secrets generes automatiquement (`tls_private_key`, `random_bytes`, `random_password`)
- [ ] Kill switch protege par token (`secret_environment_variables` + validation `hmac.compare_digest`)
- [ ] Kill switch : token accepte UNIQUEMENT via header Bearer (PAS en query string — fuite dans les logs)
- [ ] Kill switch : credentials IAM dedies injectes pour piloter l'instance (pas de `Client.from_config()` sans env vars)
- [ ] `PermitRootLogin no` (pas `prohibit-password` qui autorise root via cle SSH)

### 2. Reseau
- [ ] Security group en `inbound_default_policy = drop`
- [ ] Ports ouverts strictement necessaires (SSH admin, HTTP/HTTPS webhooks)
- [ ] SSH restreint a une IP admin (pas `0.0.0.0/0`)
- [ ] Port de l'application (3000) NON expose sur Internet (Private Network uniquement)
- [ ] Private Network utilise pour la communication Pomerium → instance
- [ ] Egress : evaluer si `outbound_default_policy = accept` est necessaire

### 3. Containers Podman (instance)
- [ ] Podman rootless (user `openclaw`, pas root)
- [ ] Pod-level seccomp profile : `RuntimeDefault`
- [ ] Per-container : `allowPrivilegeEscalation: false`
- [ ] Per-container : `readOnlyRootFilesystem: true`
- [ ] Per-container : `capabilities: drop ALL`
- [ ] `runAsUser: 1000` / `runAsGroup: 1000` au niveau pod
- [ ] `UserNS=keep-id` dans le Quadlet (mapping UID)
- [ ] Volumes `/tmp` en `emptyDir: medium: Memory` (pas de write sur disque)
- [ ] Sysctl `ip_unprivileged_port_start=80` pour binding ports 80/443 en rootless
- [ ] Health probes (livenessProbe + readinessProbe) sur chaque container
- [ ] Images epinglees (pas de tag `latest` sans suivi Renovate)
- [ ] Caddy rate_limit configure sur les endpoints webhooks

### 4. Donnees et secrets
- [ ] State OpenTofu chiffre (PBKDF2 + AES-GCM, `encryption {}` block)
- [ ] Bootstrap state : ne contient PAS de secrets en clair (passphrase generee stockee localement, jamais en S3 non chiffre)
- [ ] Bucket S3 state : ACL ou policy restrictive, pas d'acces ouvert
- [ ] Pas de secrets dans les outputs non-sensitive
- [ ] Cloud-init : secrets nettoyes post-installation (`rm user-data.txt` + `cloud-init-output.log`)
- [ ] `.gitignore` couvre `terraform.tfvars`, `*.tfstate`, `.env`, `*.pem`, `*.key`, `.terraform/`
- [ ] Swap configure (protection OOM — 1 Go)

### 5. Containers serverless (Pomerium)
- [ ] Images epinglees (pas de tag `latest` sans suivi Renovate)
- [ ] Secrets via `secret_environment_variables` (pas `environment_variables`)
- [ ] `INSECURE_SERVER=true` uniquement car TLS termine par Scaleway (edge)
- [ ] Registry image dans un namespace Scaleway (pas Docker Hub direct)
- [ ] Routes Pomerium auto-generees depuis l'IP privee instance + `github_owner` (allowed_idp_claims)

### 6. CI/CD
- [ ] GitHub Environment protection (`environment: production`) avec approbation sur apply
- [ ] Secrets GitHub jamais affiches dans les logs
- [ ] `tofu plan` sur PR, `apply` uniquement sur merge main
- [ ] Concurrency guards sur les workflows (pas de runs paralleles)
- [ ] Timeouts configures sur les jobs
- [ ] Actions tierces epinglees par SHA

### 7. Dependency Management (Renovate)
- [ ] `RENOVATE_TOKEN` est un fine-grained PAT scope au repo uniquement
- [ ] Automerge jamais applique aux composants critiques (Pomerium, OpenTofu providers)
- [ ] Presets `docker:pinDigests` et `helpers:pinGitHubActionDigests` actifs
- [ ] Pas de `automerge: true` sur les bumps major
- [ ] customManagers a jour (pas de managers pour deps supprimees)

## Format de sortie

```markdown
## Audit Securite — [date]

### Score : X/Y points conformes

| # | Categorie | Point de controle | Statut | Remarque |
|---|-----------|-------------------|--------|----------|

### Recommandations prioritaires
1. [CRITICAL] ...
2. [HIGH] ...
```
