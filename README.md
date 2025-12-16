# Docker Cantaloupe with Amazon S3

Try the Docker version of Cantaloupe with Amazon S3.

## Settings

```
git clone https://github.com/nakamura196/docker_cantaloupe_s3.git
cd docker_cantaloupe_s3
```

Edit `.env` file based on `.env.sample`.

```
# aws s3
CANTALOUPE_S3SOURCE_ENDPOINT=
# mdx.jp
# CANTALOUPE_S3SOURCE_ENDPOINT=https://s3ds.mdx.jp
CANTALOUPE_S3SOURCE_ACCESS_KEY_ID=
CANTALOUPE_S3SOURCE_SECRET_KEY=
CANTALOUPE_S3SOURCE_REGION=
CANTALOUPE_S3SOURCE_BASICLOOKUPSTRATEGY_BUCKET_NAME=
```

## Usage

```
docker-compose up -d
```

## AWS App Runner Deployment

### Prerequisites

1. AWS CLI configured
2. ECR repository created

### Step 1: Build and push Docker image to ECR

```bash
# Login to ECR
aws ecr get-login-password --region ap-northeast-1 | docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com

# Build the image
docker build -t cantaloupe .

# Tag the image
docker tag cantaloupe:latest <AWS_ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/cantaloupe:latest

# Push to ECR
docker push <AWS_ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/cantaloupe:latest
```

### Step 2: Create App Runner service

**Option A: Using AWS Console**

1. Go to AWS App Runner console
2. Click "Create service"
3. Select "Container registry" > "Amazon ECR"
4. Select your ECR image
5. Configure:
   - Port: `8182`
   - Environment variables:
     - `CANTALOUPE_SOURCE_STATIC`: `S3Source`
     - `CANTALOUPE_S3SOURCE_LOOKUP_STRATEGY`: `BasicLookupStrategy`
     - `CANTALOUPE_S3SOURCE_ACCESS_KEY_ID`: your access key
     - `CANTALOUPE_S3SOURCE_SECRET_KEY`: your secret key
     - `CANTALOUPE_S3SOURCE_REGION`: your region (e.g., `ap-northeast-1`)
     - `CANTALOUPE_S3SOURCE_ENDPOINT`: leave empty for AWS S3
     - `CANTALOUPE_S3SOURCE_BASICLOOKUPSTRATEGY_BUCKET_NAME`: your bucket name
6. Configure health check path: `/iiif/3`
7. Create and deploy

**Option B: Using AWS CLI**

```bash
aws apprunner create-service \
  --service-name cantaloupe \
  --source-configuration '{
    "ImageRepository": {
      "ImageIdentifier": "<AWS_ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/cantaloupe:latest",
      "ImageRepositoryType": "ECR",
      "ImageConfiguration": {
        "Port": "8182",
        "RuntimeEnvironmentVariables": {
          "CANTALOUPE_SOURCE_STATIC": "S3Source",
          "CANTALOUPE_S3SOURCE_LOOKUP_STRATEGY": "BasicLookupStrategy",
          "CANTALOUPE_S3SOURCE_ACCESS_KEY_ID": "your_access_key",
          "CANTALOUPE_S3SOURCE_SECRET_KEY": "your_secret_key",
          "CANTALOUPE_S3SOURCE_REGION": "ap-northeast-1",
          "CANTALOUPE_S3SOURCE_BASICLOOKUPSTRATEGY_BUCKET_NAME": "your-bucket-name"
        }
      }
    },
    "AutoDeploymentsEnabled": true,
    "AuthenticationConfiguration": {
      "AccessRoleArn": "arn:aws:iam::<AWS_ACCOUNT_ID>:role/AppRunnerECRAccessRole"
    }
  }' \
  --instance-configuration '{
    "Cpu": "1024",
    "Memory": "2048"
  }' \
  --health-check-configuration '{
    "Protocol": "HTTP",
    "Path": "/iiif/3",
    "Interval": 10,
    "Timeout": 5,
    "HealthyThreshold": 1,
    "UnhealthyThreshold": 5
  }'
```

### Required IAM Role for App Runner

Create an IAM role `AppRunnerECRAccessRole` with the following policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:ap-northeast-1:<AWS_ACCOUNT_ID>:repository/cantaloupe"
    },
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    }
  ]
}
```

Trust relationship:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "build.apprunner.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

## Reference

https://github.com/nakamura196/docker_cantaloupe
