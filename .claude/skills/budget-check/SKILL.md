---
name: budget-check
description: Verification rapide du budget Scaleway par analyse des ressources Terraform
user_invocable: true
---

# Budget Check — Analyse de couts Scaleway

Analyse les fichiers Terraform pour estimer le cout mensuel et detecter les risques de surfacturation. Skill leger (Haiku).

## Grille tarifaire Scaleway (fr-par, 2025)

### Instances
| Type | vCPU | RAM | Cout/mois |
|------|------|-----|-----------|
| STARDUST1-S | 1 | 1 Go | ~0.10 EUR |
| DEV1-S | 2 | 2 Go | ~6.42 EUR |
| DEV1-M | 3 | 4 Go | ~12.84 EUR |
| DEV1-L | 4 | 8 Go | ~25.68 EUR |
| GP1-XS | 4 | 16 Go | ~32.12 EUR |

### Ressources additionnelles
| Ressource | Cout/mois |
|-----------|-----------|
| IPv4 flexible | ~2.92 EUR |
| Object Storage | ~0.01 EUR/Go |
| Private Network | 0 EUR |
| Cockpit (metriques) | 0 EUR |

### Serverless Containers
| Ressource | Free tier/mois | Cout exces |
|-----------|---------------|------------|
| Memoire | 400 000 GB-s | ~0.10 EUR / 100k GB-s |
| vCPU | 200 000 vCPU-s | ~0.10 EUR / 100k vCPU-s |

Formule always-on : `memory_Go x 2_592_000s` et `vcpu x 2_592_000s`

### Generative APIs
| Modele | Input/M tokens | Output/M tokens |
|--------|---------------|-----------------|
| llama-3.1-8b | ~0.20 EUR | ~0.20 EUR |
| mistral-small | ~0.30 EUR | ~0.90 EUR |
| llama-3.1-70b | ~0.88 EUR | ~0.88 EUR |

Free tier : 1M tokens (credit unique, non renouvelable).

## Procedure d'audit

1. Scanner les fichiers `.tf` pour extraire toutes les ressources facturables
2. Pour chaque ressource, calculer le cout mensuel
3. Verifier les `scaleway_instance_ip` (souvent oubliees dans le budget)
4. Calculer le cout Serverless Containers (memory x min_scale x 30j)
5. Estimer le pire cas Generative APIs (requetes/jour x tokens/requete x cout)
6. Comparer au budget projet (~20 EUR/mois, incluant domaine .ai ~6.25 EUR/mois amorti)

## Format de sortie

```markdown
## Budget Check — [date]

| # | Ressource | Type | Cout/mois | Note |
|---|-----------|------|-----------|------|

**Total base** : X EUR/mois
**Budget projet** : ~20 EUR/mois
**Marge** : Y EUR/mois
**Pire cas (abus API)** : Z EUR/mois

### Alertes
- [OK/WARN/CRITICAL] ...
```
