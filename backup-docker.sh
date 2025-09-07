#!/bin/bash

# Docker Image Backup Script
# Usage: ./backup-docker.sh [save|load|push|pull] [image-name] [backup-path]

set -e

ACTION=$1
IMAGE_NAME=$2
BACKUP_PATH=${3:-"./docker-backup"}

if [ -z "$ACTION" ] || [ -z "$IMAGE_NAME" ]; then
    echo "Usage: $0 [save|load|push|pull] [image-name] [backup-path]"
    echo ""
    echo "Examples:"
    echo "  $0 save my-dev-env ./backups"
    echo "  $0 load my-dev-env ./backups"
    echo "  $0 push my-dev-env myusername/myrepo"
    echo "  $0 pull my-dev-env myusername/myrepo"
    exit 1
fi

case $ACTION in
    "save")
        echo "Saving Docker image $IMAGE_NAME to $BACKUP_PATH/"
        mkdir -p "$BACKUP_PATH"
        docker save "$IMAGE_NAME" > "$BACKUP_PATH/docker-image.tar"
        echo "Image saved successfully!"
        ls -lh "$BACKUP_PATH/docker-image.tar"
        ;;

    "load")
        echo "Loading Docker image from $BACKUP_PATH/docker-image.tar"
        docker load < "$BACKUP_PATH/docker-image.tar"
        echo "Image loaded successfully!"
        ;;

    "push")
        echo "Pushing $IMAGE_NAME to registry"
        docker push "$IMAGE_NAME"
        echo "Image pushed successfully!"
        ;;

    "pull")
        echo "Pulling $IMAGE_NAME from registry"
        docker pull "$IMAGE_NAME"
        echo "Image pulled successfully!"
        ;;

    *)
        echo "Invalid action. Use: save, load, push, or pull"
        exit 1
        ;;
esac