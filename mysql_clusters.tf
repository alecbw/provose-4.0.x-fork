# This resource generates a random suffix to the
# AWS RDS final snapshot identifier.
# This is to avoid name conflicts when the same database is created
# and destroyed twice.
resource "random_string" "mysql_clusters__final_snapshot_id" {
  for_each = var.mysql_clusters
  keepers = {
    provose_config__name                           = var.provose_config.name
    cluster_name                                   = each.key
    engine_version                                 = each.value.engine_version
    overrides__mysql_clusters__aws_db_subnet_group = try(var.overrides.mysql_clusters__aws_db_subnet_group, "")
  }
  # AWS RDS final snapshot identifiers are stored in lowercase, so
  # uppercase characters would not add additional entropy.
  upper = false
  # Final snapshot identifiers also do not support special characters,
  # except for hyphens. It is also forbidden to end the identifier
  # with a hyphen or to use two consecutive hyphens, so we avoid special
  # characters all together.
  special = false
  length  = 20
}

resource "aws_security_group" "mysql_clusters" {
  count = length(var.mysql_clusters) > 0 ? 1 : 0

  name                   = "P/v1/${var.provose_config.name}/mysql"
  description            = "Provose security group owned by module ${var.provose_config.name}, authorizing MySQL access within the VPC."
  vpc_id                 = aws_vpc.vpc.id
  revoke_rules_on_delete = true
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }
  tags = {
    Provose = var.provose_config.name
  }
}

resource "aws_db_subnet_group" "mysql_clusters" {
  count = length(var.mysql_clusters) > 0 ? 1 : 0

  name = try(
    var.overrides.mysql_clusters__aws_db_subnet_group,
    "p-v1-${var.provose_config.name}-mysql-sg"
  )
  subnet_ids = aws_subnet.vpc[*].id
}

locals {
  mysql_clusters__parameter_group_family = {
    for key, config in var.mysql_clusters :
    key => "aurora-mysql5.7"
  }
}

resource "aws_rds_cluster_parameter_group" "mysql_clusters" {
  for_each    = local.mysql_clusters__parameter_group_family
  name        = "p-v1-${var.provose_config.name}-${each.key}-mysql-cluster-pg"
  family      = each.value
  description = "Provose cluster parameter group for AWS Aurora MySQL, for module ${var.provose_config.name} and cluster ${each.key}"
}

resource "aws_db_parameter_group" "mysql_clusters" {
  for_each    = local.mysql_clusters__parameter_group_family
  name        = "p-v1-${var.provose_config.name}-${each.key}-mysql-db-pg"
  family      = each.value
  description = "Provose database parameter group for AWS Aurora MySQL, for module ${var.provose_config.name} and cluster ${each.key}"
  parameter {
    name         = "max_connections"
    value        = 5000
    apply_method = "pending-reboot"
  }
}

resource "aws_rds_cluster" "mysql_clusters" {
  for_each = {
    for key, database in var.mysql_clusters :
    key => {
      database             = database
      parameter_group_name = aws_rds_cluster_parameter_group.mysql_clusters[key].name
      # We generate final snapshot identifiers with random names so that there
      # are no conflicts when the user creates a database, destroys it (creating the
      # final snapshot), and then tries to create and destroy the database again.
      # The snapshot identifier is also not allowed to have two consecutive hyphens
      # so we make sure to remove that from the database name.
      # The final snapshot name must be a maxiumum of 255 characters.
      final_snapshot_identifier = "p-v1-${replace(var.provose_config.name, "--", "-")}-mysql-fs-${random_string.mysql_clusters__final_snapshot_id[key].result}"
    }
    if(
      contains(keys(aws_rds_cluster_parameter_group.mysql_clusters), key) &&
      contains(keys(random_string.mysql_clusters__final_snapshot_id), key)
    )
  }

  apply_immediately               = try(each.value.database.apply_immediately, true)
  engine                          = "aurora-mysql"
  engine_mode                     = "provisioned"
  cluster_identifier              = each.key
  master_username                 = try(each.value.database.username, "root")
  master_password                 = each.value.database.password
  vpc_security_group_ids          = [aws_security_group.mysql_clusters[0].id]
  engine_version                  = each.value.database.engine_version
  db_subnet_group_name            = aws_db_subnet_group.mysql_clusters[0].name
  db_cluster_parameter_group_name = each.value.parameter_group_name
  database_name                   = each.value.database.database_name
  snapshot_identifier             = try(each.value.database.snapshot_identifier, null)
  deletion_protection             = try(each.value.database.deletion_protection, true)
  copy_tags_to_snapshot           = true
  final_snapshot_identifier       = each.value.final_snapshot_identifier
  skip_final_snapshot             = false
  tags = {
    Provose = var.provose_config.name
  }
}

resource "aws_rds_cluster_instance" "mysql_clusters" {
  for_each = zipmap(
    flatten([
      for key, value in var.mysql_clusters : [
        for i in range(value.instances.instance_count) :
        join("-", [key, i])
      ]
    ]),
    flatten([
      for key, value in var.mysql_clusters : [
        for i in range(value.instances.instance_count) :
        {
          key                = key
          cluster_identifier = aws_rds_cluster.mysql_clusters[key].id
          instance_type      = value.instances.instance_type
          # AWS RDS Performance Insights is not available on MySQL
          # with db.t2 or db.t3 instances.
          performance_insights_enabled = length(regexall("^db\\.t[23]", value.instances.instance_type)) < 1
          apply_immediately            = try(value.apply_immediately, true)
        }
      ]
    ])
  )
  apply_immediately            = each.value.apply_immediately
  engine                       = "aurora-mysql"
  identifier                   = each.key
  cluster_identifier           = each.value.cluster_identifier
  instance_class               = each.value.instance_type
  db_subnet_group_name         = aws_db_subnet_group.mysql_clusters[0].name
  db_parameter_group_name      = aws_db_parameter_group.mysql_clusters[each.value.key].name
  performance_insights_enabled = each.value.performance_insights_enabled

  depends_on = [aws_rds_cluster.mysql_clusters]
  tags = {
    Provose = var.provose_config.name
  }
}

resource "aws_route53_record" "mysql_clusters" {
  for_each = aws_rds_cluster.mysql_clusters

  zone_id = aws_route53_zone.internal_dns.zone_id
  name    = "${each.key}.${var.provose_config.internal_subdomain}"
  type    = "CNAME"
  ttl     = "5"
  records = [each.value.endpoint]
}

resource "aws_route53_record" "mysql_clusters__readonly" {
  for_each = aws_rds_cluster.mysql_clusters

  zone_id = aws_route53_zone.internal_dns.zone_id
  name    = "${each.key}-readonly.${var.provose_config.internal_subdomain}"
  type    = "CNAME"
  ttl     = "5"
  records = [each.value.reader_endpoint]
}

# == Output == 

output "mysql_clusters" {
  value = {
    aws_db_subnet_group = {
      mysql_clusters = aws_db_subnet_group.mysql_clusters
    }
    aws_security_group = {
      mysql_clusters = aws_security_group.mysql_clusters
    }
    aws_rds_cluster = {
      mysql_clusters = aws_rds_cluster.mysql_clusters
    }
    aws_rds_cluster_instance = {
      mysql_clusters = aws_rds_cluster_instance.mysql_clusters
    }
    aws_route53_record = {
      mysql_clusters           = aws_route53_record.mysql_clusters
      mysql_clusters__readonly = aws_route53_record.mysql_clusters__readonly
    }
  }
}
