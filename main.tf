terraform {
  required_version = ">= 0.10.6"

  backend "s3" {
    # region, bucket, and key configured via init.sh
    dynamodb_table = "terraform-state"
  }
}

provider "aws" {
  region  = "us-east-1"
  version = "~> 1.0"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = "${data.aws_caller_identity.current.account_id}"
}

resource "aws_dynamodb_table" "dynamodb_posts_table" {
  name           = "posts${var.instance}"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_s3_bucket" "website" {
  bucket = "${local.account_id}-pollywebsite${var.instance}"
  acl    = "private"
  website {
    index_document = "index.html"
    error_document = "error.html"
  }
}

resource "aws_s3_bucket_policy" "website_policy" {
  bucket = "${aws_s3_bucket.website.id}"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Sid": "PublicReadGetObject",
          "Effect": "Allow",
          "Principal": "*",
          "Action": [
              "s3:GetObject"
          ],
          "Resource": [
              "${aws_s3_bucket.website.arn}/*"
          ]
      }
  ]
}
EOF
}

resource "aws_s3_bucket_object" "website_styles_css" {
  bucket = "${aws_s3_bucket.website.bucket}"
  key    = "styles.css"
  source = "resources/styles.css"
  content_type = "text/css"
  etag   = "${md5(file("resources/styles.css"))}"
}

data "template_file" "website_scripts_js" {
  template = "${file("${path.cwd}/resources/scripts.js.tpl")}"
  vars {
    api-gateway-url = "https://${aws_api_gateway_deployment.api_dev.rest_api_id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_deployment.api_dev.stage_name}"
  }
}

resource "aws_s3_bucket_object" "website_scripts_js" {
  bucket = "${aws_s3_bucket.website.bucket}"
  key    = "scripts.js"
  content = "${data.template_file.website_scripts_js.rendered}"
  content_type = "application/javascript"
  etag   = "${md5("${data.template_file.website_scripts_js.rendered}")}"
}

resource "aws_s3_bucket_object" "website_index_html" {
  bucket = "${aws_s3_bucket.website.bucket}"
  key    = "index.html"
  source = "resources/index.html"
  content_type = "text/html"
  etag   = "${md5(file("resources/index.html"))}"
}

resource "aws_s3_bucket" "audio_files" {
  bucket = "${local.account_id}-pollyaudiofiles${var.instance}"
  acl    = "private"
}

resource "aws_sns_topic" "new_posts" {
  name = "new_posts${var.instance}"
}

resource "aws_iam_role" "lambda_posts_reader_role" {
  name = "LambdaPostsReaderRole${var.instance}"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "lambda_policy_for_polly" {
  name = "LambdaPolicyForPolly"
  role = "${aws_iam_role.lambda_posts_reader_role.id}"
  policy = "${file("resources/lambdapolicy.json")}"
}

data "archive_file" "newposts_zip" {
  type = "zip"
  source_file = "resources/newposts.py"
  output_path = ".tmp/newposts.zip"
}

resource "aws_lambda_function" "PostReader_NewPost" {
  filename         = "${data.archive_file.newposts_zip.output_path}"
  source_code_hash = "${base64sha256(file("${data.archive_file.newposts_zip.output_path}"))}"
  function_name    = "PostReader_NewPost${var.instance}"
  role             = "${aws_iam_role.lambda_posts_reader_role.arn}"
  handler          = "newposts.lambda_handler"
  runtime          = "python2.7"
  publish          = true
  environment {
    variables = {
      DB_TABLE_NAME = "${aws_dynamodb_table.dynamodb_posts_table.name}"
      SNS_TOPIC = "${aws_sns_topic.new_posts.arn}"
    }
  }
}

data "archive_file" "convertoaudio_zip" {
  type = "zip"
  source_file = "resources/convertoaudio.py"
  output_path = ".tmp/convertoaudio.zip"
}

resource "aws_lambda_function" "PostReader_ConvertToAudio" {
  filename         = "${data.archive_file.convertoaudio_zip.output_path}"
  source_code_hash = "${base64sha256(file("${data.archive_file.convertoaudio_zip.output_path}"))}"
  function_name    = "PostReader_ConvertToAudio${var.instance}"
  role             = "${aws_iam_role.lambda_posts_reader_role.arn}"
  handler          = "convertoaudio.lambda_handler"
  runtime          = "python2.7"
  timeout          = 300
  publish          = true
  environment {
    variables = {
      DB_TABLE_NAME = "${aws_dynamodb_table.dynamodb_posts_table.name}"
      BUCKET_NAME = "${aws_s3_bucket.audio_files.bucket}"
    }
  }
}

resource "aws_lambda_permission" "with_sns" {
  statement_id = "AllowExecutionFromSNS"
  action = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.PostReader_ConvertToAudio.function_name}"
  principal = "sns.amazonaws.com"
  source_arn = "${aws_sns_topic.new_posts.arn}"
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = "${aws_sns_topic.new_posts.arn}"
  protocol  = "lambda"
  endpoint  = "${aws_lambda_function.PostReader_ConvertToAudio.arn}"
}

data "archive_file" "getposts_zip" {
  type = "zip"
  source_file = "resources/getposts.py"
  output_path = ".tmp/getposts.zip"
}

resource "aws_lambda_function" "PostReader_GetPosts" {
  filename         = "${data.archive_file.getposts_zip.output_path}"
  source_code_hash = "${base64sha256(file("${data.archive_file.getposts_zip.output_path}"))}"
  function_name    = "PostReader_GetPosts${var.instance}"
  role             = "${aws_iam_role.lambda_posts_reader_role.arn}"
  handler          = "getposts.lambda_handler"
  runtime          = "python2.7"
  publish          = true
  environment {
    variables = {
      DB_TABLE_NAME = "${aws_dynamodb_table.dynamodb_posts_table.name}"
    }
  }
}


resource "aws_api_gateway_rest_api" "api" {
  name = "PostReaderAPI${var.instance}"
}

// No aws_api_gateway_resource instances since we're putting our methods on the root

resource "aws_api_gateway_method" "post" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "post" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "${aws_api_gateway_method.post.http_method}"
  integration_http_method = "POST" # invoking lambda is always a POST, independent of the http_method
  type = "AWS"
  uri = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${aws_lambda_function.PostReader_NewPost.arn}/invocations"
}

resource "aws_lambda_permission" "allow_api_to_call_post_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.PostReader_NewPost.arn}"
  principal     = "apigateway.amazonaws.com"
  source_arn = "arn:aws:execute-api:${var.aws_region}:${local.account_id}:${aws_api_gateway_rest_api.api.id}/*/${aws_api_gateway_method.post.http_method}/"
}

resource "aws_api_gateway_integration_response" "post" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "${aws_api_gateway_method.post.http_method}"
  status_code = "${aws_api_gateway_method_response.post.status_code}"
  depends_on  = ["aws_api_gateway_integration.post"]
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }
  response_templates {
    "application/json" = ""
  }
}

resource "aws_api_gateway_method_response" "post" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "${aws_api_gateway_method.post.http_method}"
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_method" "get" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "GET"
  authorization = "NONE"
  depends_on  = ["aws_api_gateway_method.post"] # hacky workaround to create methods one at a time to avoid ConflictExceptions
  request_parameters = {
    "method.request.querystring.postId" = false # false means optional
  }
}

resource "aws_api_gateway_integration" "get" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "${aws_api_gateway_method.get.http_method}"
  integration_http_method = "POST" # invoking lambda is always a POST, independent of the http_method
  type = "AWS"
  uri = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${aws_lambda_function.PostReader_GetPosts.arn}/invocations"
  request_templates = {
    "application/json" = <<EOF
{
  "postId": "$input.params('postId')"
}
EOF
  }
  passthrough_behavior = "WHEN_NO_TEMPLATES"
}

resource "aws_lambda_permission" "allow_api_to_call_get_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.PostReader_GetPosts.function_name}"
  principal     = "apigateway.amazonaws.com"
  source_arn = "arn:aws:execute-api:${var.aws_region}:${local.account_id}:${aws_api_gateway_rest_api.api.id}/*/${aws_api_gateway_method.get.http_method}/"
}

resource "aws_api_gateway_integration_response" "get" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "${aws_api_gateway_method.get.http_method}"
  status_code = "${aws_api_gateway_method_response.get.status_code}"
  depends_on  = ["aws_api_gateway_integration.get"]
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }
  response_templates {
    "application/json" = ""
  }
}

resource "aws_api_gateway_method_response" "get" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "${aws_api_gateway_method.get.http_method}"
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}




# CORS
resource "aws_api_gateway_method" "options" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "OPTIONS"
  authorization = "NONE"
  depends_on  = ["aws_api_gateway_method.get"] # hacky workaround to create methods one at a time to avoid ConflictExceptions
}

resource "aws_api_gateway_integration" "options" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "${aws_api_gateway_method.options.http_method}"
  type = "MOCK"
  request_templates = {
    "application/json" = <<EOF
{"statusCode": 200}
EOF
  }
}

resource "aws_api_gateway_integration_response" "options" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "${aws_api_gateway_method.options.http_method}"
  status_code = "${aws_api_gateway_method_response.options.status_code}"
  depends_on  = ["aws_api_gateway_integration.options"]
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'",
    "method.response.header.Access-Control-Allow-Methods" = "'POST,GET,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }
  response_templates = {
    "application/json" = ""
  }
}

resource "aws_api_gateway_method_response" "options" {
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  resource_id = "${aws_api_gateway_rest_api.api.root_resource_id}"
  http_method = "${aws_api_gateway_method.options.http_method}"
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_deployment" "api_dev" {
  depends_on = [
    "aws_api_gateway_method.post",
    "aws_api_gateway_integration.post",
    "aws_api_gateway_integration_response.post",
    "aws_api_gateway_method_response.post",
    "aws_api_gateway_method.get",
    "aws_api_gateway_integration.get",
    "aws_api_gateway_integration_response.get",
    "aws_api_gateway_method_response.get",
    "aws_api_gateway_method.options",
    "aws_api_gateway_integration.options",
    "aws_api_gateway_integration_response.options",
    "aws_api_gateway_method_response.options"
  ]
  rest_api_id = "${aws_api_gateway_rest_api.api.id}"
  stage_name = "dev"
  # This never seems to run, so we force it to run every time. This is an undesirable workaround.
  # See: https://github.com/hashicorp/terraform/issues/6613#issuecomment-289797226
  description = "Deployed at ${timestamp()}"
}

output "website_endpoint" {
  value = "http://${aws_s3_bucket.website.website_endpoint}"
}
