#!/bin/bash

# Docker Manager - For Frappe/ERPNext Minimal Setup
# This script manages containers created by generate_frappe_docker.sh

# Color definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect preferred docker compose command
detect_docker_compose() {
    # Try docker compose (v2) first - preferred method
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
        return 0
    # Fallback to docker-compose (v1) if v2 is not available
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
        return 0
    else
        echo -e "${RED}Error: Neither 'docker compose' nor 'docker-compose' is available${NC}" >&2
        return 1
    fi
}

# Function to print header
print_header() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                Docker Manager v1.0                          ║${NC}"
    echo -e "${BLUE}║         Frappe/ERPNext Minimal Setup                        ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Function to check if Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker is not running or you don't have permission to access it${NC}"
        echo "Please start Docker and try again."
        exit 1
    fi
}

# Function to find Frappe sites by running containers
find_frappe_sites() {
    local sites=()
    # Use docker ps to find containers and extract project names
    local project_names=$(docker ps -a --format '{{.Names}}' | awk -F'-' '{print $1}' | sort | uniq)
    
    for project in $project_names; do
        # Check if this project has Frappe-related containers
        if docker ps -a --format '{{.Names}}' | grep -q "^${project}-"; then
            sites+=("$project")
        fi
    done
    
    echo "${sites[@]}"
}

# Function to show running containers
show_running_containers() {
    echo -e "${CYAN}📋 Currently Running Frappe Containers:${NC}"
    echo ""
    
    local sites=($(find_frappe_sites))
    if [[ ${#sites[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No Frappe sites found in running containers${NC}"
        return
    fi
    
    for site in "${sites[@]}"; do
        echo -e "${BLUE}🏠 Site: ${site}${NC}"
        
        # Show containers for this site
        local site_containers=$(docker ps --filter "name=^${site}-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}")
        if [[ -n "$site_containers" ]]; then
            echo "$site_containers" | grep -v "NAME"
        else
            echo -e "${YELLOW}  No containers running${NC}"
        fi
        echo ""
    done
}

# Function to access container shell
access_container() {
    local site_name=$1
    local access_type=$2
    
    case $access_type in
        "normal")
            echo -e "${GREEN}🔧 Accessing $site_name-app container as frappe user...${NC}"
            docker exec -it "$site_name-app" bash
            ;;
        "root")
            echo -e "${GREEN}🔧 Accessing $site_name-app container as root user...${NC}"
            docker exec -it --user root "$site_name-app" bash
            ;;
        *)
            echo -e "${RED}❌ Invalid access type${NC}"
            return 1
            ;;
    esac
}

# Function to manage Frappe processes via Supervisor
manage_frappe_processes() {
    local site_name=$1
    local action=$2
    local process=$3
    
    case $action in
        "status")
            echo -e "${CYAN}📊 Frappe Process Status for $site_name:${NC}"
            docker exec "$site_name-app" /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf status
            ;;
        "restart")
            if [[ -n "$process" ]]; then
                echo -e "${GREEN}🔄 Restarting $process process in $site_name...${NC}"
                docker exec "$site_name-app" /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf restart "$process"
            else
                echo -e "${GREEN}🔄 Restarting all Frappe processes in $site_name...${NC}"
                docker exec "$site_name-app" /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf restart all
            fi
            ;;
        "stop")
            if [[ -n "$process" ]]; then
                echo -e "${YELLOW}⏹️  Stopping $process process in $site_name...${NC}"
                docker exec "$site_name-app" /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf stop "$process"
            else
                echo -e "${YELLOW}⏹️  Stopping all Frappe processes in $site_name...${NC}"
                docker exec "$site_name-app" /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf stop all
            fi
            ;;
        "start")
            if [[ -n "$process" ]]; then
                echo -e "${GREEN}▶️  Starting $process process in $site_name...${NC}"
                docker exec "$site_name-app" /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf start "$process"
            else
                echo -e "${GREEN}▶️  Starting all Frappe processes in $site_name...${NC}"
                docker exec "$site_name-app" /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf start all
            fi
            ;;
        *)
            echo -e "${RED}❌ Invalid action${NC}"
            return 1
            ;;
    esac
}

# Function to view logs
view_logs() {
    local site_name=$1
    local log_type=$2
    
    case $log_type in
        "web")
            echo -e "${CYAN}📋 Viewing Frappe Web logs for $site_name...${NC}"
            docker exec "$site_name-app" tail -f /home/frappe/supervisor/logs/frappe-web.log
            ;;
        "worker")
            echo -e "${CYAN}📋 Viewing Frappe Worker logs for $site_name...${NC}"
            docker exec "$site_name-app" tail -f /home/frappe/supervisor/logs/frappe-worker-default.log
            ;;
        "schedule")
            echo -e "${CYAN}📋 Viewing Frappe Schedule logs for $site_name...${NC}"
            docker exec "$site_name-app" tail -f /home/frappe/supervisor/logs/frappe-schedule.log
            ;;
        "websocket")
            echo -e "${CYAN}📋 Viewing Frappe WebSocket logs for $site_name...${NC}"
            docker exec "$site_name-app" tail -f /home/frappe/supervisor/logs/frappe-websocket.log
            ;;
        "supervisor")
            echo -e "${CYAN}📋 Viewing Supervisor logs for $site_name...${NC}"
            docker exec "$site_name-app" tail -f /home/frappe/supervisor/logs/supervisord.log
            ;;
        "container")
            echo -e "${CYAN}📋 Viewing container logs for $site_name...${NC}"
            docker logs -f "$site_name-app"
            ;;
        "create-site")
            echo -e "${CYAN}📋 Viewing Create-Site logs for $site_name...${NC}"
            docker logs -f "$site_name-create-site"
            ;;
        *)
            echo -e "${RED}❌ Invalid log type${NC}"
            return 1
            ;;
    esac
}

# Function to manage containers
manage_containers() {
    local site_name=$1
    local action=$2
    
    case $action in
        "start")
            echo -e "${GREEN}🚀 Starting containers for $site_name...${NC}"
            docker start $(docker ps -a --filter "name=^${site_name}-" --format "{{.Names}}")
            ;;
        "stop")
            echo -e "${YELLOW}⏹️  Stopping containers for $site_name...${NC}"
            docker stop $(docker ps --filter "name=^${site_name}-" --format "{{.Names}}")
            ;;
        "restart")
            echo -e "${GREEN}🔄 Restarting containers for $site_name...${NC}"
            docker restart $(docker ps --filter "name=^${site_name}-" --format "{{.Names}}")
            ;;
        "rebuild")
            echo -e "${CYAN}🔨 Rebuilding containers for $site_name...${NC}"
            # Find docker-compose file if it exists
            if [[ -f "${site_name}-docker-compose.yml" ]]; then
                DOCKER_COMPOSE_CMD=$(detect_docker_compose)
                if [ $? -ne 0 ]; then
                    echo -e "${RED}❌ Failed to detect docker compose command${NC}"
                    return 1
                fi
                $DOCKER_COMPOSE_CMD -f "${site_name}-docker-compose.yml" down
                
                # Update docker-compose file to add restart policy
                echo -e "${BLUE}📝 Adding auto-restart policy to containers...${NC}"
                sed -i 's/\(^\s*\)\(container_name:\)/\1restart: always\n\1\2/g' "${site_name}-docker-compose.yml"
                
                $DOCKER_COMPOSE_CMD -f "${site_name}-docker-compose.yml" up -d --build
            else
                echo -e "${YELLOW}⚠️  No docker-compose file found for $site_name${NC}"
                echo "Containers will be restarted instead."
                docker restart $(docker ps --filter "name=^${site_name}-" --format "{{.Names}}")
            fi
            ;;
        "rebuild-with-apps")
            echo -e "${CYAN}🔨 Rebuilding containers with custom apps preservation for $site_name...${NC}"
            rebuild_with_custom_apps "$site_name"
            ;;
        "logs")
            echo -e "${CYAN}📋 Showing logs for $site_name...${NC}"
            docker logs $(docker ps --filter "name=^${site_name}-" --format "{{.Names}}")
            ;;
        "status")
            echo -e "${CYAN}📊 Container status for $site_name:${NC}"
            docker ps --filter "name=^${site_name}-"
            ;;
        *)
            echo -e "${RED}❌ Invalid action${NC}"
            return 1
            ;;
    esac
}

# Function to remove all containers for a site
remove_all_containers() {
    local site_name=$1
    
    echo -e "${RED}⚠️  WARNING: This will remove ALL containers for site: $site_name${NC}"
    echo -e "${YELLOW}This action cannot be undone!${NC}"
    echo ""
    
    # Show what will be removed
    echo -e "${CYAN}Containers that will be removed:${NC}"
    docker ps -a --filter "name=^${site_name}-" --format "table {{.Names}}\t{{.Status}}"
    echo ""
    
    # Show volumes that will be removed
    echo -e "${CYAN}Docker volumes that will be removed:${NC}"
    local volumes=$(docker volume ls --filter "name=${site_name}" --format "{{.Name}}")
    if [ ! -z "$volumes" ]; then
        echo "$volumes" | while read volume; do
            echo -e "   📦 $volume"
        done
    else
        echo -e "   ${YELLOW}No volumes found${NC}"
    fi
    echo ""
    
    # Show networks that will be removed
    echo -e "${CYAN}Docker networks that will be removed:${NC}"
    local networks=$(docker network ls --filter "name=${site_name}" --format "{{.Name}}")
    if [ ! -z "$networks" ]; then
        echo "$networks" | while read network; do
            echo -e "   🌐 $network"
        done
    else
        echo -e "   ${YELLOW}No networks found${NC}"
    fi
    echo ""
    
    # Show folders that will be removed
    echo -e "${CYAN}Folders that will be removed:${NC}"
    local site_folder="${site_name}"
    local vscode_folder=""
    
    # Determine VS Code folder path
    ACTUAL_USER_HOME=$(eval echo ~$SUDO_USER)
    if [ -z "$ACTUAL_USER_HOME" ] || [ "$ACTUAL_USER_HOME" = "~$SUDO_USER" ]; then
        ACTUAL_USER_HOME="$HOME"
    fi
    vscode_folder="${ACTUAL_USER_HOME}/frappe-docker/${site_name}-frappe-bench"
    
    if [[ -d "$site_folder" ]]; then
        echo -e "   📁 Site folder: ${site_folder}"
    fi
    if [[ -d "$vscode_folder" ]]; then
        echo -e "   💻 VS Code folder: ${vscode_folder}"
    fi
    echo ""
    
    read -p "⚠️  Are you absolutely sure you want to remove ALL containers? (y/n): " confirm1
    if [[ ! "$confirm1" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        return 0
    fi
    
    read -p "⚠️  FINAL CONFIRMATION: Type 'DELETE' to confirm removal: " confirm2
    if [[ "$confirm2" != "DELETE" ]]; then
        echo -e "${YELLOW}Removal cancelled - incorrect confirmation.${NC}"
        return 0
    fi
    
    echo -e "${RED}🗑️  Removing all containers for $site_name...${NC}"
    
    # Stop and remove containers
    docker stop $(docker ps --filter "name=^${site_name}-" --format "{{.Names}}") 2>/dev/null
    docker rm $(docker ps -a --filter "name=^${site_name}-" --format "{{.Names}}") 2>/dev/null
    
    echo -e "${GREEN}✅ All containers removed successfully!${NC}"
    
    # Remove associated volumes
    echo -e "${BLUE}🗑️  Removing Docker volumes for $site_name...${NC}"
    local volumes=$(docker volume ls --filter "name=${site_name}" --format "{{.Name}}")
    if [ ! -z "$volumes" ]; then
        echo "$volumes" | while read volume; do
            echo -e "   Removing volume: $volume"
            docker volume rm "$volume" 2>/dev/null || echo -e "   ${YELLOW}⚠️  Warning: Could not remove volume $volume (may be in use)${NC}"
        done
        echo -e "${GREEN}✅ Docker volumes removed successfully!${NC}"
    else
        echo -e "${YELLOW}No volumes found for $site_name${NC}"
    fi
    
    # Remove associated networks
    echo -e "${BLUE}🗑️  Removing Docker networks for $site_name...${NC}"
    local networks=$(docker network ls --filter "name=${site_name}" --format "{{.Name}}")
    if [ ! -z "$networks" ]; then
        echo "$networks" | while read network; do
            # Skip default networks
            if [[ "$network" != "bridge" && "$network" != "host" && "$network" != "none" ]]; then
                echo -e "   Removing network: $network"
                docker network rm "$network" 2>/dev/null || echo -e "   ${YELLOW}⚠️  Warning: Could not remove network $network (may be in use)${NC}"
            fi
        done
        echo -e "${GREEN}✅ Docker networks removed successfully!${NC}"
    else
        echo -e "${YELLOW}No networks found for $site_name${NC}"
    fi
    
    # Remove site folder
    if [[ -d "$site_folder" ]]; then
        echo -e "${BLUE}🗑️  Removing site folder: $site_folder${NC}"
        rm -rf "$site_folder"
        echo -e "${GREEN}✅ Site folder removed successfully!${NC}"
    fi
    
    # Remove VS Code development folder
    if [[ -d "$vscode_folder" ]]; then
        echo -e "${BLUE}🗑️  Removing VS Code folder: $vscode_folder${NC}"
        rm -rf "$vscode_folder"
        echo -e "${GREEN}✅ VS Code folder removed successfully!${NC}"
    fi
    
    # Remove from hosts file if it exists
    local site_domain="${site_name//_/.}"
    if grep -q "$site_domain" /etc/hosts 2>/dev/null; then
        echo -e "${BLUE}🗑️  Removing $site_domain from hosts file${NC}"
        sudo sed -i "/$site_domain/d" /etc/hosts
        echo -e "${GREEN}✅ Hosts file entry removed successfully!${NC}"
    fi
    
    echo -e "${GREEN}🎉 Complete cleanup completed for $site_name!${NC}"
    
    # Automatic cleanup - always yes, always aggressive
    echo ""
    echo -e "${BLUE}🧹 Cleaning up unused Docker resources (volumes, images, containers)...${NC}"
    docker system prune -a --volumes -f
    echo -e "${GREEN}✅ Docker cleanup completed!${NC}"
    echo ""
    echo -e "${GREEN}📊 Updated Docker Space Usage:${NC}"
    docker system df
}

# Function to access specific container as root
access_specific_container_root() {
    local site_name=$1
    
    echo -e "${CYAN}📋 Available containers for $site_name:${NC}"
    docker ps --filter "name=^${site_name}-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    
    read -p "Enter container name to access as root: " container_name
    if [[ -z "$container_name" ]]; then
        echo -e "${YELLOW}No container name provided.${NC}"
        return 1
    fi
    
    # Check if container exists and is running
    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        echo -e "${RED}❌ Container $container_name not found or not running.${NC}"
        return 1
    fi
    
    echo -e "${GREEN}🔧 Accessing $container_name as root user...${NC}"
    docker exec -it --user root "$container_name" bash
}

# Function to transfer files
transfer_files() {
    local site_name=$1
    
    echo -e "${YELLOW}📁 File Transfer Options:${NC}"
    echo "1. Copy file TO container"
    echo "2. Copy file FROM container"
    read -p "Select transfer direction (1-2): " direction
    
    case $direction in
        1)
            # Copy TO container
            read -p "Enter source file path (on host): " source_path
            if [[ ! -f "$source_path" ]]; then
                echo -e "${RED}❌ Source file does not exist: $source_path${NC}"
                return 1
            fi
            
            echo -e "${CYAN}📋 Available containers for $site_name:${NC}"
            docker ps --filter "name=^${site_name}-" --format "table {{.Names}}\t{{.Status}}"
            read -p "Enter target container name: " container_name
            dest_path="/home/frappe/frappe-bench/"
            
            echo -e "${GREEN}📤 Copying file TO container...${NC}"
            echo "Source: $source_path"
            echo "Destination: $container_name:$dest_path"
            
            if docker cp "$source_path" "$container_name:$dest_path"; then
                echo -e "${GREEN}✅ File copied successfully!${NC}"
            else
                echo -e "${RED}❌ Failed to copy file to container.${NC}"
            fi
            ;;
        2)
            # Copy FROM container
            echo -e "${CYAN}📋 Available containers for $site_name:${NC}"
            docker ps --filter "name=^${site_name}-" --format "table {{.Names}}\t{{.Status}}"
            read -p "Enter source container name: " container_name
            read -p "Enter source file path in container: " source_path
            read -p "Enter destination path on host: " dest_path
            
            echo -e "${GREEN}📥 Copying file FROM container...${NC}"
            echo "Source: $container_name:$source_path"
            echo "Destination: $dest_path"
            
            if docker cp "$container_name:$source_path" "$dest_path"; then
                echo -e "${GREEN}✅ File copied successfully!${NC}"
            else
                echo -e "${RED}❌ Failed to copy file from container.${NC}"
            fi
            ;;
        *)
            echo -e "${RED}❌ Invalid option. Please choose 1 or 2.${NC}"
            ;;
    esac
}

# Function to install packages
install_packages() {
    local site_name=$1
    
    echo -e "${CYAN}📦 Smart Package Installation for $site_name${NC}"
    echo ""
    
    # Show available containers
    echo -e "${YELLOW}📋 Available containers:${NC}"
    docker ps --filter "name=^${site_name}-" --format "table {{.Names}}\t{{.Status}}"
    echo ""
    
    # Select container
    read -p "Enter container name to install packages in: " container_name
    if [[ -z "$container_name" ]]; then
        echo -e "${YELLOW}No container name provided.${NC}"
        return 1
    fi
    
    # Check if container exists and is running
    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        echo -e "${RED}❌ Container $container_name not found or not running.${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${GREEN}🎯 Installing packages in: $container_name${NC}"
    echo ""
    
    # Smart package installation
    echo -e "${CYAN}📦 Smart Package Installation${NC}"
    echo ""
    echo -e "${BLUE}💡 Enter packages to install (space-separated)${NC}"
    echo -e "${BLUE}   Examples: nano, nano vim curl, or press Enter for common tools${NC}"
    echo ""
    
    read -p "Enter packages (or press Enter for common tools): " packages
    
    if [[ -z "$packages" ]]; then
        # Install common development tools
        echo -e "${GREEN}📦 Installing common development tools...${NC}"
        echo "Installing: nano vim curl wget git htop tree net-tools"
        docker exec -it --user root "$container_name" bash -c "apt-get update && apt-get install nano vim curl wget git htop tree net-tools -y"
        echo -e "${GREEN}✅ Development tools installation completed!${NC}"
    else
        # Install user-specified packages
        echo -e "${GREEN}📦 Installing packages: $packages${NC}"
        docker exec -it --user root "$container_name" bash -c "apt-get update && apt-get install $packages -y"
        echo -e "${GREEN}✅ Package installation completed!${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}🎉 Package installation process completed!${NC}"
    echo -e "${BLUE}💡 You can now use the installed packages in your container.${NC}"
}

# Function to show main menu
show_main_menu() {
    echo -e "${CYAN}📋 Available Actions:${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} Show running containers"
    echo -e "${GREEN}2.${NC} Access container shell (normal user)"
    echo -e "${GREEN}3.${NC} Access container shell (root user)"
    echo -e "${GREEN}4.${NC} Manage Frappe processes"
    echo -e "${GREEN}5.${NC} View logs"
    echo -e "${GREEN}6.${NC} Manage containers"
    echo -e "${GREEN}7.${NC} Show site information"
    echo -e "${GREEN}8.${NC} Access specific container as root"
    echo -e "${GREEN}9.${NC} File Transfer"
    echo -e "${GREEN}10.${NC} Install Packages"
    echo -e "${GREEN}11.${NC} View Create-Site logs"
    echo -e "${GREEN}12.${NC} Fix Restart Policies"
    echo -e "${GREEN}13.${NC} Exit"
    echo ""
}

# Function to show Frappe process management menu
show_process_menu() {
    echo -e "${CYAN}🔄 Frappe Process Management:${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} Show process status"
    echo -e "${GREEN}2.${NC} Restart all processes"
    echo -e "${GREEN}3.${NC} Restart specific process"
    echo -e "${GREEN}4.${NC} Stop all processes"
    echo -e "${GREEN}5.${NC} Start all processes"
    echo -e "${GREEN}6.${NC} Back to main menu"
    echo ""
}

# Function to show log menu
show_log_menu() {
    echo -e "${CYAN}📋 Log Viewing Options:${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} Frappe Web logs"
    echo -e "${GREEN}2.${NC} Frappe Worker logs"
    echo -e "${GREEN}3.${NC} Frappe Schedule logs"
    echo -e "${GREEN}4.${NC} Frappe WebSocket logs"
    echo -e "${GREEN}5.${NC} Supervisor logs"
    echo -e "${GREEN}6.${NC} Container logs"
    echo -e "${GREEN}7.${NC} Create-Site logs"
    echo -e "${GREEN}8.${NC} Back to main menu"
    echo ""
}

# Function to show container management menu
show_container_menu() {
    echo -e "${CYAN}🐳 Container Management:${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} Start containers"
    echo -e "${GREEN}2.${NC} Stop containers"
    echo -e "${GREEN}3.${NC} Restart containers"
    echo -e "${GREEN}4.${NC} Rebuild containers"
    echo -e "${GREEN}5.${NC} Rebuild with custom apps preservation"
    echo -e "${GREEN}6.${NC} Show container logs"
    echo -e "${GREEN}7.${NC} Show container status"
    echo -e "${GREEN}8.${NC} Complete site removal (containers + folders + hosts)"
    echo -e "${GREEN}9.${NC} Back to main menu"
    echo ""
}

# Function to show site information
show_site_info() {
    local sites=($(find_frappe_sites))
    if [[ ${#sites[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No Frappe sites found in running containers${NC}"
        return
    fi
    
    echo -e "${CYAN}🏠 Frappe Sites Information:${NC}"
    echo ""
    
    for site in "${sites[@]}"; do
        echo -e "${BLUE}📁 Site: ${site}${NC}"
        
        # Check if containers are running
        local running=$(docker ps --filter "name=^${site}-" --format "{{.Names}}" | wc -l)
        if [[ $running -gt 0 ]]; then
            echo -e "   🟢 Status: ${GREEN}Running ($running containers)${NC}"
        else
            echo -e "   🔴 Status: ${RED}Stopped${NC}"
        fi
        
        # Show container details
        echo -e "   📋 Containers:"
        docker ps --filter "name=^${site}-" --format "   {{.Names}} - {{.Status}}"
        
        echo ""
    done
}

# Global variable to store the selected site name
SELECTED_SITE=""

# Main function
main() {
    print_header
    
    # Check if Docker is running
    check_docker
    
    # Check if we have any Frappe sites running
    local sites=($(find_frappe_sites))
    if [[ ${#sites[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠️  No Frappe sites found in running containers${NC}"
        echo "Please start your Frappe containers first."
        echo "Or run generate_frappe_docker.sh to create a site."
        exit 1
    fi
    
    echo -e "${GREEN}✅ Found ${#sites[@]} Frappe site(s):${NC}"
    for site in "${sites[@]}"; do
        echo -e "   • ${site}"
    done
    echo ""
    
    # Select site once at the beginning if multiple sites are available
    if [[ ${#sites[@]} -gt 1 ]]; then
        echo -e "${CYAN}Select a site to work with:${NC}"
        select SELECTED_SITE in "${sites[@]}"; do
            if [[ -n "$SELECTED_SITE" ]]; then
                echo -e "${GREEN}✅ Selected site: $SELECTED_SITE${NC}"
                break
            fi
        done
        echo ""
    else
        SELECTED_SITE="${sites[0]}"
        echo -e "${GREEN}✅ Working with site: $SELECTED_SITE${NC}"
        echo ""
    fi
    
    while true; do
        show_main_menu
        
        read -p "Select an option (1-13): " choice
        
        case $choice in
            1)
                show_running_containers
                ;;
            2)
                access_container "$SELECTED_SITE" "normal"
                ;;
            3)
                access_container "$SELECTED_SITE" "root"
                ;;
            4)
                manage_frappe_processes_menu "$SELECTED_SITE"
                ;;
            5)
                view_logs_menu "$SELECTED_SITE"
                ;;
            6)
                manage_containers_menu "$SELECTED_SITE"
                ;;
            7)
                show_site_info
                ;;
            8)
                access_specific_container_root "$SELECTED_SITE"
                ;;
            9)
                transfer_files "$SELECTED_SITE"
                ;;
            10)
                install_packages "$SELECTED_SITE"
                ;;
            11)
                view_logs "$SELECTED_SITE" "create-site"
                ;;
            12)
                echo -e "${BLUE}🔧 Fix Restart Policies${NC}"
                echo "This will fix restart policies for all Frappe containers to auto-start after reboot."
                read -p "Continue? (y/n): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    for site in $(docker ps -a --format "{{.Names}}" | grep -E ".*-(db|redis|app)$" | sed "s/-(db\|redis\|app)$//" | sort -u); do
                        echo -e "${BLUE}Fixing $site containers...${NC}"
                        for container in ${site}-db ${site}-redis ${site}-app; do
                            if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
                                current_policy=$(docker inspect "$container" --format="{{.HostConfig.RestartPolicy.Name}}" 2>/dev/null || echo "unknown")
                                if [[ "$current_policy" != "unless-stopped" ]]; then
                                    echo "  Updating $container restart policy..."
                                    docker update --restart=unless-stopped "$container"
                                fi
                                if [[ "$(docker inspect "$container" --format="{{.State.Status}}")" != "running" ]]; then
                                    echo "  Starting $container..."
                                    docker start "$container"
                                fi
                            fi
                        done
                    done
                    echo -e "${GREEN}✅ Restart policies fixed! Containers will now start automatically after PC restart.${NC}"
                else
                    echo "Operation cancelled."
                fi
                ;;
            13)
                echo -e "${GREEN}👋 Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Invalid option. Please try again.${NC}"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
        echo ""
    done
}

# Function to handle Frappe process management menu
manage_frappe_processes_menu() {
    local site_name=$1
    
    while true; do
        show_process_menu
        
        read -p "Select an option (1-6): " choice
        
        case $choice in
            1)
                manage_frappe_processes "$site_name" "status"
                ;;
            2)
                manage_frappe_processes "$site_name" "restart"
                ;;
            3)
                echo -e "${CYAN}Available processes:${NC}"
                echo "frappe-web, frappe-schedule, frappe-worker-short, frappe-worker-long, frappe-worker-default, frappe-websocket"
                read -p "Enter process name: " process_name
                if [[ -n "$process_name" ]]; then
                    manage_frappe_processes "$site_name" "restart" "$process_name"
                fi
                ;;
            4)
                manage_frappe_processes "$site_name" "stop"
                ;;
            5)
                manage_frappe_processes "$site_name" "start"
                ;;
            6)
                break
                ;;
            *)
                echo -e "${RED}❌ Invalid option. Please try again.${NC}"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
        echo ""
    done
}

# Function to rebuild with custom apps preservation
rebuild_with_custom_apps() {
    local site_name=$1
    local container_name="${site_name}-app"
    
    echo -e "${BLUE}📦 Backing up custom apps for ${site_name}...${NC}"
    
    # Check if container exists and is running
    if ! docker ps | grep -q "${container_name}"; then
        echo -e "${YELLOW}⚠️  Container ${container_name} is not running. Cannot backup custom apps.${NC}"
        return 1
    fi
    
    # Create backup directory
    local backup_dir="/tmp/frappe_custom_apps_backup_${site_name}"
    mkdir -p "$backup_dir"
    
    # Extract custom apps (excluding frappe and erpnext)
    local custom_apps=$(docker exec "${container_name}" bash -c "cd /home/frappe/frappe-bench && cat sites/apps.json | jq -r 'keys[]' | grep -v '^frappe$' | grep -v '^erpnext$'" 2>/dev/null)
    
    if [ -n "$custom_apps" ]; then
        echo "$custom_apps" > "${backup_dir}/custom_apps.txt"
        echo -e "${GREEN}✅ Custom apps backed up: $(echo "$custom_apps" | tr '\n' ' ')${NC}"
    else
        echo -e "${YELLOW}ℹ️  No custom apps found to backup${NC}"
        rm -rf "$backup_dir"
        return 0
    fi
    
    # Stop containers
    echo -e "${BLUE}🛑 Stopping containers...${NC}"
    DOCKER_COMPOSE_CMD=$(detect_docker_compose)
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to detect docker compose command${NC}"
        return 1
    fi
    $DOCKER_COMPOSE_CMD -f "${site_name}/${site_name}-docker-compose.yml" down
    
    # Update docker-compose file to add restart policy
    echo -e "${BLUE}📝 Adding auto-restart policy to containers...${NC}"
    sed -i 's/\(^\s*\)\(container_name:\)/\1restart: always\n\1\2/g' "${site_name}/${site_name}-docker-compose.yml"
    
    # Start containers (without regenerating docker-compose)
    echo -e "${BLUE}🔄 Starting containers...${NC}"
    $DOCKER_COMPOSE_CMD -f "${site_name}/${site_name}-docker-compose.yml" up -d
    
    # Wait for containers to be ready
    echo -e "${BLUE}⏳ Waiting for containers to be ready...${NC}"
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if docker exec "${container_name}" bash -c "cd /home/frappe/frappe-bench && bench --version" >/dev/null 2>&1; then
            echo -e "${BLUE}🔧 Fix Restart Policies${NC}"
                echo "This will fix restart policies for all Frappe containers to auto-start after reboot."
                read -p "Continue? (y/n): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    for site in $(docker ps -a --format "{{.Names}}" | grep -E ".*-(db|redis|app)$" | sed "s/-(db\|redis\|app)$//" | sort -u); do
                        echo -e "${BLUE}Fixing $site containers...${NC}"
                        for container in ${site}-db ${site}-redis ${site}-app; do
                            if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
                                current_policy=$(docker inspect "$container" --format="{{.HostConfig.RestartPolicy.Name}}" 2>/dev/null || echo "unknown")
                                if [[ "$current_policy" != "unless-stopped" ]]; then
                                    echo "  Updating $container restart policy..."
                                    docker update --restart=unless-stopped "$container"
                                fi
                                if [[ "$(docker inspect "$container" --format="{{.State.Status}}")" != "running" ]]; then
                                    echo "  Starting $container..."
                                    docker start "$container"
                                fi
                            fi
                        done
                    done
                    echo -e "${GREEN}✅ Restart policies fixed! Containers will now start automatically after PC restart.${NC}"
                else
                    echo "Operation cancelled."
                fi
            break
        fi
        echo -e "${YELLOW}   Attempt $((attempt + 1))/$max_attempts - Container not ready yet...${NC}"
        sleep 10
        ((attempt++))
    done
    
    if [ $attempt -eq $max_attempts ]; then
        echo -e "${RED}❌ Container ${container_name} did not become ready in time${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Container is ready!${NC}"
    
    # Reinstall custom apps
    local custom_apps=$(cat "${backup_dir}/custom_apps.txt")
    for app in $custom_apps; do
        echo -e "${BLUE}📦 Reinstalling ${app}...${NC}"
        
        # Get app from git repository
        docker exec "${container_name}" bash -c "cd /home/frappe/frappe-bench && bench get-app ${app}" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ ${app} downloaded successfully${NC}"
            
            # Install app on the site
            docker exec "${container_name}" bash -c "cd /home/frappe/frappe-bench && bench --site ${site_name} install-app ${app}" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ ${app} installed on site successfully${NC}"
            else
                echo -e "${YELLOW}⚠️  ${app} installation on site failed (may already be installed)${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️  ${app} download failed (may already exist)${NC}"
        fi
    done
    
    # Update apps.txt
    docker exec "${container_name}" bash -c "cd /home/frappe/frappe-bench && ls -1 apps > sites/apps.txt"
    echo -e "${GREEN}✅ apps.txt updated with all installed apps${NC}"
    
    # Clean up backup
    rm -rf "$backup_dir"
    echo -e "${GREEN}✅ Backup cleaned up${NC}"
    echo -e "${GREEN}🎉 Rebuild with custom apps preservation completed!${NC}"
}

# Function to handle log viewing menu
view_logs_menu() {
    local site_name=$1
    
    while true; do
        show_log_menu
        
        read -p "Select an option (1-8): " choice
        
        case $choice in
            1)
                view_logs "$site_name" "web"
                ;;
            2)
                view_logs "$site_name" "worker"
                ;;
            3)
                view_logs "$site_name" "schedule"
                ;;
            4)
                view_logs "$site_name" "websocket"
                ;;
            5)
                view_logs "$site_name" "supervisor"
                ;;
            6)
                view_logs "$site_name" "container"
                ;;
            7)
                view_logs "$site_name" "create-site"
                ;;
            8)
                break
                ;;
            *)
                echo -e "${RED}❌ Invalid option. Please try again.${NC}"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
        echo ""
    done
}

# Function to handle container management menu
manage_containers_menu() {
    local site_name=$1
    
    while true; do
        show_container_menu
        
        read -p "Select an option (1-9): " choice
        
        case $choice in
            1)
                manage_containers "$site_name" "start"
                ;;
            2)
                manage_containers "$site_name" "stop"
                ;;
            3)
                manage_containers "$site_name" "restart"
                ;;
            4)
                manage_containers "$site_name" "rebuild"
                ;;
            5)
                manage_containers "$site_name" "rebuild-with-apps"
                ;;
            6)
                manage_containers "$site_name" "logs"
                ;;
            7)
                manage_containers "$site_name" "status"
                ;;
            8)
                remove_all_containers "$site_name"
                ;;
            9)
                break
                ;;
            *)
                echo -e "${RED}❌ Invalid option. Please try again.${NC}"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
        echo ""
    done
}

# Check if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi