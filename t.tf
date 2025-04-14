# 1. IAM roles
resource "aws_iam_role" "ecs_task_execution" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_attach" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Custom inline policy for access to SQS, S3, OpenSearch
resource "aws_iam_policy" "ecs_custom_policy" {
  name = "ecsCustomPolicy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["sqs:*", "s3:*", "es:*"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_custom_attach" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = aws_iam_policy.ecs_custom_policy.arn
}

# 2. ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "opensearch-workflow-cluster"
}

# 3. Step Function IAM Role
resource "aws_iam_role" "sfn_role" {
  name = "stepFunctionExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "states.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sfn_execution_policy" {
  role       = aws_iam_role.sfn_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSStepFunctionsFullAccess"
}

resource "aws_iam_role_policy_attachment" "sfn_ecs_invoke" {
  role       = aws_iam_role.sfn_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

# 4. ECS Task Definitions (You need to define your own docker images)
resource "aws_ecs_task_definition" "scanner" {
  family                   = "scanner-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name  = "scanner"
      image = "<your-scanner-image-url>"
      essential = true
      environment = []
    }
  ])
}

resource "aws_ecs_task_definition" "processor" {
  family                   = "processor-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name  = "processor"
      image = "<your-processor-image-url>"
      essential = true
      environment = []
    }
  ])
}

# 5. Step Function Definition
locals {
  sfn_definition = <<EOF
{
  "Comment": "Daily OpenSearch ECS Fanout Workflow",
  "StartAt": "RunScannerTask",
  "States": {
    "RunScannerTask": {
      "Type": "Task",
      "Resource": "arn:aws:states:::ecs:runTask.sync",
      "Parameters": {
        "LaunchType": "FARGATE",
        "Cluster": "${aws_ecs_cluster.main.name}",
        "TaskDefinition": "${aws_ecs_task_definition.scanner.family}",
        "NetworkConfiguration": {
          "AwsvpcConfiguration": {
            "Subnets": ["<your-subnet-id>"],
            "AssignPublicIp": "ENABLED"
          }
        }
      },
      "Next": "FanOutProcessor"
    },
    "FanOutProcessor": {
      "Type": "Map",
      "ItemsPath": "$.indexes",
      "Parameters": {
        "index_name.$": "$$.Map.Item.Value.index_name",
        "queue_url.$": "$$.Map.Item.Value.queue_url"
      },
      "Iterator": {
        "StartAt": "RunProcessorTask",
        "States": {
          "RunProcessorTask": {
            "Type": "Task",
            "Resource": "arn:aws:states:::ecs:runTask.sync",
            "Parameters": {
              "LaunchType": "FARGATE",
              "Cluster": "${aws_ecs_cluster.main.name}",
              "TaskDefinition": "${aws_ecs_task_definition.processor.family}",
              "Overrides": {
                "ContainerOverrides": [
                  {
                    "Name": "processor",
                    "Environment": [
                      {"Name": "INDEX_NAME", "Value.$": "$.index_name"},
                      {"Name": "QUEUE_URL", "Value.$": "$.queue_url"}
                    ]
                  }
                ]
              },
              "NetworkConfiguration": {
                "AwsvpcConfiguration": {
                  "Subnets": ["<your-subnet-id>"],
                  "AssignPublicIp": "ENABLED"
                }
              }
            },
            "End": true
          }
        }
      },
      "End": true
    }
  }
}
EOF
}

resource "aws_sfn_state_machine" "main" {
  name     = "opensearch-ecs-fanout"
  role_arn = aws_iam_role.sfn_role.arn
  definition = local.sfn_definition
}

# 6. Daily Trigger with EventBridge
resource "aws_cloudwatch_event_rule" "daily" {
  name                = "daily-midnight-trigger"
  schedule_expression = "cron(0 0 * * ? *)"
}

resource "aws_cloudwatch_event_target" "sfn_target" {
  rule = aws_cloudwatch_event_rule.daily.name
  arn  = aws_sfn_state_machine.main.arn
}

resource "aws_iam_role" "eventbridge_role" {
  name = "eventbridge_to_sfn_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "events.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eventbridge_to_sfn" {
  role       = aws_iam_role.eventbridge_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEventBridgeFullAccess"
}

resource "aws_cloudwatch_event_permission" "allow_sfn" {
  principal    = "events.amazonaws.com"
  statement_id = "AllowExecutionFromEventBridge"
  action       = "events:PutEvents"
  source_arn   = aws_cloudwatch_event_rule.daily.arn
}
