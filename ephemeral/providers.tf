provider "aws" {
  region = var.region

  # Applied to every taggable resource — makes cost attribution
  # and orphan cleanup possible later.
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
