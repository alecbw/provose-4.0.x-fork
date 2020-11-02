module "myproject" {
  source = "github.com/provose/provose?ref=v1.0.2"
  provose_config = {
    authentication = {
      aws = {
        region     = "us-east-1"
        access_key = var.access_key
        secret_key = var.secret_key
      }
    }
    name                 = "myproject"
    internal_root_domain = "example-internal.com"
    internal_subdomain   = "production"
  }
}
