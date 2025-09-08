# Replace GIT_REPO
git filter-branch --tree-filter 'sed -i "s|GIT_REPO="${GIT_REPO:-}"|GIT_REPO=\"\${GIT_REPO:-\}\"|g" docker-compose.yaml' -- multiarch

# Replace IMAGE_NAME
git filter-branch --tree-filter 'sed -i "s|IMAGE_NAME="${IMAGE_NAME:-}"|IMAGE_NAME=\"\${IMAGE_NAME:-\}\"|g" docker-compose.yaml' -- multiarch

# Replace image line
git filter-branch --tree-filter 'sed -i "s|image: "${IMAGE_NAME:-}"|image: \"\${IMAGE_NAME:-\}\"|g" docker-compose.yaml' -- multiarch

# Optional: Replace service name if desired
git filter-branch --tree-filter 'sed -i "s|dp-databricks-application|dev|g" docker-compose.yaml' -- multiarch


git push origin multiarch --force
