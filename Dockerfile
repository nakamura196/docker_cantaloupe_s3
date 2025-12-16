FROM islandora/cantaloupe:2.0.10

# App Runner uses port 8080 by default, but Cantaloupe uses 8182
# We'll configure App Runner to use port 8182 instead

# Environment variables will be set via App Runner console or apprunner.yaml
# CANTALOUPE_SOURCE_STATIC=S3Source
# CANTALOUPE_S3SOURCE_ACCESS_KEY_ID
# CANTALOUPE_S3SOURCE_SECRET_KEY
# CANTALOUPE_S3SOURCE_REGION
# CANTALOUPE_S3SOURCE_ENDPOINT
# CANTALOUPE_S3SOURCE_BASICLOOKUPSTRATEGY_BUCKET_NAME
# CANTALOUPE_S3SOURCE_LOOKUP_STRATEGY=BasicLookupStrategy

EXPOSE 8182
