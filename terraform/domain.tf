# --- Enregistrement domaine via Scaleway Domains ---
# Conditionnel : ne s'active que si domain_owner_contact est renseigne dans tfvars
# Prix : 27.53 EUR/an (renouvellement auto desactive par defaut)

resource "scaleway_domain_registration" "grob_ninja" {
  count = var.domain_owner_contact != null ? 1 : 0

  domain_names      = [var.domain_name]
  duration_in_years = 1
  auto_renew        = false
  project_id        = local.project_id

  lifecycle {
    prevent_destroy = true
  }

  owner_contact {
    legal_form                  = var.domain_owner_contact.legal_form
    firstname                   = var.domain_owner_contact.firstname
    lastname                    = var.domain_owner_contact.lastname
    email                       = var.domain_owner_contact.email
    phone_number                = var.domain_owner_contact.phone_number
    address_line_1              = var.domain_owner_contact.address_line_1
    zip                         = var.domain_owner_contact.zip
    city                        = var.domain_owner_contact.city
    country                     = var.domain_owner_contact.country
    company_name                = var.domain_owner_contact.company_name
    vat_identification_code     = var.domain_owner_contact.vat_identification_code
    company_identification_code = var.domain_owner_contact.company_identification_code

    # Contact francais particulier : extension_fr obligatoire pour eviter la validation SIRET
    extension_fr {
      mode = "individual"
      individual_info {
        whois_opt_in = false
      }
    }
  }
}
