# Docker Image Backup Guide

## Quick Start
```bash
# Make script executable
chmod +x backup-docker.sh

# Save your image
./backup-docker.sh save your-image-name ./backups

# Load your image later
./backup-docker.sh load your-image-name ./backups
```

## Method 1: File Backup (Recommended for Local)
```bash
# Save image to file
docker save your-dev-env:latest > ./backups/dev-env-$(date +%Y%m%d).tar

# Load image from file
docker load < ./backups/dev-env-20241206.tar
```

## Method 2: Docker Hub (Recommended for Sharing)
```bash
# Tag and push
docker tag your-dev-env:latest yourusername/dev-env:latest
docker push yourusername/dev-env:latest

# Pull later
docker pull yourusername/dev-env:latest
```

## Method 3: Private Registry
```bash
# Push to private registry
docker tag your-dev-env:latest registry.example.com/dev-env:latest
docker push registry.example.com/dev-env:latest

# Pull from private registry
docker pull registry.example.com/dev-env:latest
```

## Method 4: Docker Desktop Data Directory
If using Docker Desktop, your images are stored in:
- **macOS**: `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`
- **Windows**: `C:\Users\[username]\AppData\Local\Docker\wsl\data\ext4.vhdx`

## Best Practices
1. **Regular Backups**: Backup after major changes
2. **Version Tags**: Use semantic versioning (v1.0.0, v1.1.0)
3. **Multiple Locations**: Store backups in multiple places
4. **Automation**: Use the backup script for consistency
5. **Documentation**: Keep track of what each image contains

## Recovery Steps
1. Reinstall Docker
2. Run: `docker load < your-backup.tar`
3. Or: `docker pull your-registry/image:tag`
4. Verify: `docker images` and `docker run your-image`