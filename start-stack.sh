#!/usr/bin/env bash

set -e

# ============================================================================
# Stack Startup Script
# Starts selected services from n8n-stack via the root docker-compose.yml
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Determine script location and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# If script is in scripts/manage/, go up two levels, otherwise stay in current dir
if [[ "$SCRIPT_DIR" == */scripts/manage ]]; then
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
    PROJECT_ROOT="$SCRIPT_DIR"
fi

# Paths
N8N_DIR="$PROJECT_ROOT/n8n"            # still used for .env pre-load
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"
NETWORK_NAME="n8n-stack-network"

# Docker compose command (will be set by check_docker)
DOCKER_COMPOSE=""

# Global flags
RECREATE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--recreate)
            RECREATE=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# ============================================================================
# Docker Check
# ============================================================================

check_docker() {
    print_header "Docker Check"
    
    # Check if docker command exists
    if ! command -v docker &>/dev/null; then
        print_error "Docker is not installed or not in PATH"
        echo ""
        
        # Detect OS and provide specific instructions
        case "$(uname -s)" in
            Linux*)
                echo "Install Docker on Linux:"
                echo "  curl -fsSL https://get.docker.com | sh"
                echo "  sudo usermod -aG docker \$USER"
                echo ""
                echo "Then logout/login or run: newgrp docker"
                ;;
            Darwin*)
                echo "Install Docker Desktop for macOS:"
                echo "  https://docs.docker.com/desktop/install/mac-install/"
                echo ""
                if command -v brew &>/dev/null; then
                    echo "Or via Homebrew:"
                    echo "  brew install --cask docker"
                else
                    echo "Note: Homebrew is not installed. Install Docker Desktop manually."
                fi
                ;;
            MINGW*|MSYS*|CYGWIN*)
                echo "Install Docker Desktop for Windows:"
                echo "  https://docs.docker.com/desktop/install/windows-install/"
                echo ""
                echo "Make sure WSL2 backend is enabled"
                ;;
            *)
                echo "Install Docker for your system:"
                echo "  https://docs.docker.com/get-docker/"
                ;;
        esac
        
        echo ""
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &>/dev/null; then
        print_error "Docker is installed but not running"
        echo ""
        
        case "$(uname -s)" in
            Linux*)
                echo "Start Docker service:"
                echo "  sudo systemctl start docker"
                echo "  sudo systemctl enable docker"
                ;;
            Darwin*|MINGW*|MSYS*|CYGWIN*)
                echo "Start Docker Desktop application"
                echo ""
                echo "On macOS/Windows, Docker Desktop must be running"
                echo "Look for the Docker icon in your system tray/menu bar"
                ;;
        esac
        
        echo ""
        exit 1
    fi
    
    # Check docker compose
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE="docker compose"
    elif docker-compose version &>/dev/null; then
        print_info "Using legacy docker-compose command"
        DOCKER_COMPOSE="docker-compose"
    else
        print_error "Docker Compose is not available"
        echo ""
        echo "Docker Compose should be included with Docker Desktop"
        echo "If using Linux, install docker-compose-plugin:"
        echo "  sudo apt-get install docker-compose-plugin"
        echo ""
        exit 1
    fi
    
    # Success
    DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
    COMPOSE_VERSION=$($DOCKER_COMPOSE version --short 2>/dev/null || echo "unknown")
    
    print_success "Docker ${DOCKER_VERSION} is running"
    print_success "Docker Compose ${COMPOSE_VERSION} is available"
    echo ""
}

# ============================================================================
 # System Check
# ============================================================================

check_system() {
    print_header "System Check"
    
    # Check RAM
    if [[ "$(uname -s)" == "Linux" ]]; then
        TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
        TOTAL_SWAP=$(free -m | awk '/^Swap:/{print $2}')
        
        print_info "Total RAM: ${TOTAL_RAM}MB"
        print_info "Total Swap: ${TOTAL_SWAP}MB"
        
        if [ "$TOTAL_RAM" -lt 1500 ] && [ "$TOTAL_SWAP" -lt 1024 ]; then
            print_error "LOW MEMORY DETECTED!"
            echo -e "${YELLOW}Your server has less than 1.5GB RAM and very little Swap.${NC}"
            echo -e "${YELLOW}Running the full stack WILL likely cause the server to hang.${NC}"
            echo ""
            echo "Recommendation: Enable at least 2GB of Swap space."
            echo "  sudo fallocate -l 2G /swapfile"
            echo "  sudo chmod 600 /swapfile"
            echo "  sudo mkswap /swapfile"
            echo "  sudo swapon /swapfile"
            echo ""
            read -rp "Continue anyway? [y/N]: " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
}

# ============================================================================
# Port Checking & Firewall Management
# ============================================================================

# Check if a port is in use
is_port_in_use() {
    local port=$1
    if command -v lsof &>/dev/null; then
        lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1
    elif command -v ss &>/dev/null; then
        ss -tuln | grep -q ":$port "
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -q ":$port "
    else
        return 1  # Can't check, assume not in use
    fi
}

# Check if a port is open in firewall
is_port_open_in_firewall() {
    local port=$1
    
    # Only check on Linux
    [[ "$(uname -s)" != "Linux" ]] && return 0
    
    if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        sudo ufw status | grep -qE "^$port(/tcp)?.*ALLOW"
    elif command -v firewall-cmd &>/dev/null; then
        sudo firewall-cmd --query-port=$port/tcp 2>/dev/null
    else
        return 0  # No firewall detected, assume open
    fi
}

# Open port in firewall
open_port_in_firewall() {
    local port=$1
    
    if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        sudo ufw allow $port/tcp
    elif command -v firewall-cmd &>/dev/null; then
        sudo firewall-cmd --permanent --add-port=$port/tcp
        sudo firewall-cmd --reload
    fi
}

# Show instructions for opening ports
show_port_instructions() {
    local ports=("$@")
    local ports_str="${ports[*]}"
    
    echo ""
    print_info "Please open the following ports manually:"
    echo "  Ports: ${ports_str// /, }"
    echo ""
    echo "  UFW (Ubuntu/Debian):"
    for port in "${ports[@]}"; do
        echo "    sudo ufw allow $port/tcp"
    done
    echo ""
    echo "  Firewalld (CentOS/RHEL):"
    for port in "${ports[@]}"; do
        echo "    sudo firewall-cmd --permanent --add-port=$port/tcp"
    done
    echo "    sudo firewall-cmd --reload"
    echo ""
    echo -e "  ${YELLOW}⚠ Don't forget to open ports in your cloud provider's firewall/security group!${NC}"
    echo ""
}

# Main port check function
check_and_open_ports() {
    local ports=("$@")
    local in_use_ports=()
    local closed_ports=()
    
    print_header "Port Check"
    
    # Check for occupied ports
    for port in "${ports[@]}"; do
        if is_port_in_use "$port"; then
            in_use_ports+=($port)
            print_error "Port $port is already in use"
            if command -v lsof &>/dev/null; then
                lsof -i :$port | grep LISTEN | head -3
            fi
        else
            print_success "Port $port is available"
        fi
    done
    
    # If ports are in use, warn user
    if [ ${#in_use_ports[@]} -gt 0 ]; then
        echo ""
        print_error "Some ports are already in use: ${in_use_ports[*]}"
        echo "Services using these ports may fail to start."
        read -rp "Continue anyway? [y/N]: " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            print_error "Operation cancelled by user"
            exit 0
        fi
    fi
    
    # Only check firewall on Linux
    if [[ "$(uname -s)" != "Linux" ]]; then
        print_info "Skipping firewall check (not on Linux)"
        return 0
    fi
    
    # Check firewall
    print_header "Firewall Check"
    
    # Detect firewall type
    local firewall_type=""
    if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        firewall_type="ufw"
        print_info "Detected active firewall: UFW"
    elif command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall_type="firewalld"
        print_info "Detected active firewall: firewalld"
    else
        print_info "No active firewall detected (ufw/firewalld)"
        echo ""
        echo -e "${YELLOW}⚠ Note: If you're on a VPS, check your cloud provider's firewall/security group!${NC}"
        echo "  Required ports: ${ports[*]}"
        echo ""
        return 0
    fi
    
    # Check which ports need to be opened
    for port in "${ports[@]}"; do
        if ! is_port_open_in_firewall "$port"; then
            closed_ports+=($port)
            print_error "Port $port is closed in firewall"
        else
            print_success "Port $port is open in firewall"
        fi
    done
    
    # If no ports need to be opened, we're done
    if [ ${#closed_ports[@]} -eq 0 ]; then
        print_success "All required ports are open"
        return 0
    fi
    
    # Ask user if they want to open ports
    echo ""
    print_info "The following ports need to be opened: ${closed_ports[*]}"
    read -rp "Open these ports automatically? (requires sudo) [Y/n]: " response
    
    if [[ ! "$response" =~ ^[Nn]$ ]]; then
        # Try to open ports
        local failed_ports=()
        for port in "${closed_ports[@]}"; do
            echo -n "Opening port $port... "
            if open_port_in_firewall "$port" 2>/dev/null; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}FAILED${NC}"
                failed_ports+=($port)
            fi
        done
        
        if [ ${#failed_ports[@]} -gt 0 ]; then
            show_port_instructions "${failed_ports[@]}"
        else
            print_success "All ports opened successfully"
            echo ""
            echo -e "${YELLOW}⚠ Remember: Also open these ports in your cloud provider's firewall!${NC}"
        fi
    else
        show_port_instructions "${closed_ports[@]}"
    fi
    
    echo ""
}

# Determine which ports to check based on selected services
get_required_ports() {
    local ports=()
    
    if $START_NPM && ! $START_CLOUDFLARED; then
        # NPM selected - only need 80, 81, 443
        ports=(80 81 443)
    elif $START_CLOUDFLARED; then
        # Cloudflared selected - no ports needed
        ports=()
    elif $START_N8N && ! $START_NPM; then
        # n8n only - need n8n + db ports
        ports=(5678 5432)
    fi
    
    # Remove duplicates
    printf '%s\n' "${ports[@]}" | sort -u | tr '\n' ' '
}

# Create network if it doesn't exist
create_network() {
    print_header "Network Setup"
    
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        print_info "Network '$NETWORK_NAME' already exists"
    else
        print_info "Creating network '$NETWORK_NAME'..."
        docker network create "$NETWORK_NAME"
        print_success "Network created successfully"
    fi
}

# Wait for container to be healthy
wait_for_healthy() {
    local container=$1
    local timeout=${2:-60}
    local elapsed=0
    
    echo -n "Waiting for $container to be healthy..."
    
    while [ $elapsed -lt $timeout ]; do
        status=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "not_found")
        
        if [ "$status" = "healthy" ]; then
            echo ""
            print_success "$container is healthy"
            return 0
        fi
        
        echo -n "."
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    echo ""
    print_error "$container did not become healthy within ${timeout}s"
    return 1
}

# Generate the root compose file based on selected services
generate_compose_file() {
    print_header "Generating Compose File"
    print_info "Updating $COMPOSE_FILE based on selection..."
    
    cat > "$COMPOSE_FILE" << EOF
name: n8n-stack

include:
EOF

    $START_NPM && echo "  - path: ./proxy/npm/docker-compose.yml" >> "$COMPOSE_FILE"
    $START_CLOUDFLARED && echo "  - path: ./proxy/cloudflared/docker-compose.yml" >> "$COMPOSE_FILE"
    $START_N8N && echo "  - path: ./n8n/docker-compose.yml" >> "$COMPOSE_FILE"
    $START_PORTAINER && echo "  - path: ./portainer/docker-compose.yml" >> "$COMPOSE_FILE"

    cat >> "$COMPOSE_FILE" << EOF

networks:
  default:
    name: n8n-stack-network
    external: true
EOF

    print_success "Compose file updated"
}

# Start all included services via the root compose file
start_stack() {
    print_header "Starting Services"
    print_info "Compose file: $COMPOSE_FILE"
    echo ""
    
    cd "$PROJECT_ROOT"
    
    local up_args=""
    if $RECREATE; then
        print_info "--recreate flag set: will force-recreate containers"
        up_args="--force-recreate"
    fi
    
    print_info "Starting containers..."
    $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d $up_args
    
    print_success "Services started successfully"
    echo ""
}

# ============================================================================
# Service Selection - Interactive Menu (whiptail/dialog)
# ============================================================================

select_services_interactive() {
    local cmd=""
    
    # Detect available dialog tool
    if command -v whiptail &>/dev/null; then
        cmd="whiptail"
    elif command -v dialog &>/dev/null; then
        cmd="dialog"
    else
        return 1  # Fall back to simple mode
    fi
    
    # Build checklist
    local options=(
        "n8n" "n8n" OFF
        "npm" "Nginx Proxy Manager" OFF
        "cloudflared" "Cloudflared Tunnel" OFF
        "portainer" "Portainer" OFF
    )
    
    local selected
    if [ "$cmd" = "whiptail" ]; then
        selected=$(whiptail --title "Stack Startup" \
            --checklist "Select services to start (Space to select, Enter to confirm):" \
            20 70 10 \
            "${options[@]}" \
            3>&1 1>&2 2>&3)
    else
        selected=$(dialog --stdout --title "Stack Startup" \
            --checklist "Select services to start (Space to select, Enter to confirm):" \
            20 70 10 \
            "${options[@]}")
    fi
    
    # Check if user cancelled
    if [ $? -ne 0 ]; then
        echo ""
        print_error "Operation cancelled by user"
        exit 0
    fi
    
    # Parse selected services
    START_N8N=false
    START_NPM=false
    START_CLOUDFLARED=false
    START_PORTAINER=false
    
    for service in $selected; do
        case $service in
            \"n8n\"|n8n)
                START_N8N=true
                ;;
            \"npm\"|npm)
                START_NPM=true
                ;;
            \"cloudflared\"|cloudflared)
                START_CLOUDFLARED=true
                ;;
            \"portainer\"|portainer)
                START_PORTAINER=true
                ;;
        esac
    done
}

# ============================================================================
# Service Selection - Simple Mode (yes/no questions)
# ============================================================================

select_services_simple() {
    print_header "Service Selection"
    echo "Answer yes (y) or no (n) for each service:"
    echo ""
    
    START_N8N=false
    read -rp "Start n8n? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        START_N8N=true
    fi
    
    START_NPM=false
    read -rp "Start Nginx Proxy Manager? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        START_NPM=true
    fi
    
    START_CLOUDFLARED=false
    read -rp "Start Cloudflared Tunnel? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        START_CLOUDFLARED=true
    fi
    
    START_PORTAINER=false
    read -rp "Start Portainer? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        START_PORTAINER=true
    fi
    return 0
}


# ============================================================================
# Main Logic
# ============================================================================

main() {
    print_header "n8n Stack Startup Script"
    echo "Project root: $PROJECT_ROOT"
    
    # Step 0: Check Docker
    check_docker
    
    # Step 0.5: Check System
    check_system
    
    # Step 1: Create network
    create_network
    
    # Step 2: Select services
    if ! select_services_interactive; then
        # Fallback to simple mode if whiptail/dialog not available
        print_info "Interactive menu not available, using simple mode"
        select_services_simple
    fi
    
    
    # Step 3: Summary
    print_header "Selected Services"
    echo "The following services will be started:"
    echo ""
    $START_N8N && echo "  • n8n (+ Postgres)"
    $START_NPM && echo "  • Nginx Proxy Manager"
    $START_CLOUDFLARED && echo "  • Cloudflared Tunnel"
    $START_PORTAINER && echo "  • Portainer"
    echo ""
    
    # Check if nothing selected
    if ! $START_N8N && ! $START_NPM && ! $START_CLOUDFLARED && ! $START_PORTAINER; then
        print_error "No services selected. Exiting."
        exit 0
    fi
    
    read -rp "Continue? [Y/n]: " response
    if [[ "$response" =~ ^[Nn]$ ]]; then
        print_error "Operation cancelled by user"
        exit 0
    fi
    
    # Step 3.5: Generate compose file
    generate_compose_file

    # Step 3.6: Pre-pull images (from root compose, it will only pull included services)
    print_header "Image Pre-pull"
    print_info "Pre-pulling images for selected services..."
    # Load n8n env so compose can resolve variables during pull
    if [ -f "$N8N_DIR/.env" ]; then
        set -a; source "$N8N_DIR/.env"; set +a
    fi
    cd "$PROJECT_ROOT"
    $DOCKER_COMPOSE -f "$COMPOSE_FILE" pull -q 2>/dev/null || \
        print_warning "Pre-pull failed or partially skipped (images may already be cached)"

    # Step 4: Check ports and firewall
    REQUIRED_PORTS=$(get_required_ports)
    if [ -n "$REQUIRED_PORTS" ]; then
        # Convert space-separated string to array
        read -ra PORT_ARRAY <<< "$REQUIRED_PORTS"
        check_and_open_ports "${PORT_ARRAY[@]}"
    else
        print_info "Using Cloudflared Tunnel - no port check needed"
    fi

    # Step 5: Load n8n env vars so compose can resolve them, then start everything
    if [ -f "$N8N_DIR/.env" ]; then
        set -a; source "$N8N_DIR/.env"; set +a
    fi

    start_stack

    # Final summary
    print_header "Startup Complete"
    echo "Running containers (n8n-stack):"
    echo ""
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
        | grep -E "(n8n|npm|cloudflared|portainer)" \
        || print_info "No containers found"
    echo ""
    print_success "All selected services started successfully!"
    print_info "Tip: Stop the full stack any time with:  docker compose -f $COMPOSE_FILE down"
    echo ""
}

# Run main function
main