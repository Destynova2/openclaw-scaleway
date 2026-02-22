# OpenClaw — Scaleway Deployment

## Project Structure

```
.claude/skills/           7 skills d'audit et validation (voir ci-dessous)
.github/workflows/        opentofu.yml (deploy: builds + apply + drift),
                          build-*.yml / push-pomerium.yml (workflow_dispatch only),
                          renovate.yml, trivy-compliance.yml
containers/               Containerfile.caddy, Containerfile.pomerium, Containerfile.openclaw,
                          Containerfile.openclaw-cli, Containerfile.token-guard
                          .trivyignore (CVEs upstream non-fixables)
  token-guard/            Proxy DLP Rust (filtre secrets dans les appels LLM)
docs/PRD.md               Product Requirements Document
renovate.json             Dependency management config
terraform/                Infrastructure OpenTofu (Scaleway)
  modules/                Modules reutilisables :
    iam-service-account/  IAM application + API key(s) + policy (utilise 3x)
    dns-scaleway/         DNS records via Scaleway Domains (interface interchangeable)
    dns-ovh/              DNS records via OVH (meme interface, non utilise actuellement)
  tests/                  34 tests (.tftest.hcl)
  killswitch/             Serverless Function Python (budget kill switch)
  bootstrap/              Bucket S3 pour le state (one-time)
```

## Commands

**IMPORTANT** : toutes les commandes `tofu` doivent etre executees depuis le repertoire `terraform/`.
Le backend S3 necessite les credentials Scaleway en variables d'environnement.

```bash
# TOUJOURS utiliser ce pattern pour tofu plan/apply/destroy :
AWS_ACCESS_KEY_ID=<scw_access_key> AWS_SECRET_ACCESS_KEY=<scw_secret_key> tofu plan
AWS_ACCESS_KEY_ID=<scw_access_key> AWS_SECRET_ACCESS_KEY=<scw_secret_key> tofu apply

# Les credentials sont dans terraform/backend.conf (gitignore)
# Format rapide (copier-coller) :
#   source <(grep '=' terraform/backend.conf | sed 's/access_key/AWS_ACCESS_KEY_ID/;s/secret_key/AWS_SECRET_ACCESS_KEY/;s/ //g;s/^/export /')

# Commandes qui ne necessitent PAS les credentials S3 :
tofu fmt                        # depuis terraform/
tofu fmt -check -recursive      # depuis terraform/
tofu validate                   # depuis terraform/ (apres init)
tofu test                       # depuis terraform/ (34 tests, ~15s)
```

**Regles** :
- Utiliser `tofu` (OpenTofu), PAS `terraform`
- Ne JAMAIS lancer `tofu plan/apply/destroy` sans `AWS_ACCESS_KEY_ID` et `AWS_SECRET_ACCESS_KEY`
- Toujours `tofu fmt` + `tofu validate` AVANT `tofu apply`
- Le working directory DOIT etre `terraform/` (pas la racine du projet)

## Deployment Flow

Le deploiement en production passe par **GitHub Actions CI/CD**, pas par `tofu apply` local.

### Sequence complete (premier deploiement)

```
1. Configure    terraform.tfvars (secrets, domain, OAuth)
2. Bootstrap    cd terraform/bootstrap && tofu init && tofu apply -var-file=../terraform.tfvars
                → cree le bucket S3, genere encryption_passphrase, pousse les GitHub Secrets
3. Git push     git push origin main
                → CI : detect-changes → build images (parallel) → apply (needs builds)
4. Done         https://app.<domain>
```

Premier deploy = 2 CI runs (convergence automatique) :
- Run 1 : builds skip (registry pas encore cree), apply cree l'infra + met a jour les secrets
- Run 2 : builds poussent les images, apply cree le container Pomerium
Declencher le run 2 via `gh workflow run opentofu.yml` ou un push trivial.

### En routine (modifications d'infra)

```
1. Modifier les .tf localement
2. tofu fmt + tofu validate + tofu test (local, pas besoin de credentials S3)
3. git push origin main
4. CI deploy automatiquement (job "apply" sur push to main)
```

### Deploy local (exceptionnel / debug)

```bash
cd terraform
source <(grep '=' backend.conf | sed 's/access_key/AWS_ACCESS_KEY_ID/;s/secret_key/AWS_SECRET_ACCESS_KEY/;s/ //g;s/^/export /')
tofu plan    # verifier
tofu apply   # appliquer
```

### Credentials et scopes requis

**Scaleway API key** (dans `terraform.tfvars`) :
- **Scope : Organization** (pas project-level) — necessaire pour : creation de projet, DNS, TEM, IAM, Billing API
- 2 cles API distinctes :
  - `scw_access_key` / `scw_secret_key` : cle principale (org-level, tous les droits)
  - `backend.conf` (`access_key`/`secret_key`) : cle S3 state (ObjectStorageFullAccess sur le projet du bucket)

**GitHub tokens** (3 tokens distincts) :

| Token | Scope | Usage | Ou le mettre |
|-------|-------|-------|-------------|
| `github_token` | `repo` (classic PAT) | Auto-configurer les GitHub Actions Secrets via OpenTofu | `terraform.tfvars` |
| `RENOVATE_TOKEN` | `repo` (classic PAT) | Renovate dependency management | GitHub Settings > Secrets (manuel) |
| `github_agent_token` | Fine-grained: `Contents`, `Issues`, `Pull requests` | Agent OpenClaw acces repos prives | `terraform.tfvars` (optionnel) |

**GitHub OAuth App** (pour Pomerium SSO) :
- Creer dans GitHub > Settings > Developers > OAuth Apps
- Callback URL : `https://auth.<domain>/oauth2/callback`
- Client ID → `pomerium_idp_client_id`
- Client Secret → `pomerium_idp_client_secret`

### GitHub Actions Secrets

Le bootstrap + `tofu apply` creent automatiquement **~25 secrets** dans GitHub Actions (si `github_token` fourni).
Le seul secret **manuel** est `RENOVATE_TOKEN` (PAT GitHub separe pour Renovate).

### Destroy / Rebuild complet

```bash
# 1. Retirer les ressources prevent_destroy du state
tofu state rm 'scaleway_domain_registration.grob_ninja[0]'
tofu state rm 'scaleway_account_project.openclaw'
tofu state rm 'tls_private_key.admin'
tofu state rm 'scaleway_vpc_private_network.openclaw'

# 2. Destroy tout le reste
tofu destroy

# 3. Re-importer le projet existant
tofu import 'scaleway_account_project.openclaw' '<project-uuid>'

# 4. Push Pomerium image d'abord (CI workflow)
# 5. Apply
tofu apply
# Note : scaleway_domain_registration echouera (already registered)
#        → import impossible (provider limitation), laisser hors state
```

## Architecture

- **Instance DEV1-S** : Podman rootless (user `openclaw`, uid 1000)
  - Pod `openclaw` : 5 containers (OpenClaw + Caddy + Chrome headless + CLI sidecar + infra)
  - Quadlet systemd (`/etc/containers/systemd/openclaw.kube`)
  - Seccomp RuntimeDefault, readOnlyRootFilesystem, drop ALL caps
- **Gateway auth** : mode `token` (`random_password.gateway_token`)
  - Caddy injecte le token dans l'URL pour le Control UI (`/?token=<token>`)
  - CLI sidecar utilise `--token` en flag explicite
- **Pomerium** : Scaleway Serverless Container (SSO GitHub -> private network -> instance:3000)
  - Auth URL : `https://auth.<domain>/oauth2/callback`
- **Caddy** : Reverse proxy webhooks.<domain> -> localhost:18789 (rate_limit 30 req/min)
- **Kill switch** : Scaleway Serverless Function (cron horaire, poweroff instance si budget >= 13 EUR)
- **TEM** : Scaleway Transactional Email (SPF + DKIM + DMARC sur le domaine)
- **DNS** : Scaleway Domains (module `dns-scaleway`, interchangeable avec `dns-ovh`)
- **Domain** : configure via `var.domain_name` (Scaleway Domains)

## Commits

Ce projet suit **Conventional Commits** (`type(scope): description`).

### Types autorises

| Type | Usage |
|------|-------|
| `feat` | Nouvelle fonctionnalite |
| `fix` | Correction de bug |
| `refactor` | Restructuration sans changement de comportement |
| `docs` | Documentation uniquement |
| `chore` | Maintenance, deps, CI config |
| `test` | Ajout ou modification de tests |
| `style` | Formatage (tofu fmt, whitespace) |

### Regles

- Message en **anglais**, imperatif, premiere ligne < 72 caracteres
- Scope optionnel entre parentheses : `feat(killswitch): add email alerts`
- Corps optionnel separe par une ligne vide, explique le **pourquoi** (pas le quoi)
- Breaking changes : ajouter `!` apres le type → `feat!: remove trusted-proxy auth`
- **Un commit = un changement logique**. Ne pas melanger fix + feat dans le meme commit.

### Exemples

```
feat(cli): add sidecar container for gateway communication
fix(caddy): inject token redirect for Control UI
refactor(iam): extract service account into reusable module
docs: update CLAUDE.md with SSH access instructions
chore(deps): bump pomerium to v0.32.0
test: add validation tests for encryption passphrase
```

## Secrets — regles strictes

**Ne JAMAIS commiter de secrets.** Cela inclut :

- Cles API, tokens, mots de passe (meme temporaires, meme pour "tester")
- Adresses email personnelles, numeros de telephone, adresses postales
- IPs de production, noms de domaine reels
- Toute valeur qui figurerait dans `terraform.tfvars` ou `backend.conf`

### Avant chaque commit, verifier :

1. `git diff --cached` — relire chaque ligne ajoutee
2. Pas de `.tfvars`, `.env`, `.pem`, `.key`, `backend.conf` dans le staging
3. Les fichiers de test utilisent des placeholders (`SCWTEST0000000000000`, `203.0.113.42/32`, `example.com`)
4. Les exemples dans la doc utilisent `<domain>`, `<IP>`, `admin@example.com`

### Si un secret est commite par erreur :

1. **Ne PAS juste le supprimer dans un nouveau commit** (il restera dans l'historique)
2. Revoquer immediatement le secret (regenerer la cle API, changer le token)
3. Utiliser `git filter-repo` pour purger l'historique, ou repartir d'un squash
4. Forcer le push : `git push --force`

### Fichiers proteges par .gitignore

```
terraform.tfvars          # Variables avec secrets
encryption.auto.tfvars    # Passphrase generee
backend.conf              # Credentials S3
.terraform/               # Cache providers
*.tfstate                 # State (contient des secrets)
.env, *.pem, *.key        # Secrets divers
.claude/settings.local.json  # Config locale Claude Code
```

## Contributions upstream (PRs sur des projets tiers)

Quand on ouvre un PR sur un projet externe (ex: bump de version, fix CVE) :

### Avant de rediger

1. **Lire les PRs recentes** du projet (`gh pr list --state merged --limit 10`) pour capter le style
2. **Chercher un PR template** (`.github/pull_request_template.md`, `CONTRIBUTING.md`)
3. **Adapter le format** au projet — ne pas imposer notre style maison

### Structure du PR body

```markdown
## Summary
<1-3 phrases claires : quoi + pourquoi — lisible par un humain ET par une IA>

## Changes
- <changement concret 1>
- <changement concret 2>

## Test plan
- [ ] `commande de build`
- [ ] `commande de test`

<lien issue si applicable : Fixes #NNN>
```

### Regles

- **Titre** : suivre le format du projet (souvent Conventional Commits `type(scope): description`)
- **Ton** : technique, concis, imperatif. Pas de marketing, pas de filler
- **Contexte** : expliquer le probleme (CVE, trivy scan, etc.) pour que le mainteneur comprenne sans chercher
- **Actionnable** : mentionner les etapes post-merge si necessaire (ex: "cut a new release")
- **Attribution** : ajouter `Generated with [Claude Code](https://claude.com/claude-code)` en footer si le projet le fait deja
- **Ne pas** : ajouter de labels (sauf si le projet en utilise), over-documenter, envoyer des PRs sur des projets inactifs

### Checklist pre-PR

1. Le projet a eu un commit dans les 3 derniers mois
2. Pas de PR ouverte identique (verifier `gh pr list --state open`)
3. Le changement est minimal et cible (un seul sujet par PR)
4. Les URLs de telechargement des nouvelles versions sont verifiees (`curl --head`)

## Conventions

- Langue des fichiers : francais pour les commentaires/descriptions, anglais pour le code
- Secrets : jamais en dur. Variables `sensitive = true`, injection via `templatefile()` ou `secret_environment_variables`
- Secrets auto-generes : cle SSH (`tls_private_key` Ed25519), secrets Pomerium (`random_bytes`), gateway token (`random_password`)
- State : chiffre client-side (PBKDF2 + AES-GCM)
- Images container : epinglees par version, suivi Renovate
- GitHub Actions : SHA-pinned, concurrency guards, timeouts
- IAM : 3 modules `iam-service-account` (openclaw, cicd, killswitch) avec moindre privilege

## Skills (invoquer via `/nom-du-skill`)

| Skill | Role | Quand l'utiliser |
|-------|------|-----------------|
| `/validate-terraform` | Syntax + pieges Scaleway | Avant chaque `tofu plan` |
| `/scaleway-resource` | Reference ressources + prix | Quand on ajoute/modifie une ressource |
| `/deploy-check` | Checklist pre/post deploy | Avant le premier `tofu apply` |
| `/audit-security` | CIS + Podman + Renovate | Audit periodique ou apres changement majeur |
| `/budget-check` | Cout vs ~20 EUR/mois | Quand on ajoute une ressource payante |
| `/audit-cicd` | Pipeline GitHub Actions | Apres modif des workflows |
| `/scan-secrets` | Detection secrets en dur | Avant chaque commit |

Pour lancer tous les audits en parallele, demander : **"lance les audits"** — cela execute les 7 skills comme sous-agents concurrents.

## Budget (~20 EUR/mois)

| Poste | Cout |
|-------|------|
| DEV1-S | 6.42 EUR |
| IPv4 flexible | 2.92 EUR |
| Pomerium (256Mo always-on) | 0.42 EUR |
| Domaine (amorti) | 2.29 EUR |
| **Base** | **~12.05 EUR** |
| Marge API (llama-3.1-8b) | ~4 EUR |

## Providers OpenTofu

| Provider | Version | Usage |
|----------|---------|-------|
| `scaleway/scaleway` | `~> 2.69` | Infra Scaleway (instance, containers, DNS, IAM, TEM) |
| `hashicorp/tls` | `~> 4.0` | Generation cle SSH Ed25519 |
| `hashicorp/random` | `~> 3.6` | Secrets Pomerium, token kill switch |
| `integrations/github` | `~> 6.0` | GitHub Actions Secrets automatiques |
| `hashicorp/archive` | `~> 2.7` | Zip handler kill switch |

## Scaleway Provider Pitfalls

- `instance_server` : `private_network { pn_id = ... }` (bloc imbrique, PAS plat)
- `container` : `private_network_id` (plat, different de instance!)
- `.private_ip` n'existe pas -> `.private_ips[0].address`
- `permission_set_ids` n'existe pas -> `permission_set_names` (type set)
- `scaleway_cockpit` DEPRECIE -> auto-active par projet
- IPv4 flexible = ~2.92 EUR/mo SEPAREMENT de l'instance
- Modules enfants : ajouter `required_providers { scaleway = { source = "scaleway/scaleway" } }` pour eviter l'ambiguite `hashicorp/scaleway`

## Acces instance (SSH)

```bash
# Cle SSH : ~/.ssh/openclaw (Ed25519, generee par tls_private_key)
# IP : resolvable via `host webhooks.<domain>`
ssh -i ~/.ssh/openclaw root@$(host webhooks.<domain> | awk '{print $4}')

# Commandes Podman (user openclaw, rootless)
ssh -i ~/.ssh/openclaw root@<IP> "cd /tmp && sudo -u openclaw XDG_RUNTIME_DIR=/run/user/1000 podman <cmd>"
```

**Regles SSH** :
- Toujours `cd /tmp &&` avant `sudo -u openclaw` (evite `cannot chdir to /root`)
- Toujours `XDG_RUNTIME_DIR=/run/user/1000` pour Podman rootless
- User `openclaw` n'a pas de shell → `sudo -u openclaw` depuis root

## Communication Claude Code ↔ OpenClaw

Le CLI sidecar (`openclaw-cli`) permet d'envoyer des messages a l'agent OpenClaw.

```bash
# Pattern complet (SSH → podman exec → base64 pour eviter l'enfer du JSON escaping)
IDEMPOTENCY="cc-$(date +%s)"
MSG="Ton message ici"
JSON_PARAMS='{"sessionKey":"agent:main:main","message":"'"${MSG}"'","idempotencyKey":"'"${IDEMPOTENCY}"'"}'
B64=$(echo -n "$JSON_PARAMS" | base64)
TOKEN="<gateway_token>"  # dans /home/openclaw/config/openclaw.json → gateway.auth.token

ssh -i ~/.ssh/openclaw root@<IP> "cd /tmp && sudo -u openclaw XDG_RUNTIME_DIR=/run/user/1000 \
  podman exec -e PARAMS_B64=${B64} openclaw-cli sh -c \
  'openclaw gateway call chat.send --url ws://127.0.0.1:18789 --token ${TOKEN} --params \"\$(echo \$PARAMS_B64 | base64 -d)\"'"

# Lire l'historique de conversation
JSON_HIST='{"sessionKey":"agent:main:main"}'
B64_H=$(echo -n "$JSON_HIST" | base64)
ssh ... podman exec -e PARAMS_B64=${B64_H} openclaw-cli sh -c \
  'openclaw gateway call chat.history --url ws://127.0.0.1:18789 --token ${TOKEN} --params "$(echo $PARAMS_B64 | base64 -d)"'
```

**Methodes gateway connues** : `chat.send`, `chat.history`

**Pieges** :
- JSON escaping a travers SSH + podman + sh : **toujours utiliser base64** (sinon les `"` sont manges)
- `openclaw agent` ignore `--url`, decouvre l'IP LAN, rejette `ws://` non-loopback → utiliser `gateway call` a la place
- `chat.send` requiert `sessionKey`, `message` (string), `idempotencyKey`
- Le CLI sidecar a besoin d'ecrire dans `/home/node/.openclaw/identity` → pas de `readOnly` sur le volume config
- Le container CLI fait 128Mi max — si le gateway call echoue, il tente un fallback agent embarque (249Mo+) → OOM. C'est normal, le `gateway call` est la seule methode supportee
