#!/usr/bin/env bash

# SYNOPSIS
#     Installs all required tools for the ADO-to-GitHub migration accelerator.
# DESCRIPTION
#     Checks for and installs: GitHub CLI, GEI extension, Actions Importer,
#     git-sizer, gitleaks, git-filter-repo, and Docker.

# Exit on error
set -e

# ANSI escape codes for colors
CYAN='\e[36m'
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
GRAY='\e[90m'
NC='\e[0m' # No Color

echo -e "${CYAN}=== Migration Tooling Installer ===${NC}"

# Define tools
declare -A tool_commands
tool_commands["GitHub CLI (gh)"]="gh"
tool_commands["Git"]="git"
tool_commands["Docker"]="docker"
tool_commands["Python 3"]="python3"
tool_commands["git-sizer"]="git-sizer"
tool_commands["gitleaks"]="gitleaks"

declare -A tool_install_cmds
tool_install_cmds["GitHub CLI (gh)"]="curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null && sudo apt update && sudo apt install gh -y"
tool_install_cmds["Git"]="sudo apt-get update && sudo apt-get install git -y"
tool_install_cmds["Docker"]="sudo apt-get update && sudo apt-get install docker.io -y"
tool_install_cmds["Python 3"]="sudo apt-get update && sudo apt-get install python3 python3-pip -y"
tool_install_cmds["git-sizer"]="Download from: https://github.com/github/git-sizer/releases"
tool_install_cmds["gitleaks"]="Download from: https://github.com/gitleaks/gitleaks/releases"

declare -A tool_urls
tool_urls["GitHub CLI (gh)"]="https://cli.github.com"
tool_urls["Git"]="https://git-scm.com"
tool_urls["Docker"]="https://www.docker.com"
tool_urls["Python 3"]="https://python.org"
tool_urls["git-sizer"]="https://github.com/github/git-sizer/releases"
tool_urls["gitleaks"]="https://github.com/gitleaks/gitleaks/releases"

tools_list=("GitHub CLI (gh)" "Git" "Docker" "Python 3" "git-sizer" "gitleaks")

for tool in "${tools_list[@]}"; do
    cmd=${tool_commands[$tool]}
    if command -v "$cmd" >/dev/null 2>&1; then
        version=""
        if [ "$cmd" = "gitleaks" ]; then
            version=$(gitleaks version 2>/dev/null || echo "")
        else
            version=$("$cmd" --version 2>/dev/null | head -n 1 || echo "")
        fi
        echo -e "${GREEN}[OK] $tool: $version${NC}"
    else
        echo -e "${RED}[MISSING] $tool${NC}"
        install_cmd=${tool_install_cmds[$tool]}
        if [[ "$install_cmd" == *"Download"* ]]; then
            echo -e "${YELLOW}  Download from: ${tool_urls[$tool]}${NC}"
        else
            echo -e "${YELLOW}  Install: $install_cmd${NC}"
        fi
    fi
done

# --- Python packages ---
echo -e "\n${CYAN}--- Python Packages ---${NC}"
pythonPackages=("git-filter-repo")
for pkg in "${pythonPackages[@]}"; do
    if pip3 show "$pkg" >/dev/null 2>&1 || pip show "$pkg" >/dev/null 2>&1; then
        echo -e "${GREEN}[OK] $pkg${NC}"
    else
        echo -e "${RED}[MISSING] $pkg — Install: pip3 install $pkg${NC}"
    fi
done

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

echo -e "\n${CYAN}Tooling check complete.${NC}"
