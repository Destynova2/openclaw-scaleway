---
name: scan-secrets
description: Detection de secrets en dur dans le code source et les configs Terraform
user_invocable: true
---

# Scan Secrets — Detection de fuites

Scan statique des fichiers du projet pour detecter des secrets en dur, des credentials exposees, ou des configurations de secrets incorrectes. Skill leger (Haiku), lecture seule.

## Patterns recherches

### 1. Secrets en dur dans les fichiers
Rechercher via Grep les patterns suivants dans tous les fichiers (sauf `.terraform/`, `node_modules/`) :

```
# API Keys
(sk|pk|api[_-]?key|secret[_-]?key|access[_-]?key)["\s]*[:=]\s*["'][A-Za-z0-9+/=]{20,}
# Tokens
(token|bearer|auth)["\s]*[:=]\s*["'][A-Za-z0-9._-]{20,}
# Passwords
(password|passwd|pwd)["\s]*[:=]\s*["'][^"']{8,}
# Private keys
-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----
# AWS/Scaleway style keys
(SCW|AKID|AKIA)[A-Z0-9]{12,}
```

### 2. Variables Terraform
- [ ] Toutes les variables contenant `secret`, `key`, `password`, `token` sont marquees `sensitive = true`
- [ ] Pas de `default` sur les variables sensibles (force l'injection externe)
- [ ] `terraform.tfvars` est dans `.gitignore`

### 3. Cloud-init et user_data
- [ ] Pas de secrets en clair dans les templates cloud-init (utiliser `templatefile` avec variables)
- [ ] Post-installation : nettoyage de `/var/lib/cloud/instances/*/user-data.txt`
- [ ] Post-installation : nettoyage de `/var/log/cloud-init-output.log`
- [ ] Metadata endpoint bloque (protection SSRF)

### 4. Docker et containers
- [ ] Secrets injectes via `secret_environment_variables` (pas `environment_variables`)
- [ ] Pas de `ENV SECRET=...` dans les Dockerfiles
- [ ] Pas de credentials dans les layers d'image

### 5. CI/CD
- [ ] Secrets GitHub references via `${{ secrets.* }}`
- [ ] Pas de `echo $SECRET` ou `printenv` dans les workflows
- [ ] Pas de secrets dans les artefacts ou les commentaires PR

### 6. Git history
- [ ] `.gitignore` couvre : `terraform.tfvars`, `*.tfstate`, `.env`, `*.pem`, `*.key`, `.terraform/`
- [ ] Recommander `git-secrets` ou `trufflehog` en pre-commit hook

## Format de sortie

```markdown
## Scan Secrets — [date]

### Resultats

| # | Severite | Fichier:ligne | Pattern detecte | Action |
|---|----------|---------------|-----------------|--------|

### Resume
- Fichiers scannes : N
- Secrets detectes : X
- Variables sensibles sans `sensitive = true` : Y
- Nettoyage post-install : OK/MANQUANT
```
