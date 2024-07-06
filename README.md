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

## Reference

https://github.com/nakamura196/docker_cantaloupe
