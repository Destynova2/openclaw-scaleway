# PRD - Deploiement OpenClaw sur Scaleway via OpenTofu

## 1. Vue d'ensemble

**Objectif** : Deployer une instance auto-hebergee d'[OpenClaw](https://github.com/openclaw/openclaw) (assistant IA personnel open-source) sur une instance Scaleway DEV1-S, protegee par [Pomerium](https://www.pomerium.com/) (identity-aware proxy) en Serverless Container, connectee aux [Generative APIs de Scaleway](https://www.scaleway.com/en/generative-apis/) comme fournisseur LLM. Le tout provisionne via OpenTofu (fork open-source de Terraform), deploye par GitHub Actions, avec des regles de securite strictes et un controle budgetaire ~20 EUR/mois.

**Usage cible** : Agent autonome actif — messaging multi-canal, automations, cron jobs, skills etendus.

**Probleme resolu** : Heberger un assistant IA personnel sans dependre de services SaaS proprietaires (ChatGPT, Claude.ai), en conservant la souverainete des donnees en Europe et en maitrisant le cout (~20 EUR/mois).

---

## 1b. Objectifs mesurables

| # | Objectif | Metrique de succes | Cible |
|---|----------|--------------------|-------|
| G1 | Deployer OpenClaw fonctionnel sur Scaleway | Instance en etat `running`, daemon systemd actif | 100% uptime hors maintenance |
| G2 | Proteger l'acces web par SSO | Toute requete web UI passe par Pomerium | 0 acces non authentifie |
| G3 | Utiliser les Generative APIs Scaleway | Requetes LLM traitees via `api.scaleway.ai` | Latence < 5s p95 |
| G4 | Automatiser le deploiement via CI/CD | Changements OpenTofu deployes via GitHub Actions | 0 apply manuel apres setup |
| G5 | Respecter le budget | Facture Scaleway + domaine mensualise | < 20 EUR/mois (~12 base + ~4 API) |
| G6 | Securiser l'infrastructure | Score audit securite (voir skill `/audit-security`) | >= 80% conformite |
| G7 | Infrastructure as Code reproductible | `tofu destroy` + `tofu apply` = environnement identique | Temps de rebuild < 30min |

---

## 1c. User Stories

| # | En tant que... | Je veux... | Afin de... |
|---|----------------|------------|------------|
| US1 | Utilisateur admin | Acceder a la web UI OpenClaw via `https://app.<domain>` avec SSO GitHub | Gerer mon assistant IA depuis un navigateur de maniere securisee |
| US2 | Utilisateur admin | Que les webhooks Telegram/WhatsApp soient recus sur `https://webhooks.<domain>` | Communiquer avec mon assistant via messaging sans configuration reseau manuelle |
| US3 | Utilisateur admin | Que l'agent autonome execute des taches planifiees (cron, automations) 24/7 | Beneficier d'un assistant toujours actif sans intervention |
| US4 | Utilisateur admin | Voir la consommation CPU/RAM/tokens dans un dashboard Grafana | Surveiller la sante du systeme et anticiper les depassements |
| US5 | DevOps / admin | Modifier l'infrastructure via une PR GitHub avec plan OpenTofu en review | Valider les changements avant application, sans acces SSH |
| US6 | DevOps / admin | Recevoir une alerte email si la facture Scaleway depasse 10 EUR, et un arret automatique a 13 EUR | Reagir avant depassement grace au kill switch budgetaire |
| US7 | DevOps / admin | Pouvoir reconstruire l'environnement from scratch avec `tofu apply` | Avoir un disaster recovery < 30 minutes |

---

## 1d. Exigences fonctionnelles

| # | Exigence | Priorite |
|---|----------|----------|
| FR1 | L'instance DEV1-S doit etre provisionnee automatiquement via OpenTofu avec cloud-init | P0 |
| FR2 | OpenClaw doit demarrer comme pod Podman rootless au boot, sous un utilisateur dedie non-root | P0 |
| FR3 | OpenClaw doit etre configure pour utiliser les Generative APIs Scaleway (`api.scaleway.ai/{project_id}/v1`) | P0 |
| FR4 | Pomerium doit etre deploye en Serverless Container avec SSO GitHub | P0 |
| FR5 | Le port 3000 (web UI) ne doit PAS etre expose sur Internet | P0 |
| FR6 | Les webhooks doivent etre accessibles en HTTPS avec certificat Let's Encrypt automatique | P0 |
| FR7 | Le pipeline GitHub Actions doit executer `tofu plan` sur PR et `tofu apply` sur merge main | P0 |
| FR8 | Le state OpenTofu doit etre stocke sur Scaleway Object Storage (S3), chiffre cote client (AES-GCM), avec versioning | P0 |
| FR9 | Un security group drop-by-default doit proteger l'instance | P0 |
| FR10 | SSH doit etre restreint a une IP admin, cle Ed25519 auto-generee, fail2ban actif | P0 |
| FR11 | Un kill switch budgetaire doit couper l'instance si le budget projet depasse 13 EUR | P0 |
| FR12 | Les emails d'alerte doivent etre envoyes via Scaleway TEM (SPF + DKIM + DMARC) | P1 |
| FR13 | Le rate limiting des webhooks doit etre configure (30 req/min par IP) | P1 |
| FR14 | Les secrets cloud-init doivent etre nettoyes post-installation | P1 |
| FR15 | Le metadata endpoint doit etre bloque (protection SSRF) | P1 |
| FR16 | L'infrastructure doit etre modulaire : modules IAM et DNS interchangeables | P1 |

---

## 1e. Hors perimetre (Non-Goals)

Les elements suivants sont explicitement **hors du perimetre v1** :

- Haute disponibilite / multi-region
- Backup automatise (snapshots)
- State locking (pas d'equivalent DynamoDB chez Scaleway)
- Egress filtering strict
- Rotation automatisee des secrets
- Scale-to-zero intelligent (arret nuit)
- Multi-tenant / multi-utilisateur

Voir la section "Evolutions futures" pour le detail.

---

## 2. Architecture cible

```
                           +-----------------------------------+
                           |  GitHub Actions CI/CD             |
                           |  tofu plan/apply                  |
                           +----------------+------------------+
                                            |
                                            | deploy
                                            v
+------------------+     +-----------------------------------+
| Scaleway Project |     | OpenTofu State (chiffre AES-GCM)  |
| (cree via OTF)  |     | (Scaleway Object Storage - S3)    |
+------------------+     +-----------------------------------+

                    === Plan de donnees ===

                                  +---------------------------+
+-------------------+    HTTPS    |  Pomerium                 |
|  Utilisateur      | ----------> |  Serverless Container     |
|  (navigateur,     |  app/auth   |  256 Mo / 140 mvCPU       |
|  admin web UI)    | <domain>  |  (~0.42 EUR/mois)         |
+-------------------+             +------------+--------------+
                                               |
                                               | proxy auth (Private Network)
                                               v
+-------------------+             +---------------------------+
|  Services tiers   |   HTTPS    |  Instance DEV1-S          |
|  (WhatsApp,       | ---------> |  Ubuntu 24.04             |
|  Telegram, etc.)  |  webhooks  |  Podman rootless + Quadlet|
+-------------------+   :443     |  Pod: OpenClaw + Caddy    |
                                  +------------+--------------+
                                               |
                                               | HTTPS (OpenAI-compat)
                                               v
                                  +---------------------------+
                                  |  Scaleway Generative APIs |
                                  | api.scaleway.ai/{pid}/v1  |
                                  +---------------------------+

                    === Alertes ===

                                  +---------------------------+
                                  |  Kill Switch              |
                                  |  Serverless Function      |
                                  |  Cron horaire -> Billing  |
                                  |  10 EUR: email warning    |
                                  |  13 EUR: email + poweroff |
                                  +---------------------------+
                                               |
                                               v
                                  +---------------------------+
                                  |  Scaleway TEM             |
                                  |  <domain> (SPF+DKIM)    |
                                  +---------------------------+

                    === Monitoring ===

                                  +---------------------------+
                                  |  Scaleway Cockpit         |
                                  |  Grafana (gratuit, IAM)   |
                                  |  Metriques instance/cont. |
                                  +---------------------------+
```

**Flux d'acces** :
- **Acces humain (web UI, admin)** : Utilisateur -> `app.<domain>` -> Pomerium (SSO GitHub) -> OpenClaw via Private Network
- **Auth Pomerium** : `auth.<domain>` (callback OAuth)
- **Webhooks messaging** : WhatsApp/Telegram -> directement sur l'IP publique de l'instance (port 443, Caddy TLS)
- **Appels LLM** : OpenClaw -> Scaleway Generative APIs (baseUrl inclut project_id)
- **Alertes budget** : Kill switch cron -> Billing API -> email TEM + poweroff si >= 13 EUR

---

## 3. Choix techniques

### 3.1 Projet Scaleway

Le projet Scaleway est cree via OpenTofu (`scaleway_account_project`) pour isoler toutes les ressources et la facturation. `lifecycle { prevent_destroy = true }`.

### 3.2 Nom de domaine (Scaleway Domains)

| Parametre    | Valeur                                               |
|--------------|------------------------------------------------------|
| Registrar    | Scaleway Domains                                     |
| Enregistrement | Via OpenTofu (`scaleway_domain_registration`)      |
| DNS          | Via OpenTofu — module `dns-scaleway` (`scaleway_domain_record` for_each) |
| Cout         | Variable selon le TLD (~2-3 EUR/mois amorti) |

**Pourquoi Scaleway Domains** : Tout dans un seul provider, pas de credentials tiers (OVH supprime), gestion DNS dans le meme pipeline que l'infra.

**Sous-domaines** :

| Sous-domaine                  | Type  | Cible                              | Usage                      |
|-------------------------------|-------|-------------------------------------|----------------------------|
| `app.<domain>`             | CNAME | Pomerium container domain (.scw.cloud) | Web UI (protegee par SSO)  |
| `auth.<domain>`            | CNAME | Pomerium container domain (.scw.cloud) | Callback OAuth GitHub      |
| `webhooks.<domain>`        | A     | IP publique de l'instance           | Webhooks Telegram/WhatsApp |

**Records TEM (email)** : SPF (TXT racine), DKIM (TXT `{project_id}._domainkey`), DMARC (TXT `_dmarc`).

### 3.2b TLS / Let's Encrypt

Deux couches de TLS, toutes deux automatiques et gratuites :

| Composant | Terminaison TLS | Methode | Certificat | Config |
|-----------|-----------------|---------|------------|--------|
| **Pomerium** (Serverless Container) | Scaleway Edge | [Auto Let's Encrypt par Scaleway](https://www.scaleway.com/en/docs/serverless-containers/how-to/add-a-custom-domain-to-a-container/) sur le custom domain | Genere et renouvele automatiquement | Zero config |
| **Instance** (webhooks) | [Caddy](https://caddyserver.com/) reverse proxy | ACME HTTP-01 challenge | Let's Encrypt automatique | Caddyfile minimal |

```
Utilisateur --- HTTPS ---> [Scaleway TLS Edge] --- HTTP ---> Pomerium Container
                            Let's Encrypt auto              (pas de TLS interne)

Telegram --- HTTPS ---> [Caddy sur DEV1-S] --- HTTP ---> OpenClaw :3000
                         Let's Encrypt auto
```

> **Pas besoin de `AUTOCERT` dans Pomerium** : Scaleway gere le TLS en amont. Pomerium recoit du HTTP dechiffre.

### 3.3 Instance de calcul

| Parametre     | Valeur                |
|---------------|-----------------------|
| Type          | DEV1-S                |
| vCPU          | 2                     |
| RAM           | 2 Go                  |
| Stockage      | 20 Go SSD local       |
| OS            | Ubuntu 24.04 LTS      |
| Cout          | ~6.42 EUR/mois        |
| Region        | `fr-par-1` (Paris)    |

**Containeurisation** : Podman rootless (user `openclaw`, uid 1000), Quadlet systemd, pod avec OpenClaw + Caddy + Chrome headless.

### 3.4 Pomerium — Identity-Aware Proxy

| Parametre       | Valeur                                 |
|-----------------|----------------------------------------|
| Deploiement     | Scaleway Serverless Container          |
| Image           | `pomerium/pomerium:v0.32.0` (all-in-one) via Scaleway Container Registry |
| RAM             | 256 Mo (Pomerium + Envoy embarque)     |
| vCPU            | 140 mvCPU                              |
| min_scale       | 1 (always-on)                          |
| Cout            | **~0.42 EUR/mois**                     |
| IdP             | **GitHub OAuth** (callback URL: `https://auth.<domain>/oauth2/callback`) |
| Version         | Variable `pomerium_version` (default `v0.32.0`) |

**Secrets auto-generes** : `COOKIE_SECRET` et `SHARED_SECRET` via `random_bytes` (32 octets, base64). Pas de generation manuelle.

### 3.5 Fournisseur LLM : Scaleway Generative APIs

| Parametre      | Valeur                                    |
|----------------|-------------------------------------------|
| Endpoint       | `https://api.scaleway.ai/{project_id}/v1` |
| Compatibilite  | OpenAI API (drop-in replacement)          |
| Auth           | API Key IAM Scaleway (module iam_openclaw)|
| Free tier      | 1 000 000 tokens gratuits (credit unique, non renouvelable) |
| Tarif apres    | A partir de 0.20 EUR / million de tokens  |

> **IMPORTANT** : Le baseUrl DOIT inclure le project_id. Sans project_id -> 403 FORBIDDEN.

### 3.6 Modeles recommandes (par cout croissant)

1. **llama-3.1-8b-instruct** — Le plus econome, suffisant pour la majorite des taches
2. **mistral-small** — Bon compromis performance/cout
3. **llama-3.1-70b-instruct** — Pour les taches complexes (attention au cout)

### 3.7 Monitoring : Scaleway Cockpit

| Parametre      | Valeur                              |
|----------------|-------------------------------------|
| Activation     | Automatique sur chaque projet       |
| Dashboard      | Grafana integre (gratuit, auth IAM) |
| Metriques      | CPU, RAM, disque, reseau (gratuit)  |
| Retention      | 31 jours (metriques), 7 jours (logs)|
| Cout           | **0 EUR** (metriques Scaleway)      |

> **Note** : `scaleway_cockpit` et `scaleway_cockpit_grafana_user` sont **deprecies**. Utiliser `data "scaleway_cockpit_grafana"` + auth IAM.

### 3.8 Kill Switch Budgetaire

| Parametre      | Valeur                              |
|----------------|-------------------------------------|
| Runtime        | Scaleway Serverless Function (Python 3.10) |
| Declenchement  | Cron horaire (`scaleway_function_cron`) |
| Seuil warning  | 10 EUR -> email via TEM             |
| Seuil poweroff | 13 EUR -> email + poweroff instance |
| IAM            | Module iam_killswitch (InstancesFullAccess + TransactionalEmailFullAccess + BillingReadOnly org) |
| Mode           | Dual: cron automatique + HTTP declenchement manuel (Bearer token) |

### 3.9 Email Transactionnel (TEM)

| Parametre      | Valeur                              |
|----------------|-------------------------------------|
| Domaine        | <domain> (verifie SPF + DKIM)     |
| Usage          | Alertes kill switch uniquement      |
| Cout           | 0 EUR (< 300 emails/mois gratuit)   |

---

## 4. Infrastructure OpenTofu

### 4.1 Structure du projet

```
.
├── .github/
│   └── workflows/
│       ├── opentofu.yml          # CI/CD: plan on PR, apply on merge main
│       ├── build-caddy.yml       # Build Caddy image + rate_limit
│       ├── push-pomerium.yml     # Push Pomerium image to registry
│       ├── build-openclaw.yml    # Build OpenClaw image
│       └── renovate.yml          # Self-hosted Renovate (cron 6h UTC)
├── containers/
│   ├── Containerfile.caddy       # Caddy + xcaddy + rate_limit
│   ├── Containerfile.pomerium    # Pomerium all-in-one
│   └── Containerfile.openclaw    # OpenClaw application
├── terraform/
│   ├── bootstrap/
│   │   └── main.tf              # Bootstrap: bucket S3 pour le state
│   ├── modules/
│   │   ├── iam-service-account/  # IAM app + API key(s) + policy (utilise 3x)
│   │   ├── dns-scaleway/         # DNS records Scaleway (interface interchangeable)
│   │   └── dns-ovh/              # DNS records OVH (meme interface, reserve)
│   ├── main.tf                   # 5 providers + backend S3 + encryption + project + locals
│   ├── variables.tf              # ~20 variables d'entree
│   ├── outputs.tf                # 11 sorties (IPs, URLs, cles, kill switch)
│   ├── iam.tf                    # 3x module iam-service-account + SSH key
│   ├── dns.tf                    # Module dns-scaleway (6 records) + container_domain
│   ├── domain.tf                 # Domain registration via Scaleway Domains
│   ├── tem.tf                    # Scaleway Transactional Email
│   ├── instance.tf               # Instance DEV1-S + cloud-init
│   ├── security.tf               # Security group + regles firewall
│   ├── network.tf                # Private Network (VPC)
│   ├── pomerium.tf               # Serverless Container Pomerium
│   ├── killswitch.tf             # Serverless Function + cron + IAM killswitch
│   ├── monitoring.tf             # Cockpit Grafana data source
│   ├── registry.tf               # Container Registry namespace
│   ├── github.tf                 # GitHub Actions Secrets (auto)
│   ├── cloud-init.yaml.tftpl    # Template cloud-init (Podman pod + Quadlet)
│   ├── killswitch/
│   │   └── handler.py           # Python handler (dual mode)
│   ├── tests/                    # 34 tests (.tftest.hcl)
│   └── terraform.tfvars          # Valeurs (NON commite — .gitignore)
├── renovate.json                 # Dependency management config
└── .gitignore
```

### 4.2 Modules reutilisables

#### Module `iam-service-account`

Elimine la triplication du pattern IAM (application + API key + policy). Utilise 3 fois : openclaw (GenAI), cicd (deploy infra), killswitch (poweroff + billing + email).

**Interface** :
- `name`, `description`, `project_id`, `tags` : identifiant du service account
- `project_rules` : liste d'objets `{ project_ids, permission_set_names }` (scope projet)
- `org_rules` : liste d'objets `{ organization_id, permission_set_names }` (scope org, optionnel)
- `extra_api_keys` : map d'objets pour cles API supplementaires (ex: cle S3 state CI/CD)

**Outputs** : `application_id`, `access_key`, `secret_key` (sensitive), `extra_keys` (sensitive map)

#### Module `dns-scaleway` / `dns-ovh`

Interface interchangeable pour changer de registrar DNS sans modifier le code appelant.

**Interface commune** :
- `zone` : nom de domaine (ex: `example.com`)
- `records` : map d'objets `{ name, type, data, ttl (optional, default 300) }`

**Outputs** : `record_ids`, `records` (name/type/ttl pour les tests)

> Pour passer de Scaleway a OVH : changer `source = "./modules/dns-scaleway"` en `source = "./modules/dns-ovh"` dans `dns.tf`.

### 4.3 Variables

Les variables sont reparties en categories :

| Categorie | Variables | Sensibles |
|-----------|-----------|-----------|
| Scaleway credentials | `scw_access_key`, `scw_secret_key`, `scw_organization_id` | Oui |
| Admin | `admin_ip_cidr`, `admin_email` | Non |
| Domaine | `domain_name`, `domain_owner_contact` | Partiellement |
| OpenClaw | `openclaw_version`, `chrome_headless_version` | Non |
| Pomerium | `pomerium_version`, `pomerium_idp_client_id`, `pomerium_idp_client_secret`, `pomerium_routes_b64` | Partiellement |
| GitHub | `github_token`, `github_repository` | Partiellement |
| Integrations | `brave_search_api_key`, `github_agent_token`, `telegram_bot_token` | Oui |
| State | `state_project_id`, `encryption_passphrase` | Partiellement |

**Secrets auto-generes (pas de variable)** :
- `tls_private_key.admin` : cle SSH Ed25519
- `random_bytes` : cookie_secret + shared_secret Pomerium (32 octets, base64)
- `random_password.killswitch_token` : token HTTP kill switch

### 4.4 Outputs

| Output | Description | Sensitive |
|--------|-------------|-----------|
| `project_id` | ID du projet Scaleway | Non |
| `instance_public_ip` | IP publique | Non |
| `instance_private_ip` | IP privee (Private Network) | Non |
| `pomerium_container_url` | URL container Pomerium | Non |
| `openclaw_web_ui` | `https://app.<domain>` | Non |
| `webhooks_url` | `https://webhooks.<domain>` | Non |
| `grafana_url` | URL Grafana Cockpit | Non |
| `openclaw_api_key_access_key` | Access key IAM OpenClaw | Oui |
| `killswitch_function_url` | URL fonction kill switch | Oui |
| `killswitch_webhook_url` | URL kill switch avec token | Oui |
| `cicd_access_key` / `cicd_secret_key` | Cles API CI/CD | Oui |
| `ssh_private_key` | Cle privee SSH Ed25519 | Oui |

---

## 5. CI/CD — GitHub Actions

### 5.1 Secrets GitHub

Les secrets sont configures **automatiquement** par OpenTofu via `github_actions_secret` (provider `integrations/github ~> 6.0`). Seul `RENOVATE_TOKEN` reste a configurer manuellement.

### 5.2 Workflows

| Workflow | Declencheur | Action |
|----------|-------------|--------|
| `opentofu.yml` | PR sur `terraform/**` | `tofu plan` + commentaire PR |
| `opentofu.yml` | Push main sur `terraform/**` | `tofu apply` (environment: production) |
| `build-caddy.yml` | Push main sur `containers/Containerfile.caddy` | Build + push image Caddy |
| `push-pomerium.yml` | workflow_dispatch | Push image Pomerium vers registry |
| `build-openclaw.yml` | Push main sur `containers/Containerfile.openclaw` | Build + push image OpenClaw |
| `renovate.yml` | Cron 6h UTC + workflow_dispatch | Renovate dependency PRs |

### 5.3 Securite du pipeline

- Les secrets ne sont **jamais** affiches dans les logs
- `tofu plan` + `tofu test` s'executent sur les PR pour review avant merge
- `tofu apply` uniquement sur push vers `main`, dans un **GitHub Environment `production`** avec approbation requise
- State chiffre client-side (PBKDF2 + AES-GCM)
- Actions tierces SHA-pinned, concurrency guards, timeouts
- **Limitation** : Pas de state locking (pas d'equivalent DynamoDB chez Scaleway)

---

## 6. Securite

### 6.1 Regles appliquees

| Categorie                  | Mesure                                                     |
|----------------------------|------------------------------------------------------------|
| **Acces web**              | Pomerium : SSO GitHub obligatoire, zero-trust              |
| **Reseau**                 | Security group : drop par defaut en entree                  |
| **Port 3000**              | NON expose sur Internet, accessible uniquement via VPC      |
| **SSH**                    | Clef Ed25519 auto-generee, IP admin restreinte, pas de mdp  |
| **Bruteforce**             | fail2ban : 3 tentatives max, ban 1h                         |
| **Runtime**                | Podman rootless, Seccomp RuntimeDefault, drop ALL caps      |
| **Mises a jour**           | unattended-upgrades actif (patches securite auto)           |
| **Secrets OpenTofu**       | Variables `sensitive`, auto-generation (tls/random)         |
| **Secrets CI/CD**          | GitHub Actions Secrets auto-provisionnees                   |
| **State OpenTofu**         | Chiffre client-side (AES-GCM), stocke sur S3 avec versioning|
| **IAM**                    | 3 modules moindre privilege : GenAI, CI/CD, killswitch      |
| **Projet**                 | Isolation dans un projet Scaleway dedie                      |
| **Kill switch**            | Cron horaire, poweroff automatique a 13 EUR                 |
| **Email**                  | TEM avec SPF + DKIM + DMARC                                |
| **Metadata**               | Endpoint 169.254.169.254 bloque (iptables)                  |

---

## 7. Controle budgetaire

### 7.1 Estimation des couts mensuels

| Poste                           | Cout estime          |
|---------------------------------|----------------------|
| Instance DEV1-S                 | ~6.42 EUR            |
| IP publique (IPv4 flexible)     | ~2.92 EUR            |
| Stockage 20 Go local            | Inclus               |
| Pomerium Serverless Container   | ~0.42 EUR            |
| Private Network                 | 0 EUR                |
| Cockpit (metriques Scaleway)    | 0 EUR                |
| Object Storage (state ~Ko)     | ~0 EUR (negligeable) |
| Domaine (amorti)                | ~2.29 EUR |
| TEM (< 300 emails/mois)        | 0 EUR                |
| Generative APIs (free tier)     | 0 EUR (1M tokens, credit unique) |
| Generative APIs (au-dela)       | ~0.20-2.50 EUR       |
| Container Registry (images)     | ~0 EUR (negligeable) |
| **Total estime**                | **~12-16 EUR/mois** (base ~12 + API ~0-4) |

### 7.2 Kill switch budgetaire (automatise)

Le kill switch remplace les alertes manuelles de la console Scaleway (qui sont org-wide, pas par projet, et sans API pour les creer).

- **Cron horaire** : Serverless Function interroge la Billing API par projet
- **10 EUR** : email d'avertissement via TEM
- **13 EUR** : email + poweroff automatique de l'instance
- **Token HTTP** : permet aussi un declenchement manuel pour les tests

### 7.3 Risques de surfacturation

> **IMPORTANT** : Scaleway n'offre **aucun hard spending cap**. Le kill switch budgetaire est la seule protection.

| Scenario | Cout potentiel | Mitigation |
|----------|---------------|------------|
| Abus webhook -> appels LLM | 260-875 EUR/mois | Rate limiting Caddy (30 req/min) |
| Boucle infinie agent | 500+ EUR/mois | Circuit breaker OpenClaw |
| Modele cher accidentel (70b au lieu de 8b) | x10-50 | Config forcee dans cloud-init |
| Instance oubliee | ~12 EUR/mois perpetuel | Kill switch + alerte |

---

## 8. Deploiement — Etapes

### Phase 1 : Preparation (manuelle, une seule fois)

1. **Scaleway** : Creer un compte + generer une API key admin (Organization scope)
2. **Domaine** : Enregistrer `<domain>` via Scaleway Domains (ou laisser OpenTofu le faire via `domain_owner_contact`)
3. **IdP** : Creer une OAuth App dans [GitHub Settings > Developer settings > OAuth Apps](https://github.com/settings/developers) (callback URL: `https://auth.<domain>/oauth2/callback`)
4. **GitHub PAT** : Creer un PAT avec scope `repo` pour la gestion des GitHub Secrets et Renovate

> **Automatise par OpenTofu** : cle SSH Ed25519 (`tls_private_key`), secrets Pomerium (`random_bytes`), token kill switch (`random_password`), GitHub Actions Secrets (`github_actions_secret`).

### Phase 2 : Bootstrap du backend S3

```bash
cd terraform/bootstrap/
tofu init
tofu apply
# -> Note la passphrase generee
```

### Phase 3 : Premier deploiement

```bash
cd terraform/
tofu init -backend-config=backend.conf
tofu test           # 34 tests, ~15s
tofu plan
tofu apply
# -> Sauvegarder la cle SSH: tofu output -raw ssh_private_key > ~/.ssh/openclaw && chmod 600 ~/.ssh/openclaw
```

### Phase 4 : Configuration Pomerium ROUTES

1. `tofu output instance_private_ip` -> noter l'IP privee
2. Generer routes YAML avec l'IP privee, encoder base64
3. Mettre a jour `pomerium_routes_b64` dans `terraform.tfvars`
4. `tofu apply` -> injecte les routes

### Phase 5 : Validation

- [ ] DNS propages : `dig app.<domain>`, `dig webhooks.<domain>`
- [ ] TLS actif : `curl -I https://app.<domain>`, `curl -I https://webhooks.<domain>`
- [ ] Pomerium SSO fonctionnel : acces `https://app.<domain>` -> GitHub OAuth
- [ ] OpenClaw repond : `curl -s http://localhost:3000` depuis l'instance
- [ ] Kill switch actif : `tofu output killswitch_webhook_url` -> test curl
- [ ] CI/CD fonctionnel : PR -> plan commentaire, merge -> apply

---

## 9. Risques et mitigations

| # | Risque | Impact | Mitigation |
|---|--------|--------|------------|
| 1 | Surfacturation API (abus webhook) | 260-875 EUR/mois | Rate limiting Caddy + kill switch |
| 2 | Surfacturation API (boucle agent) | 500+ EUR/mois | Circuit breaker + kill switch |
| 3 | OOM avec browser automation | Service crash | Swap 1 Go + limites concurrence |
| 4 | Faille OpenClaw (supply chain) | Compromission | Podman rootless, SG strict, version epinglee |
| 5 | Secrets dans cloud-init/metadata | Fuite API key | Nettoyage post-install + blocage metadata |
| 6 | Apply concurrent (pas de lock) | State corrompu | GitHub Actions sequentiel |
| 7 | ROUTES Pomerium manuelles | Web UI KO | Documente dans Phase 4 |

---

## 10. Evolutions futures (hors perimetre v1)

- **State locking** : Mecanisme de lock custom
- **Pomerium routes automatisees** : Generation dynamique via data source
- **Backup** : Snapshots automatiques via `scaleway_instance_snapshot`
- **Alertes Cockpit** : CPU, RAM, disque via `scaleway_cockpit_alert_manager`
- **Egress filtering** : Restreindre les sorties aux endpoints necessaires
- **Rotation automatisee des secrets** : Script ou GitHub Action trimestrielle

---

## 11. Metriques de succes

| Metrique | Methode de mesure | Cible | Frequence |
|----------|-------------------|-------|-----------|
| **Uptime instance** | Cockpit metriques | > 99% (hors maintenance) | Continu |
| **Latence LLM p95** | Logs OpenClaw | < 5 secondes | Hebdomadaire |
| **Facture mensuelle** | Scaleway Billing | < 20 EUR/mois total | Mensuelle |
| **Score audit securite** | Skill `/audit-security` | >= 80% conformes | A chaque PR infra |
| **Temps de rebuild** | `tofu destroy` + `tofu apply` | < 30 minutes | Trimestriel |
| **Tests OpenTofu** | `tofu test` | 34/34 pass | A chaque PR |

---

## 12. Questions ouvertes

| # | Question | Statut |
|---|----------|--------|
| Q1 | ~~Quel IdP pour Pomerium ?~~ | Resolu — **GitHub OAuth** |
| Q2 | ~~Quel nom de domaine ?~~ | Resolu — configure via `var.domain_name` (Scaleway Domains) |
| Q3 | Quels canaux messaging activer en priorite ? | A decider |
| Q4 | ~~Epingler Pomerium ?~~ | Resolu — variable `pomerium_version` (default `v0.32.0`) |
| Q5 | ~~IP privee stable apres reboot ?~~ | Resolu — **OUI** (IPAM Scaleway, statique) |
| Q6 | ~~Free tier Generative APIs mensuel ?~~ | Resolu — **NON**, credit unique 1M tokens |
| Q7 | ~~Kill switch en v1 ?~~ | Resolu — **OUI**, implemente (cron horaire + TEM) |
| Q8 | ~~Module rate_limit Caddy standard ?~~ | Resolu — **NON**, build custom xcaddy |
| Q9 | ~~baseUrl Generative APIs ?~~ | Resolu — **DOIT inclure project_id** (`api.scaleway.ai/{pid}/v1`) |

---

## 13. References

- [OpenClaw — Documentation officielle](https://docs.openclaw.ai/)
- [OpenClaw — GitHub](https://github.com/openclaw/openclaw)
- [Pomerium — Documentation](https://www.pomerium.com/docs/)
- [Scaleway Generative APIs](https://www.scaleway.com/en/generative-apis/)
- [Scaleway Generative APIs — Troubleshooting](https://www.scaleway.com/en/docs/generative-apis/troubleshooting/fixing-common-issues/)
- [OpenTofu — Documentation](https://opentofu.org/docs/)
- [OpenTofu — State Encryption](https://opentofu.org/docs/language/state/encryption/)
- [Scaleway Terraform/OpenTofu Provider](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs)
- [Scaleway — Domains](https://www.scaleway.com/en/docs/managed-services/domains-and-dns/)
- [Scaleway — Transactional Email](https://www.scaleway.com/en/docs/managed-services/transactional-email/)
- [Scaleway — Custom Domain Container](https://www.scaleway.com/en/docs/serverless-containers/how-to/add-a-custom-domain-to-a-container/)
- [Scaleway — Backend S3 Guide](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/guides/backend_guide)
- [Caddy Server](https://caddyserver.com/docs/)
- [caddy-ratelimit](https://github.com/mholt/caddy-ratelimit)
