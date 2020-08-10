#create ecs security group
resource "aws_security_group" "ecs-access-security-group" {
  name   = "ecs-access-security-group"
  vpc_id = var.vpc_id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    #  security_groups =  output SG from alb????
    description = "inbound allowed only via Application load balancer"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project-name}-ecs-access-security-group"
  }
}

resource "aws_iam_role" "ecs-instance-role" {
  name               = "ecs-instance-role"
  path               = "/"
  assume_role_policy = <<EOF
{
"Version": "2012-10-17",
"Statement": [
  {
    "Effect": "Allow",
    "Principal": {
      "Service": "ec2.amazonaws.com"
    },
    "Action": "sts:AssumeRole"
  }
]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ecs-instance-role-attachment" {
  role       = aws_iam_role.ecs-instance-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy" "this" {
  name = "${var.project-name}-iam_role_policy"
  role = aws_iam_role.ecs-instance-role.id

  policy = <<-EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
          "ec2:DescribeTags",
          "ecs:CreateCluster",
          "ecs:DeregisterContainerInstance",
          "ecs:DiscoverPollEndpoint",
          "ecs:Poll",
          "ecs:RegisterContainerInstance",
          "ecs:StartTelemetrySession",
          "ecs:UpdateContainerInstancesState",
          "ecs:Submit*",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
  EOF
}

resource "aws_iam_instance_profile" "ecs-instance-profile" {
  name = "ecs-instance-profile"
  role = aws_iam_role.ecs-instance-role.id
}


# create launch configuration
resource "aws_launch_configuration" "ecs-launch-configuration" {
  name                 = "${var.project-name}-ecs-launch-configuration"
  image_id             = var.image_id
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.ecs-instance-profile.arn
  lifecycle {
    create_before_destroy = true
  }
  security_groups             = [aws_security_group.ecs-access-security-group.id]
  associate_public_ip_address = "true"
  user_data                   = <<EOF
                                  #!/bin/bash
                                  echo ECS_CLUSTER=${aws_ecs_cluster.ecs-cluster.name} >> /etc/ecs/ecs.config
                                  EOF
}


# create auto scaling group
resource "aws_autoscaling_group" "ecs-autoscaling-group" {
  name                      = "ecs-autoscaling-group"
  max_size                  = var.max-size
  min_size                  = var.min-size
  wait_for_capacity_timeout = 0
  vpc_zone_identifier       = [var.subnet-public-1, var.subnet-public-2]
  launch_configuration      = aws_launch_configuration.ecs-launch-configuration.id
  health_check_type         = "EC2"
  target_group_arns         = [var.target_group_arn]
  health_check_grace_period = 0
  default_cooldown          = 300
  termination_policies      = ["OldestInstance"]
  tag {
    key                 = "Name"
    value               = "${var.project-name}-ECS"
    propagate_at_launch = true
  }
}



#create auto scaling policy
resource "aws_autoscaling_policy" "autoscaling-policy" {
  name                      = "${var.project-name}-asg-policy"
  autoscaling_group_name    = aws_autoscaling_group.ecs-autoscaling-group.name
  adjustment_type           = "ChangeInCapacity"
  policy_type               = "TargetTrackingScaling"
  estimated_instance_warmup = "120"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 40
  }
}


# create ECS cluster
resource "aws_ecs_cluster" "ecs-cluster" {
  name = "${var.project-name}-ecs-cluster"
}


locals {

  mount_points = length(var.mount_points) > 0 ? [
    for mount_point in var.mount_points : {
      containerPath = lookup(mount_point, "containerPath")
      sourceVolume  = lookup(mount_point, "sourceVolume")
      readOnly      = tobool(lookup(mount_point, "readOnly", false))
    }
  ] : var.mount_points

  container_definition = {
    name                   = var.container_name
    image                  = var.container_image
    essential              = var.essential
    readonlyRootFilesystem = var.readonly_root_filesystem
    secrets                = var.secrets
    mountPoints            = local.mount_points
    portMappings           = var.port_mappings
    memory                 = var.container_memory
    cpu                    = var.container_cpu
  }

  container_definition_without_null = {
    for k, v in local.container_definition :
    k => v
    if v != null
  }
  json_map = jsonencode(merge(local.container_definition_without_null, var.container_definition))
}

# ECS Task definition
resource "aws_ecs_task_definition" "this" {
  family                = "${var.project-name}-task-definition"
  container_definitions = jsonencode([local.container_definition_without_null])
  memory                = var.container_memory

  volume {
    name = var.volume_name

    efs_volume_configuration {
      file_system_id          = lookup(var.efs_volume_configuration, "file_system_id", null)
      root_directory          = lookup(var.efs_volume_configuration, "root_directory", null)
      transit_encryption      = lookup(var.efs_volume_configuration, "transit_encryption", null)
      transit_encryption_port = lookup(var.efs_volume_configuration, "transit_encryption_port", null)
    }
  }

  tags = merge(var.common_tags, {
    Name = "${var.project-name}-ecs-task-definition"
  })
}

# ECS service
resource "aws_ecs_service" "this" {
  name            = "${var.project-name}-ecs_service"
  cluster         = aws_ecs_cluster.ecs-cluster.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  iam_role        = aws_iam_role.ecs-instance-role.arn

  depends_on = [aws_iam_role_policy.this]

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = var.container_name
    container_port   = var.container_port
  }
  network_configuration {
    security_groups = [aws_security_group.ecs-access-security-group.id]
    subnets         = [var.subnet-public-1, var.subnet-public-2]
  }
  tags = merge(var.common_tags, {
    Name = "${var.project-name}-ecs_service"
  })
}