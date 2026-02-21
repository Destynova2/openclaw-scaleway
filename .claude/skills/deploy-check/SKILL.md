---
name: deploy-check
description: Checklist pre-deploiement et verification post-deploiement
user_invocable: true
---

# Checklist Deploiement Scaleway

Quand l'utilisateur demande de verifier un deploiement, suivre cette checklist.

## Pre-deploiement

### 1. Prerequis
- [ ] Compte Scaleway actif avec API key admin (Organization scope) pour le premier apply
- [ ] Domaine enregistre via Scaleway Domains (configure via `var.domain_name`)
- [ ] GitHub OAuth App creee pour Pomerium (Client ID + Secret)
- [ ] `encryption_passphrase` generee (min 16 chars) pour le chiffrement du state

Note : SSH key, secrets Pomerium (cookie + shared) sont generes automatiquement par OpenTofu (`tls_private_key`, `random_bytes`).

### 2. Variables a fournir (terraform.tfvars)
```hcl
scw_organization_id        = "..."
admin_ip_cidr              = "x.x.x.x/32"
admin_email                = "admin@example.com"
domain_name                = "example.com"
openclaw_version           = "1.0.0"
pomerium_idp_client_id     = "..."
pomerium_idp_client_secret = "..."
encryption_passphrase      = "..."
# GitHub CI/CD :
github_token               = "ghp_..."
github_owner               = "owner"
github_repository          = "repo"
```

### 3. GitHub Secrets (auto-configures par le bootstrap ou par tofu apply)
23 secrets generes automatiquement par le bootstrap (dont `RENOVATE_TOKEN`).

### 4. Bootstrap S3 + GitHub Secrets
```bash
cd terraform/bootstrap/
tofu init && tofu plan -var-file=../terraform.tfvars
# Verifier : 1 bucket a creer, versioning active, 22 github_actions_secret
tofu apply -var-file=../terraform.tfvars
```

### 5. Validation OpenTofu
```bash
cd terraform/
tofu init -backend-config=backend.conf
tofu validate
tofu test          # 34 tests doivent passer
tofu plan -out=plan.tfplan 2>&1 | tee plan.log
```
Verifier dans le plan :
- [ ] Nombre de ressources attendu (~20-25 pour le deploiement complet)
- [ ] Pas de `destroy` inattendu
- [ ] Les secrets ne sont pas affiches en clair

## Post-deploiement

### 6. Infrastructure
- [ ] Projet visible dans la console Scaleway
- [ ] Instance DEV1-S en etat `running`
- [ ] IP publique attribuee
- [ ] Security group attache avec regles drop-by-default
- [ ] Private Network cree

### 7. DNS et TLS
```bash
dig app.<domain>         # CNAME vers Pomerium .scw.cloud
dig webhooks.<domain>    # A vers IP publique
curl -I https://app.<domain>        # certificat Let's Encrypt valide
curl -I https://webhooks.<domain>   # certificat Let's Encrypt (Caddy)
```

### 8. Pomerium
- [ ] Container Serverless en etat `ready` dans la console
- [ ] Custom domain attache avec certificat actif
- [ ] Acces `https://app.<domain>` → redirection SSO GitHub
- [ ] Apres auth SSO → acces web UI OpenClaw
- [ ] Routes configurees vers `instance_private_ip:3000`

### 9. OpenClaw (Podman rootless)
```bash
ssh root@<IP_PUBLIQUE>
# Verifier le pod Podman
su - openclaw -s /bin/bash
podman pod ps                        # pod "openclaw" running
podman ps                            # 2 containers (openclaw + caddy)
curl -s http://localhost:3000        # OpenClaw repond (via hostPort)
# Verifier Caddy
curl -I https://webhooks.<domain>    # TLS + rate_limit actif
```

### 10. Securite containers
```bash
# Verifier rootless
podman pod inspect openclaw | grep -i user    # uid 1000
# Verifier seccomp
podman inspect openclaw-openclaw | grep -i seccomp
# Verifier read-only rootfs
podman inspect openclaw-caddy | grep ReadOnly
# Swap
free -h                                       # doit montrer 1G swap
# Cloud-init cleanup
ls /var/lib/cloud/instances/*/user-data.txt   # doit etre absent
```

### 11. Fail2ban et recovery SSH
```bash
ssh root@<IP_PUBLIQUE>
# Verifier que fail2ban tourne
systemctl status fail2ban
fail2ban-client status sshd

# Verifier le hardening SSH
sshd -T | grep -E 'passwordauth|maxauthtries|permitroot'
# Attendu : passwordauthentication no, maxauthtries 3, permitrootlogin prohibit-password
```
- [ ] fail2ban actif avec jail sshd (maxretry=3, bantime=3600)
- [ ] Password auth desactive
- [ ] **Test lockout** : depuis une autre IP (ou via `fail2ban-client set sshd banip <TON_IP>`), verifier le ban puis debannir :
  ```bash
  # Simuler un ban
  fail2ban-client set sshd banip 1.2.3.4
  fail2ban-client status sshd        # 1.2.3.4 dans la liste
  fail2ban-client set sshd unbanip 1.2.3.4
  ```
- [ ] **Test recovery reboot** : se bannir volontairement, puis reboot depuis la console Scaleway → verifier que le ban est leve (bans en memoire, pas persistantes)

### 12. Monitoring et budget
- [ ] Cockpit actif dans la console Scaleway (auto-active)
- [ ] Alertes de facturation configurees dans la console (70%, 90%, 100% du budget)
- [ ] Kill switch Serverless Function deployee et testable
- [ ] Verifier la facture estimee dans Billing

### 12. Webhooks
```bash
# Envoyer un message test depuis Telegram/WhatsApp
# Verifier dans les logs OpenClaw :
podman logs openclaw-openclaw --tail 50
```
