# -----------------------------------------------------------------------
# Instance reconciliation — reboots the instance when cloud-init changes.
#
# cloud_init_content is defined in instance.tf (locals block).
# cloud-init only runs on first boot. When OpenTofu detects a change in
# cloud-init content (templates, config files), this null_resource triggers
# a reboot so the reconcile-config.py per-boot script picks up the new
# metadata and updates on-disk files.
#
# The 5s sleep avoids racing with the Scaleway API (instance state must
# settle after user_data update before accepting a reboot action).
# -----------------------------------------------------------------------
resource "null_resource" "instance_reconcile" {
  triggers = {
    cloud_init_hash = sha256(local.cloud_init_content)
  }

  provisioner "local-exec" {
    command = <<-EOT
      sleep 5
      SERVER_ID=$(echo "$INSTANCE_ID" | cut -d/ -f2)
      curl -sf -X POST \
        "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers/$SERVER_ID/action" \
        -H "Content-Type: application/json" \
        -H "X-Auth-Token: $SCW_SECRET_KEY" \
        -d '{"action": "reboot"}'
      echo "Instance reboot triggered (cloud-init changed)"
    EOT
    environment = {
      SCW_SECRET_KEY = var.scw_secret_key
      INSTANCE_ID    = scaleway_instance_server.openclaw.id
    }
  }

  depends_on = [scaleway_instance_server.openclaw]
}
