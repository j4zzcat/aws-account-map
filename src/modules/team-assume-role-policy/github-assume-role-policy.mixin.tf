variable "trusted_github_repos" {
  type        = list(string)
  description = <<-EOT
    A list of GitHub repositories allowed to access this role.
    Format is either "orgName/repoName" or just "repoName",
    in which case "cloudposse" will be used for the "orgName".
    Wildcard ("*") is allowed for "repoName".
    EOT
  default     = []
}

variable "trusted_github_org" {
  type        = string
  description = "The GitHub organization unqualified repos are assumed to belong to. Keeps `*` from meaning all orgs and all repos."
  default     = "cloudposse"
}

variable "global_environment_name" {
  type        = string
  description = "Global environment name"
  default     = "gbl"
}

locals {
  github_oidc_enabled = length(var.trusted_github_repos) > 0
}

locals {
  trusted_github_repos_regexp = "^(?:(?P<org>[^://]*)\\/)?(?P<repo>[^://]*):?(?P<branch>[^://]*)?$"
  trusted_github_repos_sub    = [for r in var.trusted_github_repos : regex(local.trusted_github_repos_regexp, r)]

  github_repos_sub = [
    for r in local.trusted_github_repos_sub : (
      r["branch"] == "" ?
      format("repo:%s/%s:*", coalesce(r["org"], var.trusted_github_org), r["repo"]) :
      format("repo:%s/%s:ref:refs/heads/%s", coalesce(r["org"], var.trusted_github_org), r["repo"], r["branch"])
    )
  ]
}

data "aws_iam_policy_document" "github_oidc_provider_assume" {
  count = local.github_oidc_enabled ? 1 : 0

  statement {
    sid = "OidcProviderAssume"
    actions = [
      "sts:AssumeRoleWithWebIdentity",
      "sts:SetSourceIdentity",
      "sts:TagSession",
    ]

    principals {
      type = "Federated"

      identifiers = [one(module.github_oidc_provider[*].outputs.oidc_provider_arn)]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"

      values = local.github_repos_sub
    }
  }
}

module "github_oidc_provider" {
  count = local.github_oidc_enabled ? 1 : 0

  source  = "cloudposse/stack-config/yaml//modules/remote-state"
  version = "1.8.0"

  component   = var.github_oidc_provider_component_name
  environment = var.global_environment_name

  privileged = var.privileged

  ignore_errors = true

  defaults = {
    oidc_provider_arn = ""
  }

  context = module.this.context
}

output "github_assume_role_policy" {
  value       = one(data.aws_iam_policy_document.github_oidc_provider_assume[*].json)
  description = "JSON encoded string representing the \"Assume Role\" policy configured by the inputs"
}
