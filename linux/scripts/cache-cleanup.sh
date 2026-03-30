#!/bin/bash
echo "=== UV cache ===" && uv cache clean 2>/dev/null || true
echo "=== PIP cache ===" && pip cache purge 2>/dev/null || true
echo "=== NPM cache ===" && npm cache clean --force 2>/dev/null || true
echo "=== Playwright cache ===" && rm -rf "$HOME/.cache/ms-playwright" 2>/dev/null || true
echo "=== Puppeteer cache ===" && rm -rf "$HOME/.cache/puppeteer" 2>/dev/null || true
echo "Cache cleanup complete"
