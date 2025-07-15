#!/bin/bash
set -e

echo "========================= SCRIPT STARTED ========================="

# === CONFIGURATION ===
echo "[INFO] Loading configuration variables..."
STACK_NAME="praid"
SERVICE_NAME="springboot-app"
DB_NAME="diagnostics"
PROD_DB_NAME="diagnostic"
MONGO_ATLAS_URI="mongodb+srv://daud:daudmongo1122@mongocluster.rsosbt7.mongodb.net/diagnostic?retryWrites=true&w=majority&appName=mongocluster"
BACKUP_DIR="/home/ubuntu/mongo-backups"
TIMESTAMP=$(date +"%Y-%m-%d-%H-%M")
OLD_STACK="/home/ubuntu/docker-stack.yml"
NEW_STACK="/home/ubuntu/docker-stack.yml"
BACKUP_PATH="${BACKUP_DIR}/springboot-backup-${TIMESTAMP}.gz"
PROD_DUMP_DIR="/tmp/daily-backup-prod-db"

echo "[INFO] BACKUP_PATH: $BACKUP_PATH"
echo "[INFO] PROD_DUMP_DIR: $PROD_DUMP_DIR"

echo "[STEP] Creating backup directory if not exists..."
mkdir -p "$BACKUP_DIR"

echo "[STEP] Downloading delegates.rb from S3..."
aws s3 cp s3://$S3_BUCKET_NAME/$DEPLOY_ENV/delegates.rb /home/ubuntu/delegates.rb


# === FUNCTION: Extract image tag ===
get_image_tag() {
  grep -A1 "${SERVICE_NAME}:" "$1" | grep "image:" | awk -F: '{print $NF}' | tr -d ' '
}

# === STEP 1: Extract old tag BEFORE overwriting stack ===
echo "[STEP] Extracting OLD image tag from current stack file..."
OLD_TAG=$(get_image_tag "$OLD_STACK")
echo "[INFO] OLD_TAG: $OLD_TAG"

# === STEP 2: Copy updated docker-stack.yml from S3 ===
echo "[STEP] Fetching updated docker-stack.yml from S3..."
aws s3 cp s3://${S3_BUCKET_NAME}/${DEPLOY_ENV}/docker-stack.yml /home/ubuntu/docker-stack.yml

# === STEP 3: Extract NEW tag after updated file is copied ===
echo "[STEP] Extracting NEW image tag from updated stack file..."
NEW_TAG=$(get_image_tag "$NEW_STACK")
echo "[INFO] NEW_TAG: $NEW_TAG"

# === STEP 4: Compare Tags ===
if [ -z "$OLD_TAG" ] || [ -z "$NEW_TAG" ]; then
  echo "[ERROR] Failed to extract tags for ${SERVICE_NAME}. Aborting..."
  exit 1
fi

echo "[CHECK] Comparing OLD and NEW tags..."
if [ "$OLD_TAG" == "$NEW_TAG" ]; then
  echo "[RESULT] No change in springboot-app image tag. Skipping backup/restore logic."

  echo "[STEP] Ensuring Swarm is initialized..."
  docker swarm init || echo "[INFO] Swarm already initialized"

  echo "[STEP] Logging into AWS ECR..."
  aws ecr get-login-password --region "$AMAZON_S3_REGION_NAME" | docker login --username AWS --password-stdin "$ECR_URI"

  echo "[STEP] Deploying unchanged stack..."
  docker stack deploy -c "$NEW_STACK" --with-registry-auth "$STACK_NAME"
  sleep 30
  docker container prune -f && docker image prune -a -f
  echo "[DONE] Script completed without updates."
  exit 0
fi

echo "[RESULT] Detected change in image tag. Proceeding with backup/restore and redeploy..."

# === STEP 2: Backup Mongo ===
echo "[STEP] Backing up current dev Mongo DB..."
docker exec $(docker ps --filter "name=${STACK_NAME}_mongo" -q) mongodump --db="$DB_NAME" --archive | gzip > "$BACKUP_PATH"
echo "[INFO] Backup saved to $BACKUP_PATH"

# === STEP 3: Deploy stack ===
echo "[STEP] Logging into AWS ECR..."
aws ecr get-login-password --region "$AMAZON_S3_REGION_NAME" | docker login --username AWS --password-stdin "$ECR_URI"

echo "[STEP] Ensuring Swarm is initialized..."
docker swarm init || echo "[INFO] Swarm already initialized"

echo "[STEP] Deploying updated stack..."
docker stack deploy -c "$NEW_STACK" --with-registry-auth "$STACK_NAME"
echo "[WAIT] Waiting 120s for service to stabilize..."
sleep 60
docker container prune -f && docker image prune -a -f
# === STEP 4: Check if deployment failed (rollback happened) ===
echo "[STEP] Inspecting currently running image tag..."
RUNNING_TAG=$(docker service inspect "${STACK_NAME}_${SERVICE_NAME}" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | awk -F: '{print $NF}')
echo "[INFO] RUNNING_TAG: $RUNNING_TAG"

if [ "$RUNNING_TAG" == "$OLD_TAG" ]; then
  echo "[RESULT] Rollback detected. Restoring backup..."
  gunzip -c "$BACKUP_PATH" | docker exec -i $(docker ps --filter "name=${STACK_NAME}_mongo" -q) mongorestore --archive --drop
  echo "[INFO] MongoDB restored to previous state."
else
  echo "[RESULT] Deployment succeeded. Proceeding with DB sync..."

  # === STEP 5: Dump prod DB ===
  echo "[STEP] Dumping production Mongo Atlas DB to $PROD_DUMP_DIR..."
  mkdir -p "$PROD_DUMP_DIR"
  mongodump --uri="$MONGO_ATLAS_URI" --db="$PROD_DB_NAME" --out="$PROD_DUMP_DIR"
  echo "[INFO] PROD dump completed"

  # === STEP 6: Truncate dev DB ===
  echo "[STEP] Truncating dev DB '$DB_NAME'..."
  docker exec $(docker ps --filter "name=${STACK_NAME}_mongo" -q) mongosh "$DB_NAME" --eval \
    'db.getCollectionNames().forEach(function(c) { db[c].deleteMany({}); })'
  echo "[INFO] Dev DB truncated"

  # === STEP 7: Restore prod dump into dev DB ===
  echo "[STEP] Restoring prod dump into dev DB..."
  mongorestore --host localhost --port 27017 \
    --nsFrom="${PROD_DB_NAME}.*" --nsTo="${DB_NAME}.*" \
    --dir="$PROD_DUMP_DIR" --drop
  echo "[INFO] Dev DB updated with fresh Prod data."
fi

echo "========================= SCRIPT COMPLETED ✅ ========================="