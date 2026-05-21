terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "ca-central-1" # Or your preferred region
}

# Create the VPC
resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "Artist-Project-VPC"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "Artist-IGW"
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "ca-central-1a"

  tags = {
    Name = "Public-Subnet"
  }
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ca-central-1a"

  tags = {
    Name = "Private-Subnet"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "Public-Route-Table"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}


# 7. Security Group (The Firewall)
resource "aws_security_group" "bastion_sg" {
  name        = "bastion-sg"
  description = "Allow SSH from my IP"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # In a real job, you'd use your specific IP here
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "Artist-Bastion-SG" }
}

# 8. # Get latest Amazon Linux 2023 AMI automatically
data "aws_ssm_parameter" "amazon_linux" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.amazon_linux.value
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]

  tags = {
    Name = "Artist-Project-Bastion"
  }
}

# 9. Unique ID generator (to ensure your bucket names are unique worldwide)
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# 10. The Raw Artwork Upload Bucket
resource "aws_s3_bucket" "raw_art_bucket" {
  bucket        = "mahum-artist-uploads-${random_id.bucket_suffix.hex}"
  force_destroy = true # Allows Terraform to delete the bucket even if it has files in it (useful for students!)
  
  tags = {
    Name = "Raw-Artwork-Inbound"
  }
}

# 11. The Portfolio/Website Bucket
resource "aws_s3_bucket" "portfolio_bucket" {
  bucket        = "mahum-artist-portfolio-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "Artist-Portfolio-Public"
  }
}

# 12. DynamoDB Table for Artwork Metadata
resource "aws_dynamodb_table" "artwork_metadata" {
  name           = "ArtworkMetadata"
  billing_mode   = "PAY_PER_REQUEST" # This is critical for keeping costs at $0 when idle
  hash_key       = "ArtworkID"       # This is the primary key (like a tracking number)

  attribute {
    name = "ArtworkID"
    type = "S" # 'S' stands for String
  }

  tags = {
    Name = "Artist-Metadata-Table"
  }
}


# 13. Package the Python code into a ZIP file
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/process_art.py" # Removed the "../"
  output_path = "${path.module}/lambda/process_art.zip" # Removed the "../"
}

# 14. IAM Role for Lambda (The "ID Badge" for the function)
resource "aws_iam_role" "lambda_role" {
  name = "artist_ai_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# 15. IAM Policy (The "Keys" to the specific services)
resource "aws_iam_role_policy" "lambda_permissions" {
  name = "artist_ai_permissions"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["s3:GetObject", "s3:PutObject"],
        Effect = "Allow",
        Resource = "${aws_s3_bucket.raw_art_bucket.arn}/*"
      },
      {
        Action = ["rekognition:DetectLabels"],
        Effect = "Allow",
        Resource = "*"
      },
      {
        Action = ["bedrock:InvokeModel"],
        Effect = "Allow",
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
      },
      {
        Action = ["dynamodb:PutItem"],
        Effect = "Allow",
        Resource = aws_dynamodb_table.artwork_metadata.arn
      },
      {
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Effect = "Allow",
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# 16. The Lambda Function itself
resource "aws_lambda_function" "art_processor" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "ArtProcessorFunction"
  role             = aws_iam_role.lambda_role.arn
  handler          = "process_art.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30 # AI can take a few seconds, so we increase the timeout
}

# 17. S3 Trigger Permission (Allows S3 to call Lambda)
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.art_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw_art_bucket.arn
}

# 18. The Actual S3 Notification Trigger
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.raw_art_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.art_processor.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# 19. ZIP the "Reader" Lambda
data "archive_file" "reader_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/get_art_details.py"
  output_path = "${path.module}/lambda/get_art_details.zip"
}

# 20. The "Reader" Lambda Function
resource "aws_lambda_function" "art_reader" {
  filename         = data.archive_file.reader_lambda_zip.output_path
  function_name    = "ArtReaderFunction"
  role             = aws_iam_role.lambda_role.arn # Reusing your existing IAM role
  handler          = "get_art_details.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.reader_lambda_zip.output_base64sha256
}


# 21. API Gateway (The "Front Door")
resource "aws_apigatewayv2_api" "art_api" {
  name          = "ArtistProjectAPI"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    # We MUST add "POST" for the upload request and "PUT" for S3
    allow_methods = ["GET", "POST", "PUT", "OPTIONS"]
    # We added "Authorization" just in case you add security later
    allow_headers = ["content-type", "authorization"]
    max_age       = 300
  }
}

# 22. API Integration (Connecting API Gateway to Lambda)
resource "aws_apigatewayv2_integration" "api_lambda_integration" {
  api_id           = aws_apigatewayv2_api.art_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.art_reader.invoke_arn
}


# 23. API Route (The URL path, e.g., /art)
resource "aws_apigatewayv2_route" "api_route" {
  api_id    = aws_apigatewayv2_api.art_api.id  # <--- FIX: Point to the API, not the route
  route_key = "GET /art"
  target    = "integrations/${aws_apigatewayv2_integration.api_lambda_integration.id}"
}

# 24. API Stage (Auto-deploying the URL)
resource "aws_apigatewayv2_stage" "api_stage" {
  api_id      = aws_apigatewayv2_api.art_api.id
  name        = "$default"
  auto_deploy = true
}

# 25. Permission for API Gateway to "call" the Lambda
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.art_reader.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.art_api.execution_arn}/*/*"
}

# 26. Display the URL in the terminal
output "api_url" {
  value = "${aws_apigatewayv2_api.art_api.api_endpoint}/art"
}

# New Lambda to generate the Upload URL
resource "aws_lambda_function" "uploader_lambda" {
  filename      = "uploader.zip" # We will create this zip in the next step
  function_name = "UploadURLGenerator"
  role          = aws_iam_role.lambda_role.arn
  handler       = "get_upload_url.lambda_handler"
  runtime       = "python3.11"

  environment {
    variables = {
      UPLOAD_BUCKET = aws_s3_bucket.raw_art_bucket.id
    }
  }
}

# Add a new API Route for Uploading
resource "aws_apigatewayv2_route" "upload_route" {
  api_id    = aws_apigatewayv2_api.art_api.id
  route_key = "POST /upload" # This will be the address: /upload
  target    = "integrations/${aws_apigatewayv2_integration.uploader_integration.id}"
}

resource "aws_apigatewayv2_integration" "uploader_integration" {
  api_id           = aws_apigatewayv2_api.art_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.uploader_lambda.invoke_arn
}

# Permission for API Gateway to call the new Lambda
resource "aws_lambda_permission" "api_gw_uploader" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.uploader_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.art_api.execution_arn}/*/*"
}

# Allow the browser to upload files directly to the S3 bucket
resource "aws_s3_bucket_cors_configuration" "s3_upload_cors" {
  bucket = aws_s3_bucket.raw_art_bucket.id 

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "HEAD"]
    allowed_origins = ["*"] 
    max_age_seconds = 3000
  }
}

# ==========================================
# STEP 12: FRONTEND HOSTING (S3)
# ==========================================

# 1. The Bucket for your Website Code
resource "aws_s3_bucket" "frontend_bucket" {
  # We use your unique ID to ensure the name is globally unique
  bucket = "mahum-artist-frontend-19373b71" 
}

# 2. Tell S3 this bucket is a Website
resource "aws_s3_bucket_website_configuration" "frontend_website" {
  bucket = aws_s3_bucket.frontend_bucket.id

  index_document {
    suffix = "index.html"
  }
}

# 3. Disable the "Block Public Access" security switch
resource "aws_s3_bucket_public_access_block" "frontend_public_access" {
  bucket = aws_s3_bucket.frontend_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# 4. Attach a Policy allowing anyone on the internet to view the website
resource "aws_s3_bucket_policy" "frontend_policy" {
  bucket = aws_s3_bucket.frontend_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend_bucket.arn}/*"
      }
    ]
  })
  
  # Terraform must turn off the public block before applying this policy
  depends_on = [aws_s3_bucket_public_access_block.frontend_public_access]
}

# 5. Output your new live Website URL!
output "live_website_url" {
  description = "The public link to your Cloud Artist Platform"
  value       = "http://${aws_s3_bucket_website_configuration.frontend_website.website_endpoint}"
}


# CloudFront Distribution (The Global "Caffeine" for your site)
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    # Points CloudFront to your specific frontend bucket
    domain_name = aws_s3_bucket.frontend_bucket.bucket_regional_domain_name
    origin_id   = "S3-${aws_s3_bucket.frontend_bucket.id}"
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.frontend_bucket.id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    # This ensures your site always uses the secure "https" padlock
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Add a new Output for the secure URL
output "secure_gallery_url" {
  description = "The secure HTTPS link to your Cloud Artist Platform"
  value       = "https://${aws_cloudfront_distribution.s3_distribution.domain_name}"
}