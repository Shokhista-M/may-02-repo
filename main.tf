terraform {
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "029DA-DevOps24"

    workspaces {
      name = "my_second_workspace"
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }

}
provider "aws" {
  region = "us-east-1"
}
variable "prefix" {
    type = string
    description = "Prefix for all resources"
    default = "Apr-28"
}
 resource "aws_vpc" "main" {
    cidr_block = "10.0.0.0/16"
    enable_dns_support = true
    enable_dns_hostnames = true
    tags = {
      Name = "${var.prefix}-vpc"
    }   
 }
 resource "aws_subnet" "public" {
    vpc_id            = aws_vpc.main.id
    cidr_block        = "10.0.1.0/24"
    availability_zone = "us-east-1a"
    tags = {
      Name = "${var.prefix}-public-subnet"
    }
 }  
 resource "aws_subnet" "public_2" {
    vpc_id            = aws_vpc.main.id
    cidr_block        = "10.0.2.0/24"
    availability_zone = "us-east-1b"
    tags = {
      Name = "${var.prefix}-public-subnet_2"
    }
 }  
 resource "aws_internet_gateway" "igw" {
    vpc_id = aws_vpc.main.id
    tags = {
      Name = "${var.prefix}-igw"
    }
 }
 resource "aws_route_table" "public" {
    vpc_id = aws_vpc.main.id
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.igw.id
    }
    tags = {
      Name = "${var.prefix}-public-route"
    }
 }
 
 resource "aws_route_table_association" "public" {
    subnet_id      = aws_subnet.public.id
    route_table_id = aws_route_table.public.id
 }    

 module "sg"{
  source  = "app.terraform.io/029DA-DevOps24/security-030/aws"
  version = "2.0.0" 
  security_group = {
    "web-sg" = {
      description = "Security group for web server"
      vpc_id      = aws_vpc.main.id
      ingress_rules = [
        {
          description = "HTTP"
          from_port   = 80
          to_port     = 80
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
          priority    = 200
       },
        {
          description = "HTTPS"
          from_port   = 443
          to_port     = 443
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
          priority    = 202
          },
         
      ]
      egress_rules = [
        {
          description = "Allow all outbound traffic"
          from_port   = 0
          to_port     = 0
          protocol    = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      ]   
  }  
}
 }
 module "alb-sg"{
  source  = "app.terraform.io/029DA-DevOps24/security-030/aws"
  version = "2.0.0" 
  security_group = {
    "alb-sg" = {
      description = "Security group for application load balancer server"
      vpc_id      = aws_vpc.main.id
      ingress_rules = [
        {
          description = "HTTP"
          from_port   = 80
          to_port     = 80
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
          priority    = 200
       },
        {
          description = "HTTPS"
          from_port   = 443
          to_port     = 443
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
          priority    = 202
          },
     
      ]
      egress_rules = [
        {
          description = "Allow all outbound traffic"
          from_port   = 0
          to_port     = 0
          protocol    = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      ]   
  }  
}
 }

data "aws_ami" "amzn-linux-2023-ami" {
    most_recent = true
    owners      = ["amazon"]
    
    filter {
        name   = "name"
        values = ["amzn2-ami-hvm-*-x86_64-gp2"]
    }
}
resource "aws_key_pair" "deployer" {
    key_name   = "deployer-key"
    public_key = file("~/.ssh/id_ed25519.pub")
}
resource "aws_launch_template" "default" {
    name_prefix   = "${var.prefix}-launch-template-"
    image_id      = data.aws_ami.amzn-linux-2023-ami.id
    instance_type = "t2.micro"
    key_name      = aws_key_pair.deployer.key_name

    network_interfaces {
        associate_public_ip_address = true
        delete_on_termination       = true
        subnet_id                  = aws_subnet.public.id
        #security_groups            = [module.sg.security_group["web-sg"].id]
        security_groups = [module.sg.security_group_id["web-sg"]]   #name of output which call from module
    }
    user_data = base64encode(<<-EOF
        #!/bin/bash
        yum update -y
        yum install -y httpd
        systemctl start httpd.service
        systemctl enable httpd.service
        echo "<h1>Autoscaling lab </h1>" > /var/www/html/index.html
        EOF
    )

  tag_specifications {
    resource_type = "instance"
    tags = {
        Name = "${var.prefix}-web-instance"
    }
  }
}
resource "aws_autoscaling_group" "default" {
  
    launch_template {
        id      = aws_launch_template.default.id
        version = "$Latest"
    }
    min_size     = 1
    max_size     = 2
    desired_capacity = 1
    vpc_zone_identifier = [aws_subnet.public.id]
    tag {
        key                 = "Name"
        value               = "${var.prefix}-web-instance-asg"
        propagate_at_launch = true
    }
    target_group_arns = [aws_lb_target_group.default.arn]
}
resource "aws_lb" "default" {
    name               = "test-lb-tf"
    internal           = false
    load_balancer_type = "application"
    security_groups    = [module.alb-sg.security_group_id["alb-sg"]]
    subnets            = [aws_subnet.public.id, aws_subnet.public_2.id]
    enable_deletion_protection = false
    
}

resource "aws_lb_target_group" "default" {
    name     = "${var.prefix}-target-group"
    port     = 80
    protocol = "HTTP"
    vpc_id   = aws_vpc.main.id
    target_type = "instance"
    health_check {
        healthy_threshold   = 2
        unhealthy_threshold = 2
        timeout             = 5
        interval            = 30
        path                = "/"
        protocol            = "HTTP"
        matcher             = "200"
    }
}
resource "aws_lb_listener" "default" {
    load_balancer_arn = aws_lb.default.arn
    port              = "80"
    protocol          = "HTTP"

    default_action {
        type = "forward"
        target_group_arn = aws_lb_target_group.default.arn
    }
}
resource "aws_autoscaling_attachment" "default" {
    autoscaling_group_name = aws_autoscaling_group.default.name
    lb_target_group_arn   = aws_lb_target_group.default.arn
}
