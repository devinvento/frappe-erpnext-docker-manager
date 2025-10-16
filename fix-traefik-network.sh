#!/bin/bash

# Manual fix for broken traefik_proxy network
# Run this ONLY if you have network issues with existing sites

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  WARNING: This will temporarily disconnect all sites  ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}This script will:${NC}"
echo "  1. Store all running containers"
echo "  2. Disconnect all containers from traefik_proxy"
echo "  3. Remove and recreate the network"
echo "  4. Reconnect all containers"
echo ""
echo -e "${YELLOW}Your sites will be down for ~30 seconds during this process.${NC}"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo -e "${BLUE}Aborted. No changes made.${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}Starting network fix...${NC}"
echo ""

# Store all running containers
echo -e "${YELLOW}📋 Storing running container list...${NC}"
RUNNING_CONTAINERS=$(docker ps --format "{{.Names}}")
if [ -z "$RUNNING_CONTAINERS" ]; then
    echo -e "${BLUE}No running containers found.${NC}"
else
    echo -e "${GREEN}Found running containers:${NC}"
    echo "$RUNNING_CONTAINERS" | while read container; do
        echo "  - $container"
    done
fi
echo ""

# Check if network exists
if ! docker network ls | grep -q traefik_proxy; then
    echo -e "${YELLOW}⚠️  traefik_proxy network doesn't exist. Creating it...${NC}"
    docker network create traefik_proxy --driver bridge
    echo -e "${GREEN}✅ Network created successfully${NC}"
    exit 0
fi

# Disconnect all containers
echo -e "${YELLOW}🔌 Disconnecting all containers from traefik_proxy...${NC}"
CONNECTED_CONTAINERS=$(docker network inspect traefik_proxy -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)
for container in $CONNECTED_CONTAINERS; do
    echo "  Disconnecting: $container"
    docker network disconnect -f traefik_proxy "$container" 2>/dev/null
done
echo -e "${GREEN}✅ All containers disconnected${NC}"
echo ""

# Remove old network
echo -e "${YELLOW}🗑️  Removing old traefik_proxy network...${NC}"
docker network rm traefik_proxy 2>/dev/null
docker network prune -f >/dev/null 2>&1
echo -e "${GREEN}✅ Old network removed${NC}"
echo ""

# Create new network
echo -e "${YELLOW}🆕 Creating fresh traefik_proxy network...${NC}"
docker network create traefik_proxy --driver bridge
echo -e "${GREEN}✅ New network created${NC}"
echo ""

# Reconnect all containers
if [ -n "$RUNNING_CONTAINERS" ]; then
    echo -e "${YELLOW}🔄 Reconnecting all containers...${NC}"
    for container in $RUNNING_CONTAINERS; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            echo "  Reconnecting: $container"
            if docker network connect traefik_proxy "$container" 2>/dev/null; then
                echo -e "    ${GREEN}✅ Success${NC}"
            else
                echo -e "    ${YELLOW}⚠️  Could not reconnect (may not need traefik_proxy)${NC}"
            fi
        fi
    done
    echo ""
fi

# Restart Traefik if it's running
if docker ps --format "{{.Names}}" | grep -q "^traefik$"; then
    echo -e "${YELLOW}🔄 Restarting Traefik...${NC}"
    docker restart traefik
    sleep 3
    echo -e "${GREEN}✅ Traefik restarted${NC}"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ Network Fix Complete!                  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Wait 30 seconds for all services to stabilize"
echo "  2. Test your sites in the browser"
echo "  3. Clear browser cache if needed (Ctrl+Shift+Delete)"
echo ""
echo -e "${YELLOW}If sites still don't work:${NC}"
echo "  • Check container status: docker ps"
echo "  • Check network: docker network inspect traefik_proxy"
echo "  • Restart Traefik: docker restart traefik"
echo ""

