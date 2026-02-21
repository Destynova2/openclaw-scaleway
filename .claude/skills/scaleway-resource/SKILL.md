---
name: scaleway-resource
description: Reference rapide des ressources Terraform Scaleway avec les pieges connus
user_invocable: true
---

# Reference ressources Terraform Scaleway

Quand l'utilisateur demande de l'aide sur une ressource Terraform Scaleway, fournir la syntaxe correcte et les pieges connus.

## Ressources courantes et pieges

### scaleway_instance_server
```hcl
resource "scaleway_instance_server" "example" {
  type  = "DEV1-S"
  image = "ubuntu_noble"
  ip_id = scaleway_instance_ip.example.id
  # CORRECT : bloc imbrique avec pn_id (verifie provider v2.69)
  private_network {
    pn_id = scaleway_vpc_private_network.example.id
  }
  # INCORRECT : private_network_id = ... ← argument plat invalide sur instance_server
}
```
- IP privee : `scaleway_instance_server.example.private_ips[0].address` (PAS `.private_ip`)
- `user_data` est un map : `user_data = { cloud-init = "..." }`
- Types disponibles fr-par-1 : STARDUST1-S, DEV1-S, DEV1-M, DEV1-L, GP1-XS...

### scaleway_instance_ip
- ~2.92 EUR/mois pour une IPv4 flexible — PAS gratuite, PAS incluse dans l'instance
- Une IP = une facturation, meme si l'instance est arretee

### scaleway_container
```hcl
resource "scaleway_container" "example" {
  namespace_id   = scaleway_container_namespace.example.id
  registry_image = "${scaleway_registry_namespace.example.endpoint}/image:tag"
  port           = 8080  # Port HTTP sur lequel le container ecoute
  # Images Docker Hub directes NON supportees → passer par scaleway_registry_namespace
}
```
- Free tier : 400 000 GB-s + 200 000 vCPU-s/mois
- `min_scale = 0` = scale-to-zero (cold start ~1-5s), `min_scale = 1` = always-on

### scaleway_iam_policy
```hcl
resource "scaleway_iam_policy" "example" {
  rule {
    project_ids        = [scaleway_account_project.example.id]
    permission_set_names = ["GenerativeApisFullAccess"]
    # INCORRECT : permission_set_ids ← n'existe pas
  }
}
```

### scaleway_cockpit (DEPRECIE depuis janvier 2025)
- Ne PAS utiliser `scaleway_cockpit` → erreur avec provider >= 2.68
- Cockpit est active par defaut sur les projets Scaleway
- Pour les alertes : utiliser `scaleway_cockpit_alert_manager` (si disponible)
- `scaleway_cockpit_grafana_user` DEPRECIE (supprime Jan 2026) → utiliser `data "scaleway_cockpit_grafana"` + auth IAM

### scaleway_container_domain
```hcl
resource "scaleway_container_domain" "example" {
  container_id = scaleway_container.example.id
  hostname     = "sub.domain.com"
}
```
- Genere automatiquement un certificat Let's Encrypt
- Necessite un CNAME DNS pointant vers `scaleway_container.example.domain_name`

### scaleway_object_bucket (backend S3)
- Region : `fr-par` (pas `fr-par-1`)
- Endpoint S3 : `https://s3.fr-par.scw.cloud`
- Pas de state locking natif (pas d'equivalent DynamoDB)

## Pricing rapide (fr-par, fevrier 2025)

| Ressource | Cout mensuel |
|-----------|-------------|
| DEV1-S (2vCPU/2Go) | ~6.42 EUR |
| STARDUST1-S (1vCPU/1Go) | ~0.10 EUR |
| IPv4 flexible | ~2.92 EUR |
| Private Network | 0 EUR |
| Object Storage | ~0.01 EUR/Go |
| Container (256Mo always-on) | ~0.42 EUR |
| Cockpit metriques | 0 EUR |
