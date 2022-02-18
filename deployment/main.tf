resource "aws_s3_bucket" "codepipeline_bucket" {
  bucket = join("-", [lower(var.env_name), "bucket1989"])
}

resource "aws_iam_role" "codepipeline_role" {
  name = join("-", [var.env_name, "codepipeline"])

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codepipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline_policy"
  role = aws_iam_role.codepipeline_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:PutObject"
      ],
      "Resource": [
        "${aws_s3_bucket.codepipeline_bucket.arn}",
        "${aws_s3_bucket.codepipeline_bucket.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild",
        "codedeploy:*",
        "ecs:*"
      ],
      "Resource": "*"
    },
   {
            "Action": [
                "codecommit:CancelUploadArchive",
                "codecommit:GetBranch",
                "codecommit:GetCommit",
                "codecommit:GetRepository",
                "codecommit:GetUploadArchiveStatus",
                "codecommit:UploadArchive"
            ],
            "Resource": "*",
            "Effect": "Allow"
        },
{
            "Action": [
                "iam:PassRole"
            ],
            "Resource": "*",
            "Effect": "Allow",
            "Condition": {
                "StringEqualsIfExists": {
                    "iam:PassedToService": [
                        "ecs-tasks.amazonaws.com"
                    ]
                }
            }
        }
  ]
}
EOF
}


resource "aws_codepipeline" "ecs_pipeline" {
  name     = join("-", [var.env_name, "pipeline"])
  role_arn = aws_iam_role.codepipeline_role.arn
  tags = {
    Environment = var.env_name
  }
  artifact_store {
    location = aws_s3_bucket.codepipeline_bucket.bucket
    type     = "S3"
  }
  stage {
    name = "Source"
    action {
      name             = "FetchCode"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      run_order        = 1
      output_artifacts = ["SourceArtifact"]
      configuration = {
        RepositoryName       = var.repo_name
        BranchName           = "master"
        PollForSourceChanges = true
      }
    }
  }
  stage {
    name = "Build"
    action {
      category = "Build"
      configuration = {
        "ProjectName" = join("-", [var.env_name, "build"])
      }
      input_artifacts = [
        "SourceArtifact",
      ]
      name = "Build"
      output_artifacts = [
        "ImageArtifact",
        "DefinitionArtifact"
      ]
      owner     = "AWS"
      provider  = "CodeBuild"
      run_order = 1
      version   = "1"
    }
  }
  stage {
    name = "Deploy"
    action {
      name      = "Deploy"
      category  = "Deploy"
      owner     = "AWS"
      provider  = "CodeDeployToECS"
      version   = "1"
      run_order = 1
      input_artifacts = [
        "ImageArtifact",
        "DefinitionArtifact",
      ]
      configuration = {
        ApplicationName                = aws_codedeploy_app.deployment.name
        DeploymentGroupName            = aws_codedeploy_deployment_group.ecs.deployment_group_name
        TaskDefinitionTemplateArtifact = "DefinitionArtifact"
        TaskDefinitionTemplatePath     = "taskdef.json"
        AppSpecTemplateArtifact        = "DefinitionArtifact"
        AppSpecTemplatePath            = "appspec.yaml"
        Image1ArtifactName             = "ImageArtifact"
        Image1ContainerName            = "IMAGE1_NAME"
      }
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name = join("-", [var.env_name, "codebuild"])

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codebuild" {
  role = aws_iam_role.codebuild.name

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:*",
        "ecr:*"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
POLICY
}



resource "aws_codebuild_project" "ecs_build" {
  badge_enabled  = false
  build_timeout  = 60
  name           = join("-", [var.env_name, "build"])
  queued_timeout = 480
  service_role   = aws_iam_role.codebuild.arn
  artifacts {
    encryption_disabled    = false
    name                   = "ecs-build-${var.env_name}"
    override_artifact_name = true
    packaging              = "NONE"
    type                   = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:2.0"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true
    type                        = "LINUX_CONTAINER"
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }

    s3_logs {
      encryption_disabled = false
      status              = "DISABLED"
    }
  }

  source {
    git_clone_depth     = 0
    insecure_ssl        = false
    report_build_status = false
    type                = "CODEPIPELINE"
  }
}



resource "aws_codedeploy_app" "deployment" {
  compute_platform = "ECS"
  name             = join("-", [var.env_name, "deployment"])
}

resource "aws_iam_role" "deployment" {
  name               = join("-", [var.env_name, "deployment-role"])
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "codedeploy.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "AWSCodeDeployRole" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
  role       = aws_iam_role.deployment.name
}

resource "aws_iam_role_policy" "codedeploy" {
  role = aws_iam_role.deployment.name

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecs:*",
        "elasticloadbalancing:*"
      ],
      "Resource": [
        "*"
      ]
    },
{
            "Action": [
                "iam:PassRole"
            ],
            "Resource": "*",
            "Effect": "Allow",
            "Condition": {
                "StringEqualsIfExists": {
                    "iam:PassedToService": [
                        "ecs-tasks.amazonaws.com"
                    ]
                }
            }
        }
  ]
}
POLICY
}


resource "aws_codedeploy_deployment_group" "ecs" {
  app_name               = aws_codedeploy_app.deployment.name
  deployment_config_name = var.deployment_config_name
  deployment_group_name  = "deployment-group-${var.ecs_service_name}"
  service_role_arn       = aws_iam_role.deployment.arn
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = var.termination_wait_time_in_minutes
    }
  }
  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }
  ecs_service {
    cluster_name = var.ecs_cluster_name
    service_name = var.ecs_service_name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [
        var.main_listener]
      }

      target_group {
        name = var.main_target_group
      }

      target_group {
        name = var.test_target_group
      }

      test_traffic_route {
        listener_arns = [
        var.test_listener]
      }
    }
  }

}

