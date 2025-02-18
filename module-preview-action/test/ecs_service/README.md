# ECS Service Module

This module implements an ECS service on AWS using Fargate. It allows you to deploy a containerized application with a specified Docker image. The module is designed to work within the Facets framework, leveraging existing ECS cluster and VPC configurations.

## Functionality

- Deploys an ECS service using a specified Docker image.
- Integrates with existing ECS cluster and VPC configurations.
- Supports Fargate launch type for serverless container deployment.

## Configurability

- **Image**: Specify the Docker image to be used for the ECS service.
- **Cluster Details**: Requires ECS cluster details as input.
- **VPC Details**: Requires VPC details for network configuration.
