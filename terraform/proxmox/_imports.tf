# Active import blocks. Workflow:
#   1. Add `import { to = ...; id = "<node>/<vmid>" }` for the target.
#   2. `just tf plan -generate-config-out=generated.tf` writes HCL for it.
#   3. Move the generated resource into its own file (e.g. aglarond.tf),
#      then delete the import block here (and `generated.tf`).
#   4. `just tf plan` must be a clean no-op against the moved resource.
# When this file is empty (no import blocks), all in-flight imports are done.
