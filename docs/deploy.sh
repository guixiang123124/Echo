#!/bin/bash
# Echo Docs Deployment Script
# Usage: ./deploy.sh

cd /Users/xianggui/.openclaw/workspace/Echo/docs

# Check for changes
if [ -z "$(git status --porcelain)" ]; then
    echo "No changes to deploy"
    exit 0
fi

# Add all changes
git add -A

# Commit with timestamp
DATE=$(date "+%Y-%m-%d %H:%M")
git commit -m "docs: update features page - $DATE"

# Push to trigger Vercel deployment
echo "Pushing to GitHub (will trigger Vercel auto-deploy)..."
git push origin main

echo "✅ Deployed! Check https://docs-9l91ofmwf-guixiang123124s-projects.vercel.app in a few minutes"
