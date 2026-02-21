---
name: audit-cicd
description: Audit du pipeline GitHub Actions — securite, fiabilite, bonnes pratiques
user_invocable: true
---

# Audit CI/CD — GitHub Actions

Analyse les workflows GitHub Actions pour verifier les bonnes pratiques de securite, fiabilite et performance.

## Checklist

### 1. Securite du pipeline
- [ ] Secrets utilises via `${{ secrets.* }}` (jamais en dur)
- [ ] `permissions` declarees explicitement (pas de `permissions: write-all`)
- [ ] `pull-requests: write` uniquement si necessaire (commentaires PR)
- [ ] `contents: read` par defaut (pas `write` sauf pour push/release)
- [ ] Actions tierces epinglees par SHA (ex: `actions/checkout@abc123`) et pas juste `@v4`
- [ ] Pas de `--no-verify`, `--force`, ou `--hard` dans les commandes
- [ ] Environment protection configure sur les jobs destructifs (apply, deploy)
- [ ] Required reviewers sur l'environment production

### 2. OpenTofu specifique
- [ ] `tofu init` avant `validate` et `plan`
- [ ] `tofu plan -out=plan.tfplan` sauvegarde le plan
- [ ] `tofu apply plan.tfplan` utilise le plan sauvegarde (pas `-auto-approve` seul)
- [ ] Plan poste en commentaire PR pour review
- [ ] `tofu validate` execute avant plan
- [ ] Backend S3 configure correctement (credentials via env vars)
- [ ] State encryption configuree (PBKDF2 + AES-GCM)

### 3. Fiabilite
- [ ] `continue-on-error` utilise avec prudence (pas sur les etapes critiques)
- [ ] Jobs `plan` et `apply` separes (pas dans le meme job)
- [ ] `apply` uniquement sur `push` vers `main` (pas sur PR)
- [ ] `plan` uniquement sur `pull_request` (pas sur push)
- [ ] Condition `if:` correcte pour chaque job
- [ ] `working-directory` configure si le code n'est pas a la racine

### 4. Performance
- [ ] Cache OpenTofu provider (`actions/cache` sur `.terraform/providers`)
- [ ] Version OpenTofu epinglee (`tofu_version: "1.8"`)
- [ ] Paths filter pour ne declencher que sur les fichiers pertinents

### 5. Dependency Management (Renovate)
- [ ] `renovatebot/github-action` epinglee par SHA (pas juste tag `@v46.0.1`)
- [ ] `RENOVATE_TOKEN` est un fine-grained PAT scope au repo uniquement (pas classic PAT full `repo`)
- [ ] `renovate.json` valide contre le JSON schema officiel
- [ ] Automerge restreint a minor/patch uniquement (jamais major)
- [ ] Composants critiques (Pomerium, OpenTofu providers) en `automerge: false`
- [ ] `prHourlyLimit` et `prConcurrentLimit` configures (anti-flood)
- [ ] Schedule configure (`schedule` field) pour eviter les disruptions
- [ ] `concurrency` block dans le workflow (pas de runs paralleles)
- [ ] `timeout-minutes` configure sur le job Renovate
- [ ] Custom managers (`customManagers`) regex patterns corrects et testes

### 6. Observabilite
- [ ] Echec du plan visible dans la PR (commentaire avec le plan)
- [ ] Artefacts sauvegardes si necessaire (plan file)
- [ ] Notifications sur echec (optionnel : Slack, email)

## Format de sortie

```markdown
## Audit CI/CD — [date]

### Score : X/Y conformes

| # | Categorie | Point | Statut | Fichier:ligne |
|---|-----------|-------|--------|---------------|

### Recommandations
1. ...
```
