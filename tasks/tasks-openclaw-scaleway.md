# Implementation Tasks — OpenClaw sur Scaleway via OpenTofu

> Generated from `docs/PRD.md`. Updated 2026-02-20 after cleanup.

## Relevant Files

| File | Purpose |
|------|---------|
| `terraform/bootstrap/main.tf` | Bootstrap: S3 bucket for OpenTofu state (one-time) |
| `terraform/main.tf` | Provider, backend S3, state encryption (PBKDF2+AES-GCM), project, locals |
| `terraform/variables.tf` | All input variables (Scaleway, Pomerium, GitHub, Brave, Telegram, encryption) |
| `terraform/outputs.tf` | Outputs: IPs, URLs, API keys, SSH key, kill switch URLs |
| `terraform/network.tf` | Private Network (VPC) |
| `terraform/security.tf` | Security group (drop-by-default) + firewall rules |
| `terraform/iam.tf` | 3x module iam-service-account (openclaw, cicd, killswitch) + SSH key |
| `terraform/instance.tf` | DEV1-S instance + cloud-init injection |
| `terraform/cloud-init.yaml.tftpl` | Cloud-init template: Podman pod (kube.yml + Quadlet) |
| `terraform/pomerium.tf` | Serverless Container: namespace, registry, container, env vars |
| `terraform/dns.tf` | Module dns-scaleway (6 records: app, auth, webhooks, SPF, DKIM, DMARC) |
| `terraform/domain.tf` | Domain registration via Scaleway Domains |
| `terraform/tem.tf` | Scaleway Transactional Email (SPF + DKIM) |
| `terraform/monitoring.tf` | Cockpit Grafana data source (auth IAM) |
| `terraform/killswitch.tf` | Serverless Function: budget kill switch (cron hourly, poweroff on >= 13 EUR) |
| `terraform/killswitch/handler.py` | Kill switch Python handler (dual mode: cron + HTTP) |
| `terraform/registry.tf` | Container Registry namespace |
| `terraform/github.tf` | GitHub Actions Secrets (auto via provider integrations/github) |
| `terraform/modules/iam-service-account/` | Reusable IAM module: application + API key(s) + policy (dynamic rules) |
| `terraform/modules/dns-scaleway/` | DNS module: scaleway_domain_record for_each (interchangeable interface) |
| `terraform/modules/dns-ovh/` | DNS module: ovh_domain_zone_record for_each (same interface, reserve) |
| `terraform/tests/*.tftest.hcl` | OpenTofu test files (34 tests with mock providers) |
| `terraform/terraform.tfvars` | Variable values for local runs (NEVER committed — in .gitignore) |
| `.github/workflows/opentofu.yml` | CI/CD: plan on PR, apply on merge main |
| `.github/workflows/build-caddy.yml` | Build Caddy image with rate_limit module |
| `.github/workflows/push-pomerium.yml` | Push Pomerium image to Scaleway Registry |
| `.github/workflows/build-openclaw.yml` | Build OpenClaw image |
| `.github/workflows/renovate.yml` | Self-hosted Renovate: dependency update PRs (cron every 6h) |
| `containers/Containerfile.caddy` | Caddy + xcaddy + rate_limit module |
| `containers/Containerfile.pomerium` | Pomerium all-in-one image |
| `containers/Containerfile.openclaw` | OpenClaw application image |
| `renovate.json` | Renovate config: schedule, packageRules, customManagers regex |
| `.gitignore` | Exclude tfvars, state, secrets, keys |

## Notes

- All HCL files go in `terraform/` directory
- All variables must be `sensitive = true` if they contain secrets
- Providers: `scaleway/scaleway ~> 2.69`, `hashicorp/tls ~> 4.0`, `hashicorp/random ~> 3.6`, `integrations/github ~> 6.0`, `hashicorp/archive ~> 2.7`
- OpenTofu `>= 1.8` required for native state encryption
- Pomerium version pinned via `var.pomerium_version` (default `v0.32.0`)
- Domain: configure via `var.domain_name` (Scaleway Domains registrar)
- Budget target: ~20 EUR/month (~12 base + ~4 API margin)
- **Scaleway pitfalls** : `private_network { pn_id }` = nested block on instance, `private_network_id` = flat arg on container, `permission_set_names` (NOT `ids`), `private_ips[0].address` (NOT `.private_ip`), `scaleway_cockpit` deprecated, IPv4 flexible billed separately (~2.92 EUR/month)
- **Modules** : child modules need `required_providers { scaleway = { source = "scaleway/scaleway" } }` to avoid hashicorp/scaleway ambiguity
- **Auto-generated secrets** : SSH key (tls_private_key Ed25519), Pomerium cookie/shared secrets (random_bytes), kill switch token (random_password)
- **Two-pass deploy** : First `tofu apply` creates infra but Pomerium routes need the instance private IP. Second apply injects the routes.

## Instructions for Completing Tasks

As you complete each task, mark it as done by converting `[ ]` to `[x]`.
Tasks should be completed in order — parent tasks are independent, sub-tasks within a parent are sequential.
Run `tofu validate` after each HCL file change. Run `tofu plan` after completing a full parent task.

---

## Tasks

### Phase 1 — Parent Tasks

- [ ] 0.0 Prerequisites: accounts, domain, keys, secrets (manual, one-time)
- [x] 1.0 Create feature branch and project structure
- [x] 2.0 Bootstrap S3 backend for OpenTofu state
- [x] 3.0 Core infrastructure: provider, backend, encryption, project, variables
- [x] 4.0 Networking and security: VPC + security group
- [x] 5.0 IAM, instance, and cloud-init provisioning
- [x] 6.0 Pomerium identity-aware proxy on Serverless Container
- [x] 7.0 DNS Scaleway Domains + TLS + custom domain
- [x] 8.0 Monitoring (Cockpit Grafana) + kill switch budgetaire
- [x] 9.0 CI/CD pipeline GitHub Actions
- [x] 10.0 OpenTofu tests (TDD with `tofu test`)
- [ ] 11.0 First deploy, Pomerium routes, and OpenClaw onboarding
- [ ] 12.0 Validation and disaster recovery test
- [x] 13.0 Automated dependency management (Renovate self-hosted)
- [x] 14.0 Modules refactoring (IAM + DNS interchangeable + locals + quick fixes)

---

### Phase 2 — Sub-Tasks

- [ ] **0.0 Prerequisites: accounts, domain, keys, secrets (manual, one-time)**
  - [ ] 0.1 Create a Scaleway account and generate an admin API key (Organization scope) — save Access Key + Secret Key. Note: this key is for **bootstrap only**; after first deploy, it will be replaced in GitHub Secrets by a project-scoped CI/CD key (see task 11.6)
  - [x] ~~0.2 Buy domain~~ -> Scaleway Domains via `var.domain_name`
  - [x] ~~0.3 Create OVH API credentials~~ -> **Removed: OVH provider removed, DNS via Scaleway Domains**
  - [x] 0.4 SSH keypair: **auto-generated** via `tls_private_key` Ed25519 (no manual step)
  - [ ] 0.5 Create a GitHub OAuth App in [Settings > Developer settings > OAuth Apps](https://github.com/settings/developers) (callback URL: `https://auth.<domain>/oauth2/callback`)
  - [x] 0.6 Pomerium secrets: **auto-generated** via `random_bytes` (no manual step)
  - [ ] 0.7 Generate encryption passphrase for state: `head -c32 /dev/urandom | base64` (minimum 16 chars)
  - [ ] 0.8 Configure GitHub Secrets (most auto-provisioned via OpenTofu, only `RENOVATE_TOKEN` is manual)

- [x] **1.0 Create feature branch and project structure**
  - [x] 1.1 Create branch `feat/openclaw-infra` from `main`
  - [x] 1.2 Create directory structure: `terraform/`, `terraform/bootstrap/`, `terraform/killswitch/`, `terraform/tests/`, `terraform/modules/`, `.github/workflows/`, `containers/`
  - [x] 1.3 Create `.gitignore` with: terraform.tfvars, *.tfstate, *.tfstate.backup, .terraform/, plan.tfplan, .env, *.pem, *.key

- [x] **2.0 Bootstrap S3 backend for OpenTofu state**
  - [x] 2.1 Create `terraform/bootstrap/main.tf`
  - [x] 2.2 Add `scaleway_object_bucket` resource with versioning + lifecycle rule
  - [x] 2.3 Add `output "bucket_name"`
  - [ ] 2.4 Run bootstrap (one-time manual step)

- [x] **3.0 Core infrastructure: provider, backend, encryption, project, variables**
  - [x] 3.1 Create `terraform/main.tf` with 5 providers: scaleway, tls, random, github, archive
  - [x] 3.2 Add `backend "s3"` block with `endpoints {}` syntax
  - [x] 3.3 Add `encryption {}` block (PBKDF2 + AES-GCM)
  - [x] 3.4 Add default + aliased `provider "scaleway"`
  - [x] 3.5 Add `scaleway_account_project` with `prevent_destroy = true`
  - [x] 3.6 Add `provider "github"` with conditional token
  - [x] 3.7 Add `locals` block: project_id, org_id, zone, region, default_tags
  - [x] 3.8 Create `terraform/variables.tf` (15 variables: scw_access_key, scw_secret_key, scw_organization_id, admin_ip_cidr, admin_email, domain_name, openclaw_version, chrome_headless_version, pomerium_version, pomerium_idp_client_id, pomerium_idp_client_secret, pomerium_routes_b64, github_token, github_repository, brave_search_api_key, github_agent_token, telegram_bot_token, state_project_id, domain_owner_contact, encryption_passphrase)
  - [x] 3.9 Create `terraform/outputs.tf` (11 outputs incl. ssh_private_key, killswitch URLs)

- [x] **4.0 Networking and security: VPC + security group**
  - [x] 4.1 `terraform/network.tf`: Private Network with local.default_tags
  - [x] 4.2 `terraform/security.tf`: Security group drop-by-default
  - [x] 4.3 Inbound rules: SSH (admin IP), HTTPS (0.0.0.0/0), HTTP (0.0.0.0/0)

- [x] **5.0 IAM, instance, and cloud-init provisioning**
  - [x] 5.1 `terraform/iam.tf`: 3x module iam-service-account (openclaw, cicd, killswitch) + SSH key
  - [x] 5.2-5.5 `terraform/cloud-init.yaml.tftpl`: Podman rootless pod with Quadlet
  - [x] 5.6 `terraform/instance.tf`: DEV1-S + cloud-init injection
  - [x] 5.7 Tests pass (34/34)

- [x] **6.0 Pomerium identity-aware proxy on Serverless Container**
  - [x] 6.1 `terraform/pomerium.tf`: namespace + registry + container (256Mo, port 8080, min_scale 1)
  - [x] 6.2 Environment vars: INSECURE_SERVER, ADDRESS, IDP_PROVIDER, AUTHENTICATE_SERVICE_URL
  - [x] 6.3 Secret env vars: IDP_CLIENT_ID/SECRET, COOKIE_SECRET, SHARED_SECRET, ROUTES

- [x] **7.0 DNS Scaleway Domains + TLS + custom domain**
  - [x] 7.1 `terraform/dns.tf`: module dns-scaleway with 6 records (app, auth, webhooks, SPF, DKIM, DMARC)
  - [x] 7.2 `terraform/domain.tf`: scaleway_domain_registration
  - [x] 7.3 `terraform/tem.tf`: scaleway_tem_domain (SPF + DKIM verification)
  - [x] 7.4 Container domains: pomerium_app + pomerium_auth with depends_on dns module

- [x] **8.0 Monitoring (Cockpit Grafana) + kill switch budgetaire**
  - [x] 8.1 `terraform/monitoring.tf`: data scaleway_cockpit_grafana (IAM auth, grafana_user deprecated)
  - [x] 8.2-8.3 `terraform/killswitch.tf`: Function + cron hourly + TEM alerts (10 EUR warning, 13 EUR poweroff)
  - [x] 8.4 `terraform/killswitch/handler.py`: dual mode handler (cron auto-check + HTTP manual trigger)
  - [x] 8.5 Outputs: killswitch_function_url (sensitive), killswitch_webhook_url (sensitive)

- [x] **9.0 CI/CD pipeline GitHub Actions**
  - [x] 9.1-9.6 `.github/workflows/opentofu.yml`: plan on PR, apply on merge main, environment protection, concurrency guards, timeouts

- [x] **10.0 OpenTofu tests (TDD with `tofu test`)** — 34/34 pass
  - [x] 10.1-10.12 All test files: variables_validation, project, iam, network, instance, container, dns, monitoring, serverless, outputs

- [ ] **11.0 First deploy, Pomerium routes, and OpenClaw onboarding**
  - [ ] 11.1 Create local `terraform/terraform.tfvars` with all variable values
  - [ ] 11.2 First deploy: `cd terraform && tofu init && tofu plan && tofu apply`
  - [ ] 11.3 Push Pomerium image to Scaleway Registry (or trigger workflow)
  - [ ] 11.4 Note instance_private_ip, generate Pomerium routes YAML, encode base64, update `pomerium_routes_b64`
  - [ ] 11.5 Second apply to inject Pomerium routes
  - [ ] 11.6 Rotate CI/CD key: replace org-scoped admin key with project-scoped CI/CD key in GitHub Secrets
  - [ ] 11.7 SSH to instance, verify pod running
  - [ ] 11.8 Run OpenClaw onboarding
  - [ ] 11.9 Connect messaging channels, configure webhook URLs: `https://webhooks.<domain>`
  - [ ] 11.10 Enable required OpenClaw skills

- [ ] **12.0 Validation and disaster recovery test**
  - [ ] 12.1 Verify DNS: `dig app.<domain>` (CNAME), `dig webhooks.<domain>` (A)
  - [ ] 12.2 Verify TLS: `curl -I https://app.<domain>`, `curl -I https://webhooks.<domain>`
  - [ ] 12.3 Verify hardening: daemon running, fail2ban, swap, metadata blocked, SSH password disabled
  - [ ] 12.4 Verify Pomerium SSO: `https://app.<domain>` -> GitHub OAuth -> web UI
  - [ ] 12.5 Verify Generative APIs: test message via OpenClaw
  - [ ] 12.6 Verify Grafana: Cockpit dashboard
  - [ ] 12.7 Test kill switch: trigger manually, verify instance powers off
  - [ ] 12.8 Test CI/CD: PR with plan comment, merge with apply
  - [ ] 12.9 Test disaster recovery: `tofu destroy` + `tofu apply` < 30min

- [x] **13.0 Automated dependency management (Renovate self-hosted)**
  - [ ] 13.1 Create PAT GitHub `RENOVATE_TOKEN` (manual)
  - [x] 13.2 `renovate.json` with presets, schedule, packageRules, customManagers
  - [x] 13.3 `.github/workflows/renovate.yml` with concurrency guard + timeout 30min
  - [ ] 13.4-13.6 Trigger, verify, merge onboarding PR

- [x] **14.0 Modules refactoring (IAM + DNS interchangeable + locals + quick fixes)**
  - [x] 14.1 Created `terraform/modules/iam-service-account/` (main.tf, variables.tf, outputs.tf)
  - [x] 14.2 Created `terraform/modules/dns-scaleway/` (main.tf, variables.tf, outputs.tf)
  - [x] 14.3 Created `terraform/modules/dns-ovh/` (main.tf, variables.tf, outputs.tf)
  - [x] 14.4 Refactored iam.tf: 3 module calls replacing triplicated IAM pattern
  - [x] 14.5 Refactored dns.tf: 1 module call replacing 6 individual records
  - [x] 14.6 Added locals block in main.tf, replaced inline refs across all .tf files
  - [x] 14.7 Fixed domain.tf hardcode: use `[var.domain_name]`
  - [x] 14.8 Added `sensitive = true` on killswitch_function_url output
  - [x] 14.9 Added `pomerium_version` variable
  - [x] 14.10 State migration executed (16 moves: 10 IAM + 6 DNS)
  - [x] 14.11 Updated all 10 test files for module overrides + domain example.com
  - [x] 14.12 State migration executed successfully (0 destroy, 8 cosmetic changes)
  - [x] 14.13 All tests pass (34/34)
