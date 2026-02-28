# VPC private network connecting the instance to Pomerium serverless container.
resource "scaleway_vpc_private_network" "openclaw" {
  provider = scaleway.project
  name     = "openclaw-vpc"
  tags     = local.default_tags

  lifecycle {
    prevent_destroy = true
  }
}
