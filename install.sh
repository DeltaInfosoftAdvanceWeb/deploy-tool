#!/bin/bash
# ── One-liner installer ───────────────────────────────────────────────────────
# Run this on any Mac:
#   curl -fsSL https://raw.githubusercontent.com/DeltaInfosoftAdvanceWeb/deploy-tool/main/install.sh | bash
# ─────────────────────────────────────────────────────────────────────────────

set -e

GITHUB_RAW="https://raw.githubusercontent.com/DeltaInfosoftAdvanceWeb/deploy-tool/main"
DEPLOY_DIR="$HOME/.deploy"

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  deploy-tool — Installer${NC}"
echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"
echo ""

# ── Create ~/.deploy ──────────────────────────────────────────────────────────
echo -e "${DIM}  Creating $DEPLOY_DIR ...${NC}"
mkdir -p "$DEPLOY_DIR"
echo -e "${GREEN}  ✅ Created $DEPLOY_DIR${NC}"

# ── Download deploy.sh ────────────────────────────────────────────────────────
echo -e "${DIM}  Downloading deploy engine...${NC}"
if curl -fsSL "$GITHUB_RAW/deploy.sh" -o "$DEPLOY_DIR/deploy.sh"; then
  chmod +x "$DEPLOY_DIR/deploy.sh"
  echo -e "${GREEN}  ✅ Deploy engine ready at $DEPLOY_DIR/deploy.sh${NC}"
else
  echo -e "${RED}  ❌ Failed to download deploy.sh${NC}"
  exit 1
fi

# ── Create ~/bin and install setup-deploy ────────────────────────────────────
mkdir -p "$HOME/bin"
echo -e "${DIM}  Downloading setup-deploy CLI...${NC}"
if curl -fsSL "$GITHUB_RAW/setup-deploy" -o "$HOME/bin/setup-deploy"; then
  chmod +x "$HOME/bin/setup-deploy"
  echo -e "${GREEN}  ✅ setup-deploy installed to $HOME/bin${NC}"
else
  echo -e "${RED}  ❌ Failed to download setup-deploy${NC}"
  exit 1
fi

# ── Add ~/bin to PATH ─────────────────────────────────────────────────────────
ZSHRC="$HOME/.zshrc"
if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$ZSHRC" 2>/dev/null; then
  echo '' >> "$ZSHRC"
  echo '# deploy-tool' >> "$ZSHRC"
  echo 'export PATH="$HOME/bin:$PATH"' >> "$ZSHRC"
  echo -e "${GREEN}  ✅ Added ~/bin to PATH in ~/.zshrc${NC}"
else
  echo -e "${DIM}  ~/bin already in PATH — skipping${NC}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅ Installation complete!${NC}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Run this to activate:${NC}"
echo -e "  ${CYAN}    source ~/.zshrc${NC}"
echo ""
echo -e "  ${BOLD}Then setup any Next.js project:${NC}"
echo -e "  ${CYAN}    cd your-project${NC}"
echo -e "  ${CYAN}    setup-deploy${NC}"
echo ""
