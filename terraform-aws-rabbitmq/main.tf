data "aws_vpc" "vpc" {
  id = var.vpc_id
}

data "aws_region" "current" {
}

locals {
  cluster_name = "rabbitmq-${var.name}"
}

resource "random_string" "admin_password" {
  length  = 32
  special = false
}

resource "random_string" "rabbit_password" {
  length  = 32
  special = false
}

data "aws_iam_policy_document" "policy_doc" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "template_file" "cloud-init" {
  template = file("${path.module}/cloud-init.yaml")

  vars = {
    sync_node_count = 3
    asg_name        = local.cluster_name
    region          = data.aws_region.current.name
    admin_password  = random_string.admin_password.result
    rabbit_password = random_string.rabbit_password.result
    message_timeout = 3 * 24 * 60 * 60 * 1000 # 3 days
  }
}

resource "aws_iam_role" "role" {
  name               = local.cluster_name
  assume_role_policy = data.aws_iam_policy_document.policy_doc.json
}

resource "aws_iam_role_policy" "policy" {
  name = local.cluster_name
  role = aws_iam_role.role.id

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "autoscaling:DescribeAutoScalingInstances",
                "ec2:DescribeInstances"
            ],
            "Resource": [
                "*"
            ]
        }
    ]
}
EOF

}

resource "aws_iam_instance_profile" "profile" {
  name_prefix = local.cluster_name
  role        = aws_iam_role.role.name
}

resource "aws_security_group" "rabbitmq_elb" {
  name        = "rabbitmq_elb-${var.name}"
  vpc_id      = var.vpc_id
  description = "Security Group for the rabbitmq elb"

  ingress {
    protocol = "tcp"
    from_port = "5672"
    to_port = "5672"
    cidr_blocks = "0.0.0.0/0"
  }

  ingress {
    protocol = "tcp"
    from_port = "80"
    to_port = "80"
    cidr_blocks = "0.0.0.0/0"
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rabbitmq ${var.name} ELB"
  }
}

resource "aws_security_group" "rabbitmq_nodes" {
  name        = "${local.cluster_name}-nodes"
  vpc_id      = var.vpc_id
  description = "Security Group for the rabbitmq nodes"

  ingress {
    protocol  = -1
    from_port = 0
    to_port   = 0
    self      = true
  }

  ingress {
    protocol        = "tcp"
    from_port       = 5672
    to_port         = 5672
    security_groups = [aws_security_group.rabbitmq_elb.id]
  }

  ingress {
    protocol        = "tcp"
    from_port       = 15672
    to_port         = 15672
    security_groups = [aws_security_group.rabbitmq_elb.id]
  }

  egress {
    protocol  = "-1"
    from_port = 0
    to_port   = 0

    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }

  tags = {
    Name = "rabbitmq ${var.name} nodes"
  }
}

resource "aws_launch_configuration" "rabbitmq" {
  name                 = local.cluster_name
  image_id             = var.ami_id
  instance_type        = var.instance_type
  key_name             = var.ssh_key_name
  security_groups      = concat([aws_security_group.rabbitmq_nodes.id], var.nodes_additional_security_group_ids)
  iam_instance_profile = aws_iam_instance_profile.profile.id
  user_data            = data.template_file.cloud-init.rendered

  root_block_device {
    volume_type           = var.instance_volume_type
    volume_size           = var.instance_volume_size
    iops                  = var.instance_volume_iops
    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "rabbitmq" {
  name                      = local.cluster_name
  min_size                  = var.min_size
  desired_capacity          = var.desired_size
  max_size                  = var.max_size
  health_check_grace_period = 300
  health_check_type         = "ELB"
  force_delete              = true
  launch_configuration      = aws_launch_configuration.rabbitmq.name
  target_group_arns         = [aws_lb_target_group.ui.arn, aws_lb_target_group.backend.arn]
  vpc_zone_identifier       = var.subnet_ids

  tag {
    key                 = "Name"
    value               = local.cluster_name
    propagate_at_launch = true
  }
}

resource "aws_lb_target_group" "backend" {
  name = "${local.cluster_name}-tg"
  port = "5672"
  protocol = "tcp"
  vpc_id = var.vpc_id
  deregistration_delay = "300"
  target_type = "instance"
  health_check {
    enabled = true
    interval = 30
    port = "5672"
    protocol = "tcp"
    unhealthy_threshold = 10
    healthy_threshold   = 2
    timeout = 3
  }
}

resource "aws_lb_target_group" "ui" {
  name = "${local.cluster_name}-tg"
  port = "15672"
  protocol = "http"
  vpc_id = var.vpc_id
  deregistration_delay = "300"
  target_type = "instance"
}


resource "aws_lb" "alb"{
  name = "${local.cluster_name}-alb"
  internal = false
  security_groups = concat([aws_security_group.rabbitmq_elb.id], var.elb_additional_security_group_ids)
  subnets = var.subnet_ids
  idle_timeout = "60"
  enable_deletion_protection = true
  ip_address_type = "ipv4"
  tags = {
    Name = local.cluster_name
  }
}

resource "aws_lb_listener" "backend"{
  load_balancer_arn = aws_lb.alb.arn
  port = "5672"
  protocol = "tcp"
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_lb_listener" "ui"{
  load_balancer_arn = aws_lb.alb.arn
  port = "80"
  protocol = "tcp"
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }
}
