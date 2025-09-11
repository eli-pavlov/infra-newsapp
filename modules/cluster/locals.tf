# 1 control-plane + app_worker_count + 1 db worker
locals {
  expected_total_node_count = 1 + var.app_worker_count + 1
}