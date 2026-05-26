#!/usr/bin/env bash

# SYNOPSIS
#     Installs all required tools for the ADO-to-GitHub migration accelerator.
# DESCRIPTION
#     Checks for and automatically installs missing tools: GitHub CLI, GEI extension, 
#     Actions Importer, git-sizer, gitleaks, git-filter-repo, and Docker on Ubuntu/Debian.

# Exit on error
set -e

# ANSI escape codes for colors
CYAN='\e[36m'
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
GRAY='\e[90m'
NC='\e[0m' # No Color

echo -e "${CYAN}=== Migration Tooling Installer (Ubuntu Self-Hosted Agent) ===${NC}"

# Detect OS
is_ubuntu=false
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "ubuntu" ] || [ "$ID" = "debian" ] || [[ "$ID_LIKE" == *"ubuntu"* ]] || [[ "$ID_LIKE" == *"debian"* ]]; then
        is_ubuntu=true
    fi
fi

# Function to run commands with sudo if available/necessary
run_sudo() {
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo DEBIAN_FRONTEND=noninteractive "$@"
        else
            echo -e "${RED}ERROR: Root privileges required, but sudo is not installed/available.${NC}"
            exit 1
        fi
    else
        DEBIAN_FRONTEND=noninteractive "$@"
    fi
}

# 0. JQ (JSON Parser)
if command -v jq >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] jq: $(jq --version | head -n 1)${NC}"
else
    echo -e "${YELLOW}[MISSING] jq — Installing...${NC}"
    if [ "$is_ubuntu" = true ]; then
        run_sudo apt-get update
        run_sudo apt-get install jq -y
        echo -e "${GREEN}[OK] jq installed successfully.${NC}"
    else
        echo -e "${RED}  Manual installation required: install jq via your package manager.${NC}"
    fi
fi

# 1. GitHub CLI (gh)
if command -v gh >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] GitHub CLI (gh): $(gh --version | head -n 1)${NC}"
else
    echo -e "${YELLOW}[MISSING] GitHub CLI (gh) — Installing...${NC}"
    if [ "$is_ubuntu" = true ]; then
        run_sudo mkdir -p -m 755 /etc/apt/keyrings
        wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | run_sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
        run_sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | run_sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        run_sudo apt-get update
        run_sudo apt-get install gh -y
        echo -e "${GREEN}[OK] GitHub CLI (gh) installed successfully.${NC}"
    else
        echo -e "${RED}  Manual installation required: https://cli.github.com${NC}"
    fi
fi

# 2. Git
if command -v git >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] Git: $(git --version)${NC}"
else
    echo -e "${YELLOW}[MISSING] Git — Installing...${NC}"
    if [ "$is_ubuntu" = true ]; then
        run_sudo apt-get update
        run_sudo apt-get install git -y
        echo -e "${GREEN}[OK] Git installed successfully.${NC}"
    else
        echo -e "${RED}  Manual installation required: https://git-scm.com${NC}"
    fi
fi

# 3. Docker
if command -v docker >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] Docker: $(docker --version)${NC}"
else
    echo -e "${YELLOW}[MISSING] Docker — Installing...${NC}"
    if [ "$is_ubuntu" = true ]; then
        run_sudo apt-get update
        run_sudo apt-get install docker.io -y
        # Try to add current user to docker group
        current_user=$(whoami)
        run_sudo usermod -aG docker "$current_user" || true
        echo -e "${GREEN}[OK] Docker installed successfully.${NC}"
    else
        echo -e "${RED}  Manual installation required: https://www.docker.com${NC}"
    fi
fi

# Ensure docker daemon is started and user has access to the socket
if command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}Starting Docker daemon and configuring socket permissions...${NC}"
    run_sudo systemctl start docker || run_sudo service docker start || true
    run_sudo systemctl enable docker || true
    if [ -S /var/run/docker.sock ]; then
        run_sudo chmod 666 /var/run/docker.sock || true
        echo -e "${GREEN}[OK] Docker socket permissions configured.${NC}"
    else
        echo -e "${RED}[WARN] Docker socket /var/run/docker.sock not found. Ensure Docker daemon is running.${NC}"
    fi
fi

# 4. Python 3
if command -v python3 >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] Python 3: $(python3 --version)${NC}"
else
    echo -e "${YELLOW}[MISSING] Python 3 — Installing...${NC}"
    if [ "$is_ubuntu" = true ]; then
        run_sudo apt-get update
        run_sudo apt-get install python3 python3-pip -y
        echo -e "${GREEN}[OK] Python 3 installed successfully.${NC}"
    else
        echo -e "${RED}  Manual installation required: https://python.org${NC}"
    fi
fi

# 5. git-sizer
if command -v git-sizer >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] git-sizer: $(git-sizer --version | head -n 1)${NC}"
else
    echo -e "${YELLOW}[MISSING] git-sizer — Installing...${NC}"
    # Download binary from GitHub releases
    temp_dir=$(mktemp -d)
    pushd "$temp_dir" > /dev/null
    if wget -q https://github.com/github/git-sizer/releases/download/v1.5.0/git-sizer-1.5.0-linux-amd64.zip; then
        run_sudo apt-get install unzip -y || true
        unzip -q git-sizer-1.5.0-linux-amd64.zip
        run_sudo mv git-sizer /usr/local/bin/
        echo -e "${GREEN}[OK] git-sizer installed successfully.${NC}"
    else
        echo -e "${RED}  Failed to download git-sizer. Download manually: https://github.com/github/git-sizer/releases${NC}"
    fi
    popd > /dev/null
    rm -rf "$temp_dir"
fi

# 6. gitleaks
if command -v gitleaks >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] gitleaks: $(gitleaks version | head -n 1)${NC}"
else
    echo -e "${YELLOW}[MISSING] gitleaks — Installing...${NC}"
    # Download binary from GitHub releases
    temp_dir=$(mktemp -d)
    pushd "$temp_dir" > /dev/null
    if wget -q https://github.com/gitleaks/gitleaks/releases/download/v8.18.2/gitleaks_8.18.2_linux_x64.tar.gz; then
        tar -xzf gitleaks_8.18.2_linux_x64.tar.gz
        run_sudo mv gitleaks /usr/local/bin/
        echo -e "${GREEN}[OK] gitleaks installed successfully.${NC}"
    else
        echo -e "${RED}  Failed to download gitleaks. Download manually: https://github.com/gitleaks/gitleaks/releases${NC}"
    fi
    popd > /dev/null
    rm -rf "$temp_dir"
fi

# --- Python Packages / git-filter-repo ---
echo -e "\n${CYAN}--- Python Packages ---${NC}"
if git filter-repo --version >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] git-filter-repo${NC}"
else
    echo -e "${YELLOW}[MISSING] git-filter-repo — Installing...${NC}"
    if [ "$is_ubuntu" = true ]; then
        run_sudo apt-get update
        run_sudo apt-get install git-filter-repo -y
        echo -e "${GREEN}[OK] git-filter-repo installed successfully.${NC}"
    else
        # Fallback to pip3
        if command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1; then
            pip_cmd="pip3"
            if ! command -v pip3 >/dev/null 2>&1; then pip_cmd="pip"; fi
            if $pip_cmd install git-filter-repo --break-system-packages >/dev/null 2>&1 || $pip_cmd install git-filter-repo >/dev/null 2>&1; then
                echo -e "${GREEN}[OK] git-filter-repo installed successfully.${NC}"
            else
                echo -e "${RED}  Failed to install via pip. Run manually: pip3 install git-filter-repo${NC}"
            fi
        else
            echo -e "${RED}  Missing pip. Install manually: pip3 install git-filter-repo${NC}"
        fi
    fi
fi

# --- GH Extensions ---
echo -e "\n${CYAN}--- GitHub CLI Extensions ---${NC}"
if command -v gh >/dev/null 2>&1; then
    # List installed extensions
    installedExts=$(gh extension list 2>&1 || echo "")

    # gh-ado2gh
    if echo "$installedExts" | grep -q "gh-ado2gh"; then
        echo -e "${GREEN}[OK] gh-ado2gh${NC}"
    else
        echo -e "${YELLOW}[MISSING] gh-ado2gh — Installing...${NC}"
        if gh extension install github/gh-ado2gh 2>&1; then
            echo -e "${GREEN}  Installed gh-ado2gh${NC}"
        else
            echo -e "${RED}  Failed to install gh-ado2gh. Run manually: gh extension install github/gh-ado2gh${NC}"
        fi
    fi

    # gh-actions-importer
    if echo "$installedExts" | grep -q "actions-importer"; then
        echo -e "${GREEN}[OK] gh-actions-importer${NC}"
        # Pull latest actions-importer Docker image
        echo -e "\n${YELLOW}Pulling latest actions-importer image...${NC}"
        if gh actions-importer update 2>&1; then
            echo -e "${GREEN}[OK] actions-importer image updated${NC}"
        else
            echo -e "${RED}[WARN] Failed to update actions-importer image. Ensure Docker is running.${NC}"
        fi
    else
        echo -e "${YELLOW}[MISSING] gh-actions-importer — Installing...${NC}"
        if gh extension install github/gh-actions-importer 2>&1; then
            echo -e "${GREEN}  Installed gh-actions-importer${NC}"
            # Pull latest actions-importer Docker image
            echo -e "\n${YELLOW}Pulling latest actions-importer image...${NC}"
            if gh actions-importer update 2>&1; then
                echo -e "${GREEN}[OK] actions-importer image updated${NC}"
            else
                echo -e "${RED}[WARN] Failed to update actions-importer image. Ensure Docker is running.${NC}"
            fi
        else
            echo -e "${RED}  Failed to install gh-actions-importer. Run manually: gh extension install github/gh-actions-importer${NC}"
        fi
    fi
else
    echo -e "${YELLOW}[SKIP] Cannot check GH extensions — GitHub CLI not installed${NC}"
fi

# --- PAT Configuration Reminder ---
echo -e "\n${CYAN}=== Token Configuration ===${NC}"
echo -e "${GRAY}Create the following Personal Access Tokens:

1. Azure DevOps PAT (https://dev.azure.com/YOUR_ORG/_usersSettings/tokens)
   Scopes: Code (Read), Build (Read & Execute), Release (Read), 
           Work Items (Read), Project & Team (Read), Graph (Read)

2. GitHub PAT (https://github.com/settings/tokens)
   Scopes: repo, admin:org, workflow, read:packages
   For GEI: Also needs 'read:enterprise' if enterprise-level migration

Store tokens securely. NEVER commit them to repos.
Set as environment variables:
  export ADO_PAT='your-ado-pat'
  export GH_PAT='your-github-pat'${NC}"

echo -e "\n${CYAN}Tooling check and automated installation complete.${NC}"
