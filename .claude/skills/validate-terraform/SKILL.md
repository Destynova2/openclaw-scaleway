---
name: validate-terraform
description: Valide les fichiers Terraform Scaleway avant plan/apply
user_invocable: true
---

# Validation Terraform Scaleway

Quand l'utilisateur demande de valider du Terraform, effectue les verifications suivantes sur tous les fichiers `.tf` du projet :

## Checklist de validation

### 1. Syntaxe et structure
- Verifier que `tofu fmt -check` passe sans erreur
- Verifier que `tofu validate` passe
- Verifier la coherence des `required_providers` (pas de doublons entre fichiers)
- Verifier que TOUS les providers utilises sont declares dans `required_providers` (ex: `hashicorp/archive` si `data "archive_file"` est utilise)
- Verifier que `required_version` est specifie (y compris dans le bootstrap)

### 2. Provider Scaleway — erreurs courantes
- `scaleway_instance_server` : utiliser `private_network { pn_id = ... }` (bloc imbrique, PAS `private_network_id` plat)
- `scaleway_container` : utiliser `private_network_id` (argument plat, different de instance!)
- `.private_ip` n'existe PAS → utiliser `.private_ips[0].address` (attribut pluriel, top-level)
- `permission_set_ids` n'existe PAS sur `scaleway_iam_policy.rule` → utiliser `permission_set_names` (type set)
- `scaleway_cockpit` est DEPRECIE depuis janvier 2025 → Cockpit auto-active par projet
- `scaleway_cockpit_grafana_user` DEPRECIE (supprime Jan 2026) → `data "scaleway_cockpit_grafana"` + auth IAM
- `activate_vpc_integration` sur container namespace : DEPRECIE (toujours true)
- Les versions du provider OVH : la version actuelle est `~> 2.11`, pas `~> 0.47`

### 3. Serverless Containers
- Si `INSECURE_SERVER=true`, le port doit etre HTTP (8080), pas 443
- Les images Docker Hub ne peuvent PAS etre utilisees directement → il faut un `scaleway_registry_namespace`
- Verifier que `min_scale >= 1` si le service doit etre toujours disponible
- Verifier que `memory_limit` est suffisant (Pomerium all-in-one : minimum 256 Mo)

### 4. Backend S3
- Verifier que `skip_credentials_validation`, `skip_region_validation`, `skip_requesting_account_id`, `skip_s3_checksum` sont tous a `true`
- L'endpoint doit etre `https://s3.<region>.scw.cloud`

### 5. Securite
- Pas de secrets en dur dans les fichiers `.tf`
- Variables sensibles marquees `sensitive = true`
- `terraform.tfvars` dans `.gitignore`
- IAM : principe du moindre privilege (pas de `*FullAccess` sauf si justifie)

### 6. Robustesse
- `lifecycle { prevent_destroy = true }` sur les ressources critiques (project, bucket state, private network, tls_private_key)
- `tofu fmt -check` present dans le pipeline CI/CD (pas seulement en local)
- Drift detection : job cron periodique executant `tofu plan` pour detecter les changements hors-Terraform
- Images container epinglees par version ou digest (pas de tag `:latest` mutable sans suivi Renovate)
- Modules Go/Caddy epingles par version dans les Containerfiles (`--with module@version`)

### 7. Budget
- Verifier que les IP publiques (`scaleway_instance_ip`) sont comptees dans le budget (~2.92 EUR/mo chacune)
- Verifier les `memory_limit` des containers (impact direct sur le cout)

## Format de sortie

Produire un rapport structure :
```
## Resultat validation Terraform

### CRITICAL (bloquant)
- [ ] Description du probleme — fichier:ligne

### WARNING (a corriger)
- [ ] Description — fichier:ligne

### OK
- [x] Point verifie
```
