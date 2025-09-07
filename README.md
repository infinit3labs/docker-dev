# Build the base image (can be done once)
docker build --target builder -t my-dev-env-base .

# Build the final image with user-specific setup
docker build -t my-dev-env \
  --build-arg GIT_TOKEN=your_token \
  --build-arg GIT_REPO=your/repo \
  --build-arg GIT_USER_NAME="Your Name" \
  --build-arg GIT_USER_EMAIL="your@email.com" .

See also: BUILD_AND_DEPLOY.md for a complete end-to-end guide with Docker Compose.