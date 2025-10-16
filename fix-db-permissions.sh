#!/bin/bash

# Fix database permissions for Frappe sites
# Usage: ./fix-db-permissions.sh <site_container_name>
# Example: ./fix-db-permissions.sh hossain2_local-app

# Color definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

if [ $# -eq 0 ]; then
    echo -e "${RED}❌ Error: Please provide the site container name${NC}"
    echo -e "${BLUE}Usage: $0 <site_container_name>${NC}"
    echo -e "${BLUE}Example: $0 hossain2_local-app${NC}"
    echo ""
    echo -e "${YELLOW}Available site containers:${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "app.*Up" | grep -v traefik
    exit 1
fi

SITE_CONTAINER=$1
DB_CONTAINER="${SITE_CONTAINER%-app}-db"

echo -e "${BLUE}🔧 Fixing database permissions for $SITE_CONTAINER${NC}"
echo "=========================================="

# Check if containers exist
if ! docker ps --format "{{.Names}}" | grep -q "^${SITE_CONTAINER}$"; then
    echo -e "${RED}❌ Error: Container $SITE_CONTAINER not found or not running${NC}"
    exit 1
fi

if ! docker ps --format "{{.Names}}" | grep -q "^${DB_CONTAINER}$"; then
    echo -e "${RED}❌ Error: Container $DB_CONTAINER not found or not running${NC}"
    exit 1
fi

# Get site name from container name
SITE_NAME=$(echo "$SITE_CONTAINER" | sed 's/_local-app$//')
echo -e "${BLUE}📍 Site name: $SITE_NAME${NC}"

# Get container IPs
echo -e "${BLUE}🔍 Getting container IP addresses...${NC}"
CONTAINER_IPS=$(docker exec "$SITE_CONTAINER" hostname -i 2>/dev/null)
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Error: Could not get container IP addresses${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Container IPs: $CONTAINER_IPS${NC}"

# Get database configuration
echo -e "${BLUE}🔍 Reading database configuration...${NC}"
DB_CONFIG=$(docker exec "$SITE_CONTAINER" cat "/home/frappe/frappe-bench/sites/${SITE_NAME}.local/site_config.json" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Error: Could not read site configuration${NC}"
    exit 1
fi

DB_NAME=$(echo "$DB_CONFIG" | grep -o '"db_name": "[^"]*"' | cut -d'"' -f4)
DB_PASSWORD=$(echo "$DB_CONFIG" | grep -o '"db_password": "[^"]*"' | cut -d'"' -f4)
ROOT_PASSWORD=$(echo "$DB_CONFIG" | grep -o '"root_password": "[^"]*"' | cut -d'"' -f4)

if [ -z "$DB_NAME" ] || [ -z "$DB_PASSWORD" ]; then
    echo -e "${RED}❌ Error: Could not extract database credentials${NC}"
    echo "DB_NAME: $DB_NAME"
    echo "DB_PASSWORD: $DB_PASSWORD"
    exit 1
fi

echo -e "${GREEN}✅ Database name: $DB_NAME${NC}"
echo -e "${GREEN}✅ Database password: ${DB_PASSWORD:0:10}...${NC}"

# Create database users for all IP patterns
echo -e "${BLUE}🔐 Creating database users and granting permissions...${NC}"

# Function to execute MySQL command
execute_mysql() {
    local cmd="$1"
    local description="$2"
    
    echo -e "${BLUE}   $description${NC}"
    if docker exec "$DB_CONTAINER" mysql -uroot -p"$ROOT_PASSWORD" -e "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}   ✅ Success${NC}"
    else
        echo -e "${YELLOW}   ⚠️  Warning (may already exist)${NC}"
    fi
}

# Create users for specific IPs
for ip in $CONTAINER_IPS; do
    if [ -n "$ip" ]; then
        execute_mysql "CREATE USER IF NOT EXISTS '$DB_NAME'@'$ip' IDENTIFIED BY '$DB_PASSWORD'; GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_NAME'@'$ip';" "Creating user for IP: $ip"
    fi
done

# Create users for IP subnets
for ip in $CONTAINER_IPS; do
    if [ -n "$ip" ]; then
        # Extract subnet (e.g., 192.168.0.4 -> 192.168.%)
        ip_parts=($(echo "$ip" | tr '.' ' '))
        if [ ${#ip_parts[@]} -ge 2 ]; then
            subnet="${ip_parts[0]}.${ip_parts[1]}.%"
            execute_mysql "CREATE USER IF NOT EXISTS '$DB_NAME'@'$subnet' IDENTIFIED BY '$DB_PASSWORD'; GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_NAME'@'$subnet';" "Creating user for subnet: $subnet"
        fi
    fi
done

# Create users for localhost and % patterns
execute_mysql "CREATE USER IF NOT EXISTS '$DB_NAME'@'localhost' IDENTIFIED BY '$DB_PASSWORD'; GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_NAME'@'localhost';" "Creating user for localhost"
execute_mysql "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_NAME'@'%';" "Granting privileges for % pattern"

# Flush privileges
execute_mysql "FLUSH PRIVILEGES;" "Flushing privileges"

echo ""
echo -e "${GREEN}✅ Database permissions fixed for $SITE_NAME!${NC}"
echo -e "${BLUE}💡 You can now install apps using:${NC}"
echo -e "   docker exec -it $SITE_CONTAINER bench --site ${SITE_NAME}.local install-app <app_name>"
echo ""
echo -e "${GREEN}🧪 Testing database connection...${NC}"
if docker exec "$SITE_CONTAINER" bench --site "${SITE_NAME}.local" list-apps >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Database connection test successful!${NC}"
else
    echo -e "${YELLOW}⚠️  Database connection test failed - site may still be starting${NC}"
fi

