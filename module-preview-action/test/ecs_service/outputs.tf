locals {
  output_interfaces = {}
  output_attributes = {
    service_arn = aws_ecs_service.this.id
  }
}
