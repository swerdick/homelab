# Harbor base URL — non-sensitive (it's the public internal hostname). The
# admin credentials come via HARBOR_USERNAME + HARBOR_PASSWORD env vars
# from the justfile `tf-harbor` recipe (SOPS), so no TF variable for those.
variable "harbor_url" {
  description = "Harbor base URL, no trailing path (e.g. https://harbor.vingilot.internal)."
  type        = string
  default     = "https://harbor.vingilot.internal"
}
