terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" { region = "ap-south-1" }


resource "aws_iam_role" "app_role" {
  name = "flask_app_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "app_role_attach" {
  role       = aws_iam_role.app_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
resource "aws_iam_instance_profile" "app_profile" {
  name = "flask_app_profile"
  role = aws_iam_role.app_role.name
}


resource "aws_security_group" "app_sg" {
  name        = "flask_app_sg"
  description = "Allow Web traffic and SSH"
  ingress { from_port = 22, to_port = 22, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 80, to_port = 80, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0,  to_port = 0,  protocol = "-1",  cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "obs_sg" {
  name        = "observability_sg"
  description = "Allow Grafana UI (80) and Loki log ingestion (3100)"
  ingress { from_port = 22,   to_port = 22,   protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 80,   to_port = 80,   protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 3100, to_port = 3100, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0,    to_port = 0,    protocol = "-1",  cidr_blocks = ["0.0.0.0/0"] }
}


data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter { name = "name", values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"] }
}

resource "aws_instance" "app_server" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = "t3.small" 
  iam_instance_profile = aws_iam_instance_profile.app_profile.name
  security_groups      = [aws_security_group.app_sg.name]
  user_data            = file("user_data_app.sh") 
  tags = { Name = "Flask-App-Server" }
}

resource "aws_instance" "obs_server" {
  ami             = data.aws_ami.ubuntu.id
  instance_type   = "t3.small"
  security_groups = [aws_security_group.obs_sg.name]
  user_data       = file("user_data_obs.sh")
  tags = { Name = "Grafana-Loki-Server" }
}


resource "aws_cloudwatch_log_group" "flask_alerts" {
  name              = "flask-critical-alerts"
  retention_in_days = 14
}

resource "aws_sns_topic" "flask_alerts_topic" {
  name = "FlaskAppAlerts"
}


resource "aws_cloudwatch_log_metric_filter" "price_drop_filter" {
  name           = "PriceDropFilter"
  pattern        = "{ $.message = \"CRITICAL_PRICE_DROP\" }"
  log_group_name = aws_cloudwatch_log_group.flask_alerts.name

  metric_transformation {
    name      = "PriceDropCount"
    namespace = "FlaskMonitoring"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "price_drop_alarm" {
  alarm_name          = "Critical-Price-Drop-Alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.price_drop_filter.metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.price_drop_filter.metric_transformation[0].namespace
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.flask_alerts_topic.arn]
}


resource "aws_cloudwatch_log_metric_filter" "price_rise_filter" {
  name           = "PriceRiseFilter"
  pattern        = "{ $.message = \"CRITICAL_PRICE_RISE\" }"
  log_group_name = aws_cloudwatch_log_group.flask_alerts.name

  metric_transformation {
    name      = "PriceRiseCount"
    namespace = "FlaskMonitoring"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "price_rise_alarm" {
  alarm_name          = "Critical-Price-Rise-Alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.price_rise_filter.metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.price_rise_filter.metric_transformation[0].namespace
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.flask_alerts_topic.arn]
}


output "app_server_public_ip" { value = aws_instance.app_server.public_ip }
output "grafana_url" { value = "http://${aws_instance.obs_server.public_ip}" }
output "loki_private_ip" { value = aws_instance.obs_server.private_ip }
output "sns_topic_arn" { value = aws_sns_topic.flask_alerts_topic.arn }