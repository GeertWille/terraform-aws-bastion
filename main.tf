resource "aws_kms_key" "key" {
  enable_key_rotation = var.kms_enable_key_rotation
  tags                = merge(var.tags)
}

resource "aws_kms_alias" "alias" {
  name          = "alias/${replace(var.bucket_name, ".", "_")}"
  target_key_id = aws_kms_key.key.arn
}

data "aws_kms_alias" "kms-ebs" {
  name = "alias/aws/ebs"
}

resource "aws_s3_object" "bucket_public_keys_readme" {
  bucket     = aws_s3_bucket.bucket.id
  key        = "public-keys/README.txt"
  content    = "Drop here the ssh public keys of the instances you want to control"
  kms_key_id = aws_kms_key.key.arn
}

resource "aws_security_group" "lb_security_group" {
  count       = var.lb_with_security_group ? 1 : 0
  description = "Enable SSH access to the bastion LB from external via SSH port"
  name        = "${local.name_prefix}-lb"
  vpc_id      = var.vpc_id

  tags = merge(var.tags)
}

resource "aws_security_group_rule" "ingress_lb" {
  count            = var.lb_with_security_group ? 1 : 0
  description      = "Incoming traffic to bastion lb"
  type             = "ingress"
  from_port        = var.public_ssh_port
  to_port          = var.public_ssh_port
  protocol         = "TCP"
  cidr_blocks      = var.cidrs
  ipv6_cidr_blocks = var.ipv6_cidrs

  security_group_id = aws_security_group.lb_security_group[count.index].id
}

resource "aws_security_group_rule" "egress_lb" {
  count                    = var.lb_with_security_group ? 1 : 0
  description              = "Egress traffic from the bastion lb to the bastion host"
  type                     = "egress"
  from_port                = var.public_ssh_port
  to_port                  = var.public_ssh_port
  protocol                 = "TCP"
  source_security_group_id = aws_security_group.bastion_host_security_group[count.index].id

  security_group_id = aws_security_group.lb_security_group[count.index].id
}

resource "aws_security_group" "bastion_host_security_group" {
  count       = var.bastion_security_group_id == "" ? 1 : 0
  description = "Enable SSH access to the bastion host from external via SSH port"
  name        = "${local.name_prefix}-host"
  vpc_id      = var.vpc_id

  tags = merge(var.tags)
}

resource "aws_security_group_rule" "ingress_bastion" {
  count            = var.bastion_security_group_id == "" && var.create_elb && !var.lb_with_security_group ? 1 : 0
  description      = "Incoming traffic to bastion"
  type             = "ingress"
  from_port        = var.public_ssh_port
  to_port          = var.public_ssh_port
  protocol         = "TCP"
  cidr_blocks      = local.ipv4_cidr_block
  ipv6_cidr_blocks = local.ipv6_cidr_block

  security_group_id = local.security_group
}

resource "aws_security_group_rule" "ingress_bastion_via_lb_sg" {
  count                    = var.bastion_security_group_id == "" && var.create_elb && var.lb_with_security_group ? 1 : 0
  description              = "Incoming traffic to bastion"
  type                     = "ingress"
  from_port                = var.public_ssh_port
  to_port                  = var.public_ssh_port
  protocol                 = "TCP"
  source_security_group_id = aws_security_group.lb_security_group[count.index].id

  security_group_id = local.security_group
}

resource "aws_vpc_security_group_egress_rule" "bastion_egress_cidr" {
  for_each          = var.bastion_egress_rules_cidr
  security_group_id = local.security_group

  description = each.key
  cidr_ipv4   = each.value.cidr_ipv4
  from_port   = each.value.from_port
  ip_protocol = each.value.ip_protocol
  to_port     = each.value.to_port
}

resource "aws_vpc_security_group_egress_rule" "bastion_egress_sg" {
  for_each          = var.bastion_egress_rules_sg
  security_group_id = local.security_group

  description                  = each.key
  referenced_security_group_id = each.value.referenced_security_group_id
  from_port                    = each.value.from_port
  ip_protocol                  = each.value.ip_protocol
  to_port                      = each.value.to_port
}

resource "aws_vpc_security_group_egress_rule" "bastion_egress_prefix_list" {
  for_each          = var.bastion_egress_rules_prefix_list
  security_group_id = local.security_group

  description    = each.key
  prefix_list_id = each.value.prefix_list_id
  from_port      = each.value.from_port
  ip_protocol    = each.value.ip_protocol
  to_port        = each.value.to_port
}

resource "aws_security_group" "private_instances_security_group" {
  description = "Enable SSH access to the Private instances from the bastion via SSH port"
  name        = "${local.name_prefix}-priv-instances"
  vpc_id      = var.vpc_id

  tags = merge(var.tags)
}

resource "aws_security_group_rule" "ingress_instances" {
  description = "Incoming traffic from bastion"
  type        = "ingress"
  from_port   = var.private_ssh_port
  to_port     = var.private_ssh_port
  protocol    = "TCP"

  source_security_group_id = local.security_group

  security_group_id = aws_security_group.private_instances_security_group.id
}

data "aws_iam_policy_document" "assume_policy_document" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion_host_role" {
  name                 = var.bastion_iam_role_name
  path                 = "/"
  assume_role_policy   = data.aws_iam_policy_document.assume_policy_document.json
  permissions_boundary = var.bastion_iam_permissions_boundary
}

data "aws_iam_policy_document" "bastion_host_policy_document" {

  statement {
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl"
    ]
    resources = ["${aws_s3_bucket.bucket.arn}/logs/*"]
  }

  statement {
    actions = [
      "s3:GetObject"
    ]
    resources = ["${aws_s3_bucket.bucket.arn}/public-keys/*"]
  }

  statement {
    actions = [
      "s3:ListBucket"
    ]
    resources = [
    aws_s3_bucket.bucket.arn]

    condition {
      test     = "ForAnyValue:StringEquals"
      values   = ["public-keys/"]
      variable = "s3:prefix"
    }
  }

  statement {
    actions = [

      "kms:Encrypt",
      "kms:Decrypt"
    ]
    resources = [aws_kms_key.key.arn]
  }

}

resource "aws_iam_policy" "bastion_host_policy" {
  name   = var.bastion_iam_policy_name
  policy = data.aws_iam_policy_document.bastion_host_policy_document.json
}

resource "aws_iam_role_policy_attachment" "bastion_host" {
  policy_arn = aws_iam_policy.bastion_host_policy.arn
  role       = aws_iam_role.bastion_host_role.name
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = var.bastion_iam_role_additional_policies

  policy_arn = each.value
  role       = aws_iam_role.bastion_host_role.name
}

resource "aws_route53_record" "bastion_record_name" {
  name    = var.bastion_record_name
  zone_id = var.hosted_zone_id
  type    = "A"
  count   = var.create_dns_record && var.create_elb ? 1 : 0

  alias {
    evaluate_target_health = true
    name                   = aws_lb.bastion_lb[0].dns_name
    zone_id                = aws_lb.bastion_lb[0].zone_id
  }
}

resource "aws_lb" "bastion_lb" {
  count = var.create_elb ? 1 : 0

  internal = var.is_lb_private
  name     = "${local.name_prefix}-lb"

  subnets         = var.elb_subnets
  security_groups = var.lb_with_security_group ? [for id in aws_security_group.lb_security_group[*].id : id] : null

  load_balancer_type = "network"
  tags               = merge(var.tags)

  lifecycle {
    precondition {
      condition     = !var.create_elb || (length(var.elb_subnets) > 0 && var.is_lb_private != null)
      error_message = "elb_subnets and is_lb_private must be set when creating a load balancer"
    }
  }
}

resource "aws_lb_target_group" "bastion_lb_target_group" {
  count = var.create_elb ? 1 : 0

  name        = !var.use_target_group_name_prefix ? "${local.name_prefix}-lb-target" : null
  name_prefix = var.use_target_group_name_prefix ? local.name_prefix_short : null

  port        = var.public_ssh_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    port     = "traffic-port"
    protocol = "TCP"
  }

  tags = merge(var.tags)
}

resource "aws_lb_listener" "bastion_lb_listener_22" {
  count = var.create_elb ? 1 : 0

  default_action {
    target_group_arn = aws_lb_target_group.bastion_lb_target_group[0].arn
    type             = "forward"
  }

  load_balancer_arn = aws_lb.bastion_lb[0].arn
  port              = var.public_ssh_port
  protocol          = "TCP"
}

resource "aws_iam_instance_profile" "bastion_host_profile" {
  role = aws_iam_role.bastion_host_role.name
  path = "/"
}

resource "aws_launch_template" "bastion_launch_template" {
  name_prefix            = local.name_prefix
  image_id               = var.bastion_ami != "" ? var.bastion_ami : data.aws_ami.amazon-linux-2.id
  instance_type          = var.instance_type
  update_default_version = true
  monitoring {
    enabled = true
  }
  network_interfaces {
    associate_public_ip_address = var.associate_public_ip_address
    security_groups             = concat([local.security_group], var.bastion_additional_security_groups)
    delete_on_termination       = true
  }
  iam_instance_profile {
    name = aws_iam_instance_profile.bastion_host_profile.name
  }
  key_name = var.bastion_host_key_pair

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    aws_region              = var.region
    bucket_name             = var.bucket_name
    extra_user_data_content = var.extra_user_data_content
    allow_ssh_commands      = lower(var.allow_ssh_commands)
    public_ssh_port         = var.public_ssh_port
    sync_logs_cron_job      = var.enable_logs_s3_sync ? "*/5 * * * * /usr/bin/bastion/sync_s3" : ""
  }))

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.disk_size
      volume_type           = "gp2"
      delete_on_termination = true
      encrypted             = var.disk_encrypt
      kms_key_id            = var.disk_encrypt ? data.aws_kms_alias.kms-ebs.target_key_arn : ""
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(tomap({ "Name" = var.bastion_launch_template_name }), merge(var.tags))
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(tomap({ "Name" = var.bastion_launch_template_name }), merge(var.tags))
  }

  metadata_options {
    http_endpoint               = var.http_endpoint ? "enabled" : "disabled"
    http_tokens                 = var.use_imds_v2 ? "required" : "optional"
    http_put_response_hop_limit = var.http_put_response_hop_limit
    http_protocol_ipv6          = var.enable_http_protocol_ipv6 ? "enabled" : "disabled"
    instance_metadata_tags      = var.enable_instance_metadata_tags ? "enabled" : "disabled"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "bastion_auto_scaling_group" {
  name_prefix = var.bastion_autoscaling_group_name
  launch_template {
    id      = aws_launch_template.bastion_launch_template.id
    version = aws_launch_template.bastion_launch_template.latest_version
  }
  max_size         = var.bastion_instance_count
  min_size         = var.bastion_instance_count
  desired_capacity = var.bastion_instance_count

  vpc_zone_identifier = var.auto_scaling_group_subnets

  default_cooldown          = 180
  health_check_grace_period = 180
  health_check_type         = "EC2"

  target_group_arns = var.create_elb ? [
    aws_lb_target_group.bastion_lb_target_group[0].arn,
  ] : null

  termination_policies = [
    "OldestLaunchConfiguration",
  ]

  dynamic "tag" {
    for_each = var.tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  tag {
    key                 = "Name"
    value               = var.bastion_autoscaling_group_name
    propagate_at_launch = true
  }

  instance_refresh {
    strategy = "Rolling"
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_s3_bucket.bucket]
}
