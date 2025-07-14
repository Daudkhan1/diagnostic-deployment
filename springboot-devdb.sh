#!/bin/bash
set -e

# === CONFIGURATION ===
STACK_NAME="praid"
SERVICE_NAME="springboot-app"
DB_NAME="diagnostics"
BACKUP_DIR="/home/ubuntu/mongo-backups"
TIMESTAMP=$(date +"%Y-%m-%d-%H-%M")
OLD_STACK="/home/ubuntu/docker-stack.yml"
NEW_STACK="/home/ubuntu/docker-stack.yml"
BACKUP_PATH="${BACKUP_DIR}/springboot-backup-${TIMESTAMP}.gz"
PROD_DUMP_DIR="/tmp/daily-backup-prod-db"

mkdir -p "$BACKUP_DIR"


# === FUNCTION: Extract image tag ===
get_image_tag() {
  grep -A1 "${SERVICE_NAME}:" "$1" | grep "image:" | awk -F: '{print $NF}' | tr -d ' '
}

# === STEP 1: Extract old tag BEFORE overwriting stack ===
echo "Extracting OLD image tag from current stack file..."
OLD_TAG=$(get_image_tag "$OLD_STACK")

# === STEP 2: Copy updated docker-stack.yml from S3 ===
echo "Fetching updated docker-stack.yml from S3..."
aws s3 cp s3://${S3_BUCKET}/${DEPLOY_ENV}/docker-stack.yml /home/ubuntu/docker-stack.yml

# === STEP 3: Extract NEW tag after updated file is copied ===
echo "Extracting NEW image tag from updated stack file..."
NEW_TAG=$(get_image_tag "$NEW_STACK")

# === STEP 4: Compare Tags ===
if [ -z "$OLD_TAG" ] || [ -z "$NEW_TAG" ]; then
  echo "Failed to extract tags for ${SERVICE_NAME}. Aborting..."
  exit 1
fi

echo "Old Tag: $OLD_TAG"
echo "New Tag: $NEW_TAG"

if [ "$OLD_TAG" == "$NEW_TAG" ]; then
  echo "No change in springboot-app image tag. Skipping backup/restore logic."
  docker stack deploy -c "$NEW_STACK" --with-registry-auth "$STACK_NAME"
  exit 0
fi

echo "springboot-app is being updated. Taking Mongo backup..."

# === STEP 2: Backup Mongo ===
docker exec $(docker ps --filter "name=${STACK_NAME}_mongo" -q) mongodump --db="$DB_NAME" --archive | gzip > "$BACKUP_PATH"
echo "Backup saved to $BACKUP_PATH"

# === STEP 3: Deploy stack ===
docker stack deploy -c "$NEW_STACK" --with-registry-auth "$STACK_NAME"
echo "Waiting 120s for service to stabilize..."
sleep 120

# === STEP 4: Check if deployment failed (rollback happened) ===
RUNNING_TAG=$(docker service inspect "${STACK_NAME}_${SERVICE_NAME}" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | awk -F: '{print $NF}')

echo "Running Tag after deployment: $RUNNING_TAG"

if [ "$RUNNING_TAG" == "$OLD_TAG" ]; then
  echo "Rollback detected! Restoring Mongo backup..."
  gunzip -c "$BACKUP_PATH" | docker exec -i $(docker ps --filter "name=${STACK_NAME}_mongo" -q) mongorestore --archive --drop
  echo "MongoDB restored to previous state."
else
  echo "springboot-app deployed successfully."

  # === STEP 5: Dump prod DB ===
  echo "Dumping production database to $PROD_DUMP_DIR..."
  mkdir -p "$PROD_DUMP_DIR"
  docker exec $(docker ps --filter "name=${STACK_NAME}_mongo" -q) mongodump --db="$DB_NAME" --out="$PROD_DUMP_DIR"

  # === STEP 6: Truncate dev DB ===
  echo "Truncating dev database..."
  docker exec $(docker ps --filter "name=${STACK_NAME}_mongo" -q) mongosh "$DB_NAME" --eval \
    'db.getCollectionNames().forEach(function(c) { db[c].deleteMany({}); })'

  # === STEP 7: Restore prod dump into dev DB ===
  echo "Restoring prod DB into dev environment..."
  docker exec $(docker ps --filter "name=${STACK_NAME}_mongo" -q) mongorestore --dir="$PROD_DUMP_DIR" --drop
  echo "Dev DB updated with fresh Prod data."
fi
