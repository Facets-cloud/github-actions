resource "aws_ecs_service" "this" {
  name            = "${var.environment.unique_name}-${var.instance_name}"
  cluster         = var.inputs["ecs_cluster_details"].attributes["cluster_arn"]
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets = var.inputs["aws_vpc_details"].attributes["subnet_ids"]
  }
}

resource "aws_ecs_task_definition" "this" {
  family = "${var.environment.unique_name}-${var.instance_name}"
  container_definitions = jsonencode([{
    name      = "app"
    image     = var.instance.spec.image
    cpu       = 256
    memory    = 512
    essential = true
  }])
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
}

