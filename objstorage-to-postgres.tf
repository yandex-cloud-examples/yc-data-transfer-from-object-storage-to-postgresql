# Infrastructure for Object Storage, the Managed Service for PostgreSQL, and Data Transfer
#
# RU: https://cloud.yandex.ru/docs/data-transfer/tutorials/objstorage-to-mpg
# EN: https://cloud.yandex.com/en/docs/data-transfer/tutorials/objstorage-to-mpg
#
# Specify the following settings:
locals {

  folder_id   = "" # Set your cloud folder ID, same as for provider.
  bucket_name = "" # Set a unique bucket name.
  pg_password = "" # Set a password for the PostgreSQL admin user.

  # Specify these settings ONLY AFTER the cluster is created. Then run the "terraform apply" command again.
  # You should set up the source endpoint for the Object Storage bucket by using the GUI to obtain the endpoint ID.
  source_endpoint_id = "" # Set the source endpoint ID.
  transfer_enabled   = 0  # Set to 1 to enable the transfer.

  # The following settings are predefined. Change them only if necessary.
  network_name          = "mpg-network"        # Name of the network
  subnet_name           = "mpg-subnet-a"       # Name of the subnet
  zone_a_v4_cidr_blocks = "10.1.0.0/16"        # CIDR block for the subnet
  sa-name               = "storage-editor"     # Name of the service account
  security_group_name   = "mpg-security-group" # Name of the security group
  mpg_cluster_name      = "mpg-cluster"        # Name of the PostgreSQL cluster
  database_name         = "db1"                # Name of the PostgreSQL database
  pg_username           = "user1"              # Name of the PostgreSQL admin user
  target_endpoint_name  = "mpg-target"         # Name of the target endpoint for the PostgreSQL cluster
  transfer_name         = "s3-mpg-transfer"    # Name of the transfer from the Object Storage bucket to the Managed Service for PostgreSQL cluster
}

# Network infrastructure for the Managed Service for PostgreSQL cluster

resource "yandex_vpc_network" "network" {
  description = "Network for the Managed Service for PostgreSQL cluster"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [local.zone_a_v4_cidr_blocks]
}

resource "yandex_vpc_security_group" "security_group" {
  description = "Security group for the Managed Service for PostgreSQL cluster"
  name        = local.security_group_name
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "Allows connections to the Managed Service for PostgreSQL cluster from the internet"
    protocol       = "TCP"
    port           = 6432
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allows all outgoing traffic"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Infrastructure for the Object Storage bucket

# Create a service account.
resource "yandex_iam_service_account" "example-sa" {
  folder_id = local.folder_id
  name      = local.sa-name
}

# Create a static key for the service account.
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.example-sa.id
}

# Grant a role to the service account. The role allows for performing any operations with buckets and objects.
resource "yandex_resourcemanager_folder_iam_binding" "s3-admin" {
  folder_id = local.folder_id
  role      = "storage.editor"

  members = [
    "serviceAccount:${yandex_iam_service_account.example-sa.id}",
  ]
}

# Create a Lockbox secret.
resource "yandex_lockbox_secret" "sa_key_secret" {
  name        = "sa_key_secret"
  description = "Contains a static key pair to create an endpoint"
  folder_id   = local.folder_id
}

# Create a version of Lockbox secret with the static key pair.
resource "yandex_lockbox_secret_version" "first_version" {
  secret_id = yandex_lockbox_secret.sa_key_secret.id
  entries {
    key        = "access_key"
    text_value = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  }
  entries {
    key        = "secret_key"
    text_value = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  }
}

# Create the Yandex Object Storage bucket.
resource "yandex_storage_bucket" "example-bucket" {
  bucket     = local.bucket_name
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
}

resource "yandex_mdb_postgresql_user" "pg-user" {
  cluster_id = yandex_mdb_postgresql_cluster.mpg-cluster.id
  name       = local.pg_username
  password   = local.pg_password
}

resource "yandex_mdb_postgresql_database" "mpg-db" {
  cluster_id = yandex_mdb_postgresql_cluster.mpg-cluster.id
  name       = local.database_name
  owner      = yandex_mdb_postgresql_user.pg-user.name
  depends_on = [
    yandex_mdb_postgresql_user.pg-user
  ]
}

resource "yandex_mdb_postgresql_cluster" "mpg-cluster" {
  description        = "Managed PostgreSQL cluster"
  name               = local.mpg_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_security_group.security_group.id]

  config {
    version = 15
    resources {
      resource_preset_id = "s2.micro"
      disk_type_id       = "network-ssd"
      disk_size          = "20"
    }
  }

  host {
    zone             = "ru-central1-a"
    subnet_id        = yandex_vpc_subnet.subnet-a.id
    assign_public_ip = true
  }
}

# Data Transfer infrastructure

resource "yandex_datatransfer_endpoint" "mpg_target" {
  description = "Target endpoint for PostgreSQL cluster"
  name        = local.target_endpoint_name
  settings {
    postgres_target {
      connection {
        mdb_cluster_id = yandex_mdb_postgresql_cluster.mpg-cluster.id
      }
      database = yandex_mdb_postgresql_database.mpg-db.name
      user     = yandex_mdb_postgresql_user.pg-user.name
      password {
        raw = local.pg_password
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "objstorage-mpg-transfer" {
  count       = local.transfer_enabled
  description = "Transfer from the Object Storage bucket to the Managed Service for PostgreSQL cluster"
  name        = local.transfer_name
  source_id   = local.source_endpoint_id
  target_id   = yandex_datatransfer_endpoint.mpg_target.id
  type        = "SNAPSHOT_ONLY" # Copy data
}
