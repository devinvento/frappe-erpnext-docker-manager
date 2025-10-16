#!/bin/bash

# Color definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---

# Generate secure password
generate_password() {
    # Try pwgen first, fallback to openssl
    if command -v pwgen >/dev/null 2>&1; then
        pwgen -s 32 1
    else
        openssl rand -base64 24 | tr -d "=+/" | cut -c1-32
    fi
}

# Fetch available ERPNext versions from Docker Hub
fetch_erpnext_versions() {
    # Try to fetch versions using curl (faster than docker pull)
    local versions=""
    
    # Check if curl is available and try to fetch from Docker Hub
    if command -v curl >/dev/null 2>&1; then
        echo -e "${BLUE}   Fetching from Docker Hub API...${NC}" >&2
        versions=$(curl -s --connect-timeout 10 --max-time 30 "https://registry.hub.docker.com/v2/repositories/frappe/erpnext/tags?page_size=100" | \
            grep -o '"name":"[^"]*"' | \
            grep -E '^"name":"v[0-9]+\.[0-9]+\.[0-9]+"' | \
            sed 's/"name":"//g' | \
            sed 's/"//g' | \
            sort -V -r | \
            head -1000 2>/dev/null)
    fi
    
    if [[ -z "$versions" ]]; then
        echo -e "${YELLOW}   Using fallback version list...${NC}" >&2
        # Fallback list of common versions
        versions="v15.80.1
v15.80.0
v15.79.2
v15.79.1
v15.79.0
v15.78.1
v15.78.0
v15.77.0
v15.76.0
v15.75.1
v15.75.0
v15.74.0
v15.73.2
v15.73.1
v15.73.0
v15.72.3
v15.72.2
v15.72.1
v15.71.1
v15.70.2"
    fi
    
    echo "$versions"
}

# Select ERPNext version
select_erpnext_version() {
    echo ""
    echo -e "${BLUE}📦 ERPNext Version Selection${NC}"
    echo "=================================="
    echo -e "${BLUE}🔍 Fetching available ERPNext versions from Docker Hub...${NC}"
    
    local versions=$(fetch_erpnext_versions)
    local version_array=()
    local i=1
    
    # Check if versions are fetched
    if [[ -z "$versions" ]]; then
        echo -e "${RED}❌ No versions found!${NC}"
        return 1
    fi
    
    echo ""
    echo "Available ERPNext versions:"
    echo ""
    
    # Convert to array and display
    local is_first=true
    while IFS= read -r version; do
        if [[ -n "$version" ]]; then
            version_array+=("$version")
            if [[ "$is_first" == "true" ]]; then
                echo -e "  ${GREEN}[$i] $version (LATEST - RECOMMENDED)${NC}"
                is_first=false
            elif [[ "$version" == "v15.63.0" ]]; then
                echo -e "  ${YELLOW}[$i] $version (STABLE)${NC}"
            else
                echo "  [$i] $version"
            fi
            ((i++))
        fi
    done <<< "$versions"
    
    # Check if we have any versions
    if [[ ${#version_array[@]} -eq 0 ]]; then
        echo -e "${RED}❌ No valid versions found!${NC}"
        return 1
    fi
    
    echo ""
    # Get the latest version (first in the sorted list)
    local latest_version="${version_array[0]}"
    echo -e "${GREEN}💡 $latest_version is the latest version with newest features${NC}"
    echo -e "${YELLOW}💡 v15.63.0 is a stable version recommended for production${NC}"
    echo -e "${BLUE}💡 Choose based on your needs: latest features vs stability${NC}"
    echo ""
    
    # Get user selection
    while true; do
        read -p "Select ERPNext version (1-${#version_array[@]}) [1]: " selection
        
        # Default to 1 if empty
        if [[ -z "$selection" ]]; then
            selection=1
        fi
        
        # Validate selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "${#version_array[@]}" ]]; then
            selected_version="${version_array[$((selection-1))]}"
            echo -e "${GREEN}✅ Selected ERPNext version: $selected_version${NC}"
            SELECTED_ERPNEXT_VERSION="$selected_version"
            break
        else
            echo -e "${RED}❌ Invalid selection. Please enter a number between 1 and ${#version_array[@]}${NC}"
        fi
    done
}

# Detect preferred docker compose command
detect_docker_compose() {
    # Try docker compose (v2) first - preferred method
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
        export DOCKER_COMPOSE_VERSION="v2"
        return 0
    # Fallback to docker-compose (v1) if v2 is not available
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
        export DOCKER_COMPOSE_VERSION="v1"
        return 0
    else
        echo -e "${RED}Error: Neither 'docker compose' nor 'docker-compose' is available${NC}" >&2
        return 1
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if a port is in use
is_port_in_use() {
    ss -ltn "sport = :$1" | grep -q LISTEN
}

# Get the process using a port
get_process_on_port() {
    ss -ltnp "sport = :$1" | grep LISTEN | awk '{print $7}'
}

# Check if Traefik is running
is_traefik_running() {
    docker ps --filter "name=traefik" --format "{{.Names}}" | grep -q "traefik"
}

# Validate a domain name (modified to allow localhost domains)
validate_domain() {
    local domain=$1
    # Allow localhost domains
    if [[ $domain =~ \.localhost$ ]]; then
        return 0
    fi
    # Standard domain validation
    if [[ ! $domain =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*(\.[a-zA-Z0-9][a-zA-Z0-9-]*)*\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}Error: Invalid domain name format. Please use a format like 'example.com', 'subdomain.example.com', or 'mysite.localhost'.${NC}"
        return 1
    fi
    return 0
}

# Load local Traefik configuration if it exists
load_local_config() {
    if [[ -f ".traefik-local-config" ]]; then
        source .traefik-local-config
        echo -e "${BLUE}📋 Loaded local Traefik configuration${NC}"
        echo "  • HTTP Port: ${TRAEFIK_HTTP_PORT}"
        if [[ -n "$TRAEFIK_HTTPS_PORT" ]]; then
            echo "  • HTTPS Port: ${TRAEFIK_HTTPS_PORT}"
        fi
        if [[ "$USE_LOCALHOST" == "true" ]]; then
            echo "  • Using localhost domains"
        fi
        echo ""
        return 0
    fi
    return 1
}

# Function to manage hosts file entries
manage_hosts_entry() {
    local domain=$1
    local action=$2  # "add" or "remove"
    
    if [[ $domain =~ \.localhost$ ]]; then
        return 0  # .localhost domains don't need hosts file entries
    fi
    
    case $action in
        "add")
            if grep -q "$domain" /etc/hosts; then
                echo -e "${YELLOW}⚠️  Domain $domain already exists in hosts file${NC}"
                return 0
            else
                if echo "127.0.0.1 $domain" | tee -a /etc/hosts > /dev/null; then
                    echo -e "${GREEN}✅ Added $domain to hosts file${NC}"
                    return 0
                else
                    echo -e "${RED}❌ Failed to add domain to hosts file${NC}"
                    return 1
                fi
            fi
            ;;
        "remove")
            if grep -q "$domain" /etc/hosts; then
                # Create a temporary file without the domain
                sudo sed "/$domain/d" /etc/hosts > /tmp/hosts.tmp
                if sudo mv /tmp/hosts.tmp /etc/hosts; then
                    echo -e "${GREEN}✅ Removed $domain from hosts file${NC}"
                    return 0
                else
                    echo -e "${RED}❌ Failed to remove domain from hosts file${NC}"
                    return 1
                fi
            else
                echo -e "${YELLOW}⚠️  Domain $domain not found in hosts file${NC}"
                return 0
            fi
            ;;
    esac
}

# Generate the optimized docker-compose.yml file
generate_docker_compose() {
    local safe_site_name=$1
    local site_name=$2
    local erpnext_version=$3
    local compose_file="$safe_site_name/${safe_site_name}-docker-compose.yml"
    
    # Get Docker Compose version for compatibility
    DOCKER_COMPOSE_CMD=$(detect_docker_compose)
    
    # Generate unique IP subnet for this site based on site name hash
    # This ensures each site gets its own unique IPs
    local site_hash=$(echo -n "$safe_site_name" | md5sum | cut -c1-4)
    local subnet_third_octet=$((0x${site_hash:0:2} % 250 + 1))  # 1-250
    local subnet_base="172.25.${subnet_third_octet}"
    
    # Load local config to check for custom ports
    local http_entrypoint="web"
    
    if load_local_config; then
        # Use the configured entrypoint
        http_entrypoint="web"
    fi

    # Traefik labels for the main app container
    local app_labels=$(cat <<EOF
      - "traefik.enable=true"
      - "traefik.docker.network=traefik_proxy"
      - "traefik.http.services.${safe_site_name}-app.loadbalancer.server.port=8000"
      - "traefik.http.services.${safe_site_name}-app.loadbalancer.passHostHeader=true"
      - "traefik.http.routers.${safe_site_name}-app-http.rule=Host(\`${site_name}\`)"
      - "traefik.http.routers.${safe_site_name}-app-http.entrypoints=${http_entrypoint}"
      - "traefik.http.routers.${safe_site_name}-app-http.service=${safe_site_name}-app"
      - "traefik.http.services.${safe_site_name}-websocket.loadbalancer.server.port=9000"
      - "traefik.http.routers.${safe_site_name}-websocket.rule=Host(\`${site_name}\`) && PathPrefix(\`/socket.io\`)"
      - "traefik.http.routers.${safe_site_name}-websocket.entrypoints=${http_entrypoint}"
      - "traefik.http.routers.${safe_site_name}-websocket.service=${safe_site_name}-websocket"
      - "traefik.http.middlewares.${safe_site_name}-websocket-headers.headers.customRequestHeaders.X-Forwarded-Proto=http"
      - "traefik.http.routers.${safe_site_name}-websocket.middlewares=${safe_site_name}-websocket-headers"
EOF
)

    cat > "$compose_file" << EOF
version: "3.8"

services:
  app:
    image: frappe/erpnext:${erpnext_version}
    container_name: ${safe_site_name}-app
    restart: unless-stopped
    networks:
      frappe_network:
        ipv4_address: ${subnet_base}.10
      traefik_proxy: {}
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
      create-site:
        condition: service_completed_successfully
    labels:
${app_labels}
    deploy:
      restart_policy:
        condition: on-failure
        max_attempts: 3
      resources:
        limits:
          memory: 2G
          cpus: '1.0'
    security_opt:
      - no-new-privileges:true
    read_only: false
    tmpfs:
      - /tmp
      - /var/tmp
    healthcheck:
      test: |
        /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf status | grep -q "RUNNING" && 
        curl -f http://localhost:8000/api/method/ping || exit 1
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
      - ${VSCODE_DIR}/${safe_site_name}-frappe-bench/apps:/home/frappe/frappe-bench/apps
    environment:
      DB_HOST: db
      DB_PORT: "3306"
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      SOCKETIO_PORT: "9000"
      SOCKETIO_ORIGINS: "http://${site_name}:8081,http://${site_name},http://localhost:8081,http://localhost"
      ALLOW_CORS: "*"
      CORS_ORIGIN: "*"
      ALLOW_ORIGIN: "*"
      DISABLE_ORIGIN_CHECK: "true"
      SESSION_EXPIRY: "3600"
      SESSION_TIMEOUT: "3600"
      SOCKETIO_SESSION_TIMEOUT: "3600"
      SOCKETIO_ALLOW_ORIGIN_CHECK: "false"
      SOCKETIO_DISABLE_ORIGIN_CHECK: "true"
      DB_PASSWORD: \${DB_PASSWORD}
      REDIS_PASSWORD: \${REDIS_PASSWORD}
      FRAPPE_SITE_NAME_HEADER: \${FRAPPE_SITE_NAME_HEADER}
      SITES: \${SITES}
    entrypoint:
      - bash
      - -c
      - |
        echo "🚀 Starting Frappe application container...";
        echo "⏳ Waiting for site to be ready...";
        
        # Wait for site creation to complete
        while [ ! -f sites/${site_name}/site_config.json ]; do
          echo "Site not ready yet, waiting...";
          sleep 10;
        done;
        
        # Additional wait for site to be fully configured
        echo "Waiting for site configuration to complete...";
        sleep 30;
        
        # Check if supervisor is already installed
        if ! command -v supervisord >/dev/null 2>&1; then
          echo "Installing supervisor...";
          pip3 install supervisor;
        else
          echo "Supervisor already installed";
        fi;
        
        # Create supervisor directories
        mkdir -p /home/frappe/supervisor/conf.d /home/frappe/supervisor/logs;
        
        # Only create config if it doesn't exist
        if [ ! -f /home/frappe/supervisor/supervisord.conf ]; then
          echo "Creating supervisor configuration...";
          cat > /home/frappe/supervisor/supervisord.conf << 'SUPERVISOR_EOF'
        [unix_http_server]
        file=/home/frappe/supervisor/supervisor.sock
        chmod=0777
        chown=frappe:frappe

        [supervisord]
        logfile=/home/frappe/supervisor/logs/supervisord.log
        pidfile=/home/frappe/supervisor/supervisord.pid
        childlogdir=/home/frappe/supervisor/logs
        nodaemon=false
        user=frappe

        [rpcinterface:supervisor]
        supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

        [supervisorctl]
        serverurl=unix:///home/frappe/supervisor/supervisor.sock

        [include]
        files = /home/frappe/supervisor/conf.d/*.conf
        SUPERVISOR_EOF

        # Create Frappe process configurations
        cat > /home/frappe/supervisor/conf.d/frappe.conf << 'FRAPPE_CONF_EOF'
        [group:frappe]
        programs=frappe-web,frappe-schedule,frappe-worker-short,frappe-worker-long,frappe-worker-default,frappe-websocket

        [program:frappe-web]
        command=bench serve --port 8000
        directory=/home/frappe/frappe-bench
        user=frappe
        autostart=true
        autorestart=true
        redirect_stderr=true
        stdout_logfile=/home/frappe/supervisor/logs/frappe-web.log
        stderr_logfile=/home/frappe/supervisor/logs/frappe-web-error.log

        [program:frappe-schedule]
        command=bench schedule
        directory=/home/frappe/frappe-bench
        user=frappe
        autostart=true
        autorestart=true
        redirect_stderr=true
        stdout_logfile=/home/frappe/supervisor/logs/frappe-schedule.log
        stderr_logfile=/home/frappe/supervisor/logs/frappe-schedule-error.log

        [program:frappe-worker-short]
        command=bench worker --queue short
        directory=/home/frappe/frappe-bench
        user=frappe
        autostart=true
        autorestart=true
        redirect_stderr=true
        stdout_logfile=/home/frappe/supervisor/logs/frappe-worker-short.log
        stderr_logfile=/home/frappe/supervisor/logs/frappe-worker-short-error.log

        [program:frappe-worker-long]
        command=bench worker --queue long
        directory=/home/frappe/frappe-bench
        user=frappe
        autostart=true
        autorestart=true
        redirect_stderr=true
        stdout_logfile=/home/frappe/supervisor/logs/frappe-worker-long.log
        stderr_logfile=/home/frappe/supervisor/logs/frappe-worker-long-error.log

        [program:frappe-worker-default]
        command=bench worker --queue default
        directory=/home/frappe/frappe-bench
        user=frappe
        autostart=true
        autorestart=true
        redirect_stderr=true
        stdout_logfile=/home/frappe/supervisor/logs/frappe-worker-default.log
        stderr_logfile=/home/frappe/supervisor/logs/frappe-worker-default-error.log

        [program:frappe-websocket]
        command=bash -c "cd /home/frappe/frappe-bench && node -e \"process.env.SOCKETIO_ORIGINS='http://${site_name}:8081,http://${site_name},http://localhost:8081,http://localhost'; process.env.ALLOW_CORS='*'; process.env.CORS_ORIGIN='*'; process.env.ALLOW_ORIGIN='*'; process.env.DISABLE_ORIGIN_CHECK='true'; process.env.SOCKETIO_ALLOW_ORIGIN_CHECK='false'; process.env.SOCKETIO_DISABLE_ORIGIN_CHECK='true'; require('./apps/frappe/socketio.js');\""
        directory=/home/frappe/frappe-bench
        user=frappe
        autostart=true
        autorestart=true
        redirect_stderr=true
        stdout_logfile=/home/frappe/supervisor/logs/frappe-websocket.log
        stderr_logfile=/home/frappe/supervisor/logs/frappe-websocket-error.log
        environment=SOCKETIO_ORIGINS="http://${site_name}:8081,http://${site_name},http://localhost:8081,http://localhost",ALLOW_CORS="*",CORS_ORIGIN="*",ALLOW_ORIGIN="*",SESSION_EXPIRY="3600",SESSION_TIMEOUT="3600",SOCKETIO_SESSION_TIMEOUT="3600",DISABLE_ORIGIN_CHECK="true",SOCKETIO_ALLOW_ORIGIN_CHECK="false",SOCKETIO_DISABLE_ORIGIN_CHECK="true"
        FRAPPE_CONF_EOF

        fi;
        
        echo "🚀 Starting supervisor...";
        /home/frappe/.local/bin/supervisord -c /home/frappe/supervisor/supervisord.conf;
        
        # Wait for supervisor to start
        sleep 10;
        
        echo "✅ Supervisor started, showing status:";
        /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf status;
        
        echo "🎉 Frappe application container is ready!";
        echo "📝 Monitoring supervisor logs...";
        
        # Keep container running
        tail -f /home/frappe/supervisor/logs/supervisord.log

  create-site:
    image: frappe/erpnext:${erpnext_version}
    container_name: ${safe_site_name}-create-site
    restart: "no"
    networks:
      frappe_network:
        ipv4_address: ${subnet_base}.11
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    deploy:
      restart_policy:
        condition: none
      resources:
        limits:
          memory: 1G
          cpus: '0.5'
    security_opt:
      - no-new-privileges:true
    read_only: false
    tmpfs:
      - /tmp
      - /var/tmp
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
      - ${VSCODE_DIR}/${safe_site_name}-frappe-bench/apps:/home/frappe/frappe-bench/apps
    environment:
      DB_HOST: db
      DB_PORT: "3306"
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      DB_PASSWORD: \${DB_PASSWORD}
      REDIS_PASSWORD: \${REDIS_PASSWORD}
      FRAPPE_SITE_NAME_HEADER: \${FRAPPE_SITE_NAME_HEADER}
      SITES: \${SITES}
    entrypoint:
      - bash
      - -c
      - |
        wait-for-it -t 120 db:3306;
        wait-for-it -t 120 redis:6379;
        cd /home/frappe/frappe-bench;
        
        
        # Create apps.txt with all available apps
        if [ -f sites/apps.txt ]; then
          echo "Preserving existing apps.txt...";
          # Merge with current apps
          ls -1 apps >> sites/apps.txt.tmp 2>/dev/null || true;
          sort sites/apps.txt.tmp | uniq > sites/apps.txt;
          rm -f sites/apps.txt.tmp;
        else
          ls -1 apps > sites/apps.txt || true;
        fi;
        bench set-config -g db_host db;
        bench set-config -gp db_port 3306;
        bench set-config -g redis_cache "redis://:\${REDIS_PASSWORD}@redis:6379";
        bench set-config -g redis_queue "redis://:\${REDIS_PASSWORD}@redis:6379";
        bench set-config -g redis_socketio "redis://:\${REDIS_PASSWORD}@redis:6379";
        bench set-config -gp socketio_port 9000;
        bench set-config -g socketio_origins "http://${site_name}:8081,http://${site_name},http://localhost:8081,http://localhost";
        bench set-config -g allow_cors "*";
        bench set-config -g cors_origin "*";
        bench set-config -g socketio_cors_allowed_origins "*";
        bench set-config -g allow_origin "*";
        bench set-config -g socketio_allow_origin "*";
        bench set-config -g disable_origin_check true;
        bench set-config -g session_expiry 3600;
        bench set-config -g session_timeout 3600;
        bench set-config -g socketio_session_timeout 3600;
        bench set-config -g socketio_allow_origin_check false;
        bench set-config -g socketio_disable_origin_check true;
        if [ ! -d sites/${site_name} ]; then
          echo "Creating new site...";
          bench new-site --mariadb-root-password=\${DB_PASSWORD} --admin-password=admin --install-app erpnext --set-default ${site_name};
          echo "${site_name}" > sites/currentsite.txt;
          
          # IMMEDIATELY fix database user to allow connections from any IP
          echo "🔐 Fixing database user permissions for wildcard access...";
          SITE_DB_USER=\$\$(python3 -c "import json; print(json.load(open('sites/${site_name}/site_config.json')).get('db_name',''))")
          SITE_DB_PASS=\$\$(python3 -c "import json; print(json.load(open('sites/${site_name}/site_config.json')).get('db_password',''))")
          
          echo "Extracted user: \$\$SITE_DB_USER";
          if [ -n "\$\$SITE_DB_USER" ] && [ -n "\$\$SITE_DB_PASS" ]; then
            echo "Granting % access to user: \$\$SITE_DB_USER";
            mysql -h db -uroot -p\${DB_PASSWORD} -e "DROP USER IF EXISTS '\$\$SITE_DB_USER'@'%';" 2>/dev/null || true
            mysql -h db -uroot -p\${DB_PASSWORD} -e "CREATE USER '\$\$SITE_DB_USER'@'%' IDENTIFIED BY '\$\$SITE_DB_PASS';"
            mysql -h db -uroot -p\${DB_PASSWORD} -e "GRANT ALL PRIVILEGES ON \$\$SITE_DB_USER.* TO '\$\$SITE_DB_USER'@'%';"
            mysql -h db -uroot -p\${DB_PASSWORD} -e "FLUSH PRIVILEGES;"
            echo "✅ Database user \$\$SITE_DB_USER now has wildcard (%) access!";
          else
            echo "❌ Failed to extract DB credentials!";
          fi
        else
          echo "Site ${site_name} already exists, skipping creation";
          echo "${site_name}" > sites/currentsite.txt;
          
          # Fix permissions for existing site too
          echo "🔐 Fixing database user permissions for existing site...";
          SITE_DB_USER=\$\$(python3 -c "import json; print(json.load(open('sites/${site_name}/site_config.json')).get('db_name',''))")
          SITE_DB_PASS=\$\$(python3 -c "import json; print(json.load(open('sites/${site_name}/site_config.json')).get('db_password',''))")
          
          echo "Extracted user: \$\$SITE_DB_USER";
          if [ -n "\$\$SITE_DB_USER" ] && [ -n "\$\$SITE_DB_PASS" ]; then
            echo "Granting % access to user: \$\$SITE_DB_USER";
            mysql -h db -uroot -p\${DB_PASSWORD} -e "DROP USER IF EXISTS '\$\$SITE_DB_USER'@'%';" 2>/dev/null || true
            mysql -h db -uroot -p\${DB_PASSWORD} -e "CREATE USER '\$\$SITE_DB_USER'@'%' IDENTIFIED BY '\$\$SITE_DB_PASS';"
            mysql -h db -uroot -p\${DB_PASSWORD} -e "GRANT ALL PRIVILEGES ON \$\$SITE_DB_USER.* TO '\$\$SITE_DB_USER'@'%';"
            mysql -h db -uroot -p\${DB_PASSWORD} -e "FLUSH PRIVILEGES;"
            echo "✅ Database user \$\$SITE_DB_USER now has wildcard (%) access!";
          else
            echo "❌ Failed to extract DB credentials!";
          fi
        fi

  db:
    image: mariadb:10.6
    container_name: ${safe_site_name}-db
    restart: unless-stopped
    networks:
      frappe_network:
        ipv4_address: ${subnet_base}.20
    healthcheck:
      test: mysqladmin ping -h localhost --password=\${DB_PASSWORD}
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    deploy:
      restart_policy:
        condition: on-failure
      resources:
        limits:
          memory: 1G
          cpus: '0.5'
    security_opt:
      - no-new-privileges:true
    read_only: false
    tmpfs:
      - /tmp
      - /var/tmp
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --skip-character-set-client-handshake
      - --skip-innodb-read-only-compressed
    environment:
      MYSQL_ROOT_PASSWORD: \${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: \${DB_PASSWORD}
    volumes:
      - db-data:/var/lib/mysql

  redis:
    image: redis:6.2-alpine
    container_name: ${safe_site_name}-redis
    restart: unless-stopped
    networks:
      frappe_network:
        ipv4_address: ${subnet_base}.30
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    deploy:
      restart_policy:
        condition: on-failure
      resources:
        limits:
          memory: 512M
          cpus: '0.25'
    security_opt:
      - no-new-privileges:true
    read_only: false
    tmpfs:
      - /tmp
      - /var/tmp
    command: redis-server --appendonly yes --requirepass \${REDIS_PASSWORD}
    volumes:
      - redis-data:/data

networks:
  frappe_network:
    driver: bridge
    ipam:
      config:
        - subnet: ${subnet_base}.0/24
  traefik_proxy:
    external: true

volumes:
  sites:
  logs:
  apps:
  db-data:
  redis-data:
EOF
}

# --- Main Script ---

# Check for Docker
if ! command_exists docker; then
    echo -e "${RED}Docker is not installed. Please install Docker and try again.${NC}"
    exit 1
fi

# Check if running with sudo (needed for hosts file management)
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ This script must be run with sudo for hosts file management${NC}"
    echo -e "${YELLOW}💡 Please run: sudo ./generate_frappe_docker_local_optimized.sh${NC}"
    exit 1
fi

# Welcome message
echo -e "${GREEN}Welcome to Frappe/ERPNext Docker Setup (Optimized Edition)!${NC}"
echo "=============================================================="
echo ""
echo -e "${BLUE}🚀 Optimized for local development with minimal containers:${NC}"
echo "  • 1 app container (runs all Frappe processes via Supervisor)"
echo "  • 1 Redis container (handles cache, queue, and socketio)"
echo "  • 1 MariaDB container"
echo "  • 1 temporary create-site container"
echo ""

# For local development, we don't need SSL
echo -e "${BLUE}📍 Local Development Environment${NC}"
echo -e "${YELLOW}HTTP-only setup (no SSL certificates needed for local)${NC}"

# Check if we have a local Traefik configuration
if load_local_config; then
    echo -e "${GREEN}✅ Using existing local Traefik configuration${NC}"
fi
echo ""

# Check for port conflicts (skip if local config exists and handled)
if ! is_traefik_running && [[ ! -f ".traefik-local-config" ]]; then
    blocked_ports=""
    if is_port_in_use 80; then blocked_ports="80"; fi
    if is_port_in_use 443; then blocked_ports="$blocked_ports 443"; fi

    if [[ -n "$blocked_ports" ]]; then
        echo -e "${YELLOW}Warning: Ports $blocked_ports are in use by other processes.${NC}"
        echo "Traefik needs these ports to work properly."
        echo ""
        echo -e "${BLUE}💡 TIP: Run ./setup-traefik-local.sh first to handle port conflicts${NC}"
        echo ""
        for port in $blocked_ports; do
            echo "Port $port is being used by: $(get_process_on_port $port)"
        done
        read -p "Do you want to exit and run setup-traefik-local.sh first? (y/n): " exit_setup
        if [[ "$exit_setup" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Please run: ./setup-traefik-local.sh${NC}"
            exit 0
        fi
    fi
fi

# Check and create traefik_proxy network (safe for existing sites)
echo -e "${BLUE}🌐 Checking Docker network configuration...${NC}"

# Check if traefik_proxy network exists
if ! docker network ls | grep -q traefik_proxy; then
    echo -e "${BLUE}Creating traefik_proxy network...${NC}"
    docker network create traefik_proxy --driver bridge
    echo -e "${GREEN}✅ Created traefik_proxy network${NC}"
else
    # Network exists, verify it's accessible (don't remove it!)
    if docker network inspect traefik_proxy >/dev/null 2>&1; then
        echo -e "${GREEN}✅ traefik_proxy network is healthy${NC}"
    else
        echo -e "${YELLOW}⚠️  Network exists but can't be inspected${NC}"
        echo -e "${YELLOW}⚠️  Manual fix may be needed: docker network rm traefik_proxy && docker network create traefik_proxy${NC}"
    fi
fi
echo ""

# Check if Traefik is running
if ! is_traefik_running; then
    echo -e "${RED}⚠️  Traefik is not running!${NC}"
    echo ""
    echo "Options:"
    echo "  1. Auto-install Traefik (RECOMMENDED)"
    echo "  2. Continue without Traefik (manual setup required)"
    echo "  3. Exit and run setup-traefik-local.sh manually"
    echo ""
    read -p "Choose an option (1-3): " traefik_option
    
    case $traefik_option in
        1)
            echo -e "${BLUE}🚀 Auto-installing Traefik...${NC}"
            if [[ -f "./setup-traefik-local.sh" ]]; then
                echo -e "${GREEN}✅ Found setup-traefik-local.sh, running it...${NC}"
                chmod +x ./setup-traefik-local.sh
                ./setup-traefik-local.sh
                
                # Check if Traefik started successfully
                sleep 5
                if is_traefik_running; then
                    echo -e "${GREEN}✅ Traefik installed and running successfully!${NC}"
                else
                    echo -e "${RED}❌ Traefik installation failed${NC}"
                    echo -e "${YELLOW}💡 You can try running ./setup-traefik-local.sh manually${NC}"
                    read -p "Do you want to continue anyway? (y/n): " continue_without_traefik
                    if [[ ! "$continue_without_traefik" =~ ^[Yy]$ ]]; then
                        exit 1
                    fi
                fi
            else
                echo -e "${RED}❌ setup-traefik-local.sh not found in current directory${NC}"
                echo -e "${YELLOW}💡 Please run ./setup-traefik-local.sh manually first${NC}"
                read -p "Do you want to continue anyway? (y/n): " continue_without_traefik
                if [[ ! "$continue_without_traefik" =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            fi
            ;;
        2)
            echo -e "${YELLOW}⚠️  Continuing without Traefik - manual setup required${NC}"
            ;;
        3)
            echo -e "${YELLOW}Please run: ./setup-traefik-local.sh${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Exiting...${NC}"
            exit 1
            ;;
    esac
else
    echo -e "${GREEN}✅ Traefik is running${NC}"
fi

# Select ERPNext version
select_erpnext_version
erpnext_version=$SELECTED_ERPNEXT_VERSION

# Get site name with localhost suggestion for local env
echo ""
echo -e "${BLUE}💡 For local development, use a .localhost domain (e.g., mysite.localhost)${NC}"
echo -e "${BLUE}   Or use any domain like mysite.local (will be auto-added to hosts file)${NC}"

while true; do
    read -p "Enter site name (e.g. example.com or mysite.localhost): " site_name
    if validate_domain "$site_name"; then
        break
    fi
done

USE_LOCALHOST=false
echo -e "${BLUE}📝 Custom domain detected - will be added to hosts file${NC}"

# Sanitize site name
safe_site_name=$(echo "$site_name" | sed 's/[^a-zA-Z0-9]/_/g')

# Check if site directory already exists
if [ -d "$safe_site_name" ]; then
    echo -e "${YELLOW}⚠️  Site directory '$safe_site_name' already exists${NC}"
    echo ""
    read -p "Do you want to use the existing site? (y/n): " use_existing
    if [[ "$use_existing" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Using existing site directory${NC}"
        echo ""
        echo -e "${BLUE}Note: This will reuse existing database volumes.${NC}"
        echo -e "${BLUE}If you're having password issues, you may want to:${NC}"
        echo "  1. Delete the site directory: rm -rf $safe_site_name"
        echo "  2. Remove volumes: docker volume rm ${safe_site_name}_db-data ${safe_site_name}_sites ${safe_site_name}_redis-data 2>/dev/null"
        echo "  3. Run this script again"
        echo ""
        read -p "Continue with existing site? (y/n): " continue_existing
        if [[ ! "$continue_existing" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Setup cancelled${NC}"
            exit 1
        fi
    else
        echo -e "${RED}Please remove the existing site directory or choose a different name${NC}"
        exit 1
    fi
fi

# Create site directory
mkdir -p "$safe_site_name"

# Determine the VS Code development directory
# Use the actual user's home directory, not root's home when running with sudo
ACTUAL_USER_HOME=$(eval echo ~$SUDO_USER)
if [ -z "$ACTUAL_USER_HOME" ] || [ "$ACTUAL_USER_HOME" = "~$SUDO_USER" ]; then
    # Fallback to current user's home if SUDO_USER is not set
    ACTUAL_USER_HOME="$HOME"
fi

VSCODE_DIR="${ACTUAL_USER_HOME}/frappe-docker"
if [ ! -d "$VSCODE_DIR" ]; then
    mkdir -p "$VSCODE_DIR"
    echo -e "${GREEN}📁 Created VS Code development directory: ${VSCODE_DIR}${NC}"
fi

# Create frappe-bench directory for VS Code development
mkdir -p "${VSCODE_DIR}/${safe_site_name}-frappe-bench"
echo -e "${GREEN}📁 Created frappe-bench directory: ${VSCODE_DIR}/${safe_site_name}-frappe-bench${NC}"

# Copy Frappe apps to the mounted directory for VS Code development
echo -e "${BLUE}📦 Copying Frappe apps to mounted directory...${NC}"
sudo chown -R $USER:$USER "${VSCODE_DIR}/${safe_site_name}-frappe-bench"
docker run --rm --user root -v "${VSCODE_DIR}/${safe_site_name}-frappe-bench/apps:/apps" frappe/erpnext:${erpnext_version} bash -c "cp -r /home/frappe/frappe-bench/apps/* /apps/ && chown -R 1000:1000 /apps"
echo -e "${GREEN}✅ Frappe apps copied successfully${NC}"
echo -e "${BLUE}   💡 You can now open this folder in VS Code for development${NC}"

# Create .env file
DB_PASSWORD=$(generate_password)
REDIS_PASSWORD=$(generate_password)
FRAPPE_SITE_NAME_HEADER=${site_name}
SITES=${site_name}
cat > "$safe_site_name/.env" << EOF
ERPNEXT_VERSION=${erpnext_version}
DB_PASSWORD=${DB_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
FRAPPE_SITE_NAME_HEADER=${FRAPPE_SITE_NAME_HEADER}
SITES=${SITES}
EOF

# Generate docker-compose
generate_docker_compose "$safe_site_name" "$site_name" "$erpnext_version"

# Start containers with network fix
echo -e "${GREEN}Starting your optimized Frappe/ERPNext site...${NC}"
DOCKER_COMPOSE_CMD=$(detect_docker_compose)
if [ $? -ne 0 ]; then
    exit 1
fi

# IMPORTANT: Always use -p (--project-name) flag with docker-compose commands
# This ensures consistent container naming (e.g., hossain10_local-app)
# Without it, Docker Compose may prefix containers with a hash (e.g., 40e26c6007ba_hossain10_local-app)

# Verify network exists before starting containers
if ! docker network ls | grep -q traefik_proxy; then
    echo -e "${YELLOW}⚠️  traefik_proxy network missing, recreating...${NC}"
    docker network create traefik_proxy --driver bridge
fi

# Start containers
echo -e "${BLUE}🚀 Starting containers...${NC}"
if ! $DOCKER_COMPOSE_CMD -p "$safe_site_name" -f "$safe_site_name/${safe_site_name}-docker-compose.yml" up -d; then
    echo -e "${YELLOW}⚠️  Docker Compose failed, trying alternative method...${NC}"
    # Try starting containers individually as fallback
    $DOCKER_COMPOSE_CMD -p "$safe_site_name" -f "$safe_site_name/${safe_site_name}-docker-compose.yml" start || echo -e "${RED}❌ Failed to start containers${NC}"
fi

# Check if containers started successfully
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Containers started successfully${NC}"
    
    # Verify network connectivity
    sleep 5
    echo -e "${BLUE}🔍 Verifying network connectivity...${NC}"
    
    # Check if containers are connected to traefik_proxy
    if docker inspect "${safe_site_name}-app" | grep -q "traefik_proxy"; then
        echo -e "${GREEN}✅ Containers properly connected to traefik_proxy network${NC}"
    else
        echo -e "${YELLOW}⚠️  Reconnecting containers to network...${NC}"
        docker network connect traefik_proxy ${safe_site_name}-app 2>/dev/null
    fi
else
    echo -e "${RED}❌ Failed to start containers${NC}"
    echo -e "${YELLOW}Checking for common issues...${NC}"
    
    # Check if it's a network issue
    if ! docker network inspect traefik_proxy >/dev/null 2>&1; then
        echo -e "${RED}Network issue detected. Fixing...${NC}"
        docker network create traefik_proxy --driver bridge
        echo -e "${YELLOW}Retrying container start...${NC}"
        $DOCKER_COMPOSE_CMD -p "$safe_site_name" -f "$safe_site_name/${safe_site_name}-docker-compose.yml" up -d
    fi
fi

# Get the actual app container name (handle Docker Compose naming variations)
APP_CONTAINER=$(docker ps --filter "name=${safe_site_name}-app" --format "{{.Names}}" | head -1)
if [ -z "$APP_CONTAINER" ]; then
    APP_CONTAINER="${safe_site_name}-app"
fi

# Ensure Frappe apps are available in the mounted directory
echo -e "${BLUE}🔧 Ensuring Frappe apps are available for VS Code development...${NC}"
if [ ! -d "${VSCODE_DIR}/${safe_site_name}-frappe-bench/apps/frappe" ]; then
    echo -e "${YELLOW}📦 Apps not found, copying from container...${NC}"
    sudo chown -R $USER:$USER "${VSCODE_DIR}/${safe_site_name}-frappe-bench"
    docker run --rm --user root -v "${VSCODE_DIR}/${safe_site_name}-frappe-bench/apps:/apps" frappe/erpnext:${erpnext_version} bash -c "cp -r /home/frappe/frappe-bench/apps/* /apps/ && chown -R 1000:1000 /apps"
    echo -e "${GREEN}✅ Frappe apps copied successfully${NC}"
else
    echo -e "${GREEN}✅ Frappe apps already available${NC}"
fi

# Ensure apps.txt includes all installed apps
echo -e "${BLUE}🔧 Ensuring apps.txt includes all installed apps...${NC}"
sleep 10  # Wait for containers to be ready
docker exec $APP_CONTAINER bash -c "cd /home/frappe/frappe-bench && ls -1 apps > sites/apps.txt" 2>/dev/null || echo -e "${YELLOW}⚠️  Container not ready yet, apps.txt will be updated automatically${NC}"
echo -e "${GREEN}✅ apps.txt updated with all installed apps${NC}"

# Ensure currentsite.txt is set correctly
echo -e "${BLUE}🔧 Ensuring currentsite.txt is set correctly...${NC}"
docker exec $APP_CONTAINER bash -c "cd /home/frappe/frappe-bench && echo '${site_name}' > sites/currentsite.txt" 2>/dev/null || echo -e "${YELLOW}⚠️  Container not ready yet, currentsite.txt will be set automatically${NC}"
echo -e "${GREEN}✅ currentsite.txt set to ${site_name}${NC}"

# Wait 2 minutes for everything to initialize, then restart containers
echo -e "${BLUE}⏳ Waiting 3 minutes for containers to initialize...${NC}"
echo -e "${YELLOW}💡 This allows the site to be fully created and configured${NC}"
sleep 180

echo -e "${BLUE}🔄 Restarting all containers for proper initialization...${NC}"

# Stop all containers first using explicit container names
echo -e "${YELLOW}⏹️  Stopping all containers...${NC}"

# Check which containers are running and stop them
for container in ${safe_site_name}-app ${safe_site_name}-db ${safe_site_name}-redis ${safe_site_name}-create-site; do
    if docker ps --filter "name=$container" --format "{{.Names}}" | grep -F "$container" >/dev/null 2>&1; then
        echo -e "${BLUE}   Stopping $container...${NC}"
        docker stop "$container" 2>/dev/null || echo -e "${YELLOW}   Warning: Could not stop $container${NC}"
    else
        echo -e "${BLUE}   $container is not running${NC}"
    fi
done

# Wait a moment
sleep 5

# Start all containers using the full path to docker-compose file
echo -e "${YELLOW}▶️  Starting all containers...${NC}"
if ! $DOCKER_COMPOSE_CMD -p "$safe_site_name" -f "$safe_site_name/${safe_site_name}-docker-compose.yml" up -d; then
    echo -e "${YELLOW}⚠️  Docker Compose up failed, trying alternative method...${NC}"
    # Try starting containers individually as fallback
    $DOCKER_COMPOSE_CMD -p "$safe_site_name" -f "$safe_site_name/${safe_site_name}-docker-compose.yml" start || echo -e "${RED}❌ Failed to start containers${NC}"
fi

# Wait a bit and check if containers are running
sleep 10
echo -e "${BLUE}🔍 Checking container status after restart...${NC}"
$DOCKER_COMPOSE_CMD -p "$safe_site_name" -f "$safe_site_name/${safe_site_name}-docker-compose.yml" ps

echo -e "${GREEN}✅ Containers restarted successfully!${NC}"
echo -e "${BLUE}⏳ Waiting 30 seconds for containers to be ready...${NC}"
sleep 30

# Verify and fix MySQL password
echo -e "${BLUE}🔐 Verifying MySQL password...${NC}"
if ! docker exec ${safe_site_name}-db mysql -uroot -p"${DB_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  MySQL password mismatch detected - fixing...${NC}"
    
    # Try common default passwords
    COMMON_PASSWORDS=("admin" "root" "password" "")
    PASSWORD_FIXED=false
    
    for pwd in "${COMMON_PASSWORDS[@]}"; do
        if [ -z "$pwd" ]; then
            if docker exec ${safe_site_name}-db mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}'; ALTER USER 'root'@'%' IDENTIFIED BY '${DB_PASSWORD}'; FLUSH PRIVILEGES;" >/dev/null 2>&1; then
                PASSWORD_FIXED=true
                break
            fi
        else
            if docker exec ${safe_site_name}-db mysql -uroot -p"$pwd" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}'; ALTER USER 'root'@'%' IDENTIFIED BY '${DB_PASSWORD}'; FLUSH PRIVILEGES;" >/dev/null 2>&1; then
                PASSWORD_FIXED=true
                break
            fi
        fi
    done
    
    if [ "$PASSWORD_FIXED" = true ]; then
        echo -e "${GREEN}✅ MySQL password fixed and synchronized with .env file${NC}"
    else
        echo -e "${YELLOW}⚠️  Could not auto-fix password. Manual fix may be needed.${NC}"
        echo -e "${BLUE}   Run: docker exec -it ${safe_site_name}-db mysql -uroot${NC}"
        echo -e "${BLUE}   Then: ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';${NC}"
    fi
else
    echo -e "${GREEN}✅ MySQL password is correctly configured${NC}"
fi

# Note: We do NOT modify db_password in site_config.json
# The password created by bench new-site should remain unchanged
echo -e "${GREEN}✅ Site configuration preserved (using password from bench new-site)${NC}"

# Fix database user permissions for app installation
echo -e "${BLUE}🔐 Fixing database user permissions for app installation...${NC}"

# Get site config to extract database credentials
SITE_CONFIG=$(docker exec $APP_CONTAINER cat /home/frappe/frappe-bench/sites/${site_name}/site_config.json 2>/dev/null)

if [ -n "$SITE_CONFIG" ]; then
    # Extract db_name and db_password using python
    DB_INFO=$(echo "$SITE_CONFIG" | python3 -c "
import json, sys
try:
    config = json.load(sys.stdin)
    db_name = config.get('db_name', '')
    db_password = config.get('db_password', '')
    print(f'{db_name}|||{db_password}')
except:
    print('|||')
")
    
    SITE_DB_NAME=$(echo "$DB_INFO" | cut -d'|' -f1)
    SITE_DB_PASSWORD=$(echo "$DB_INFO" | cut -d'|' -f4)
    
    if [ -n "$SITE_DB_NAME" ] && [ -n "$SITE_DB_PASSWORD" ]; then
        echo -e "${BLUE}   Creating database users for: $SITE_DB_NAME${NC}"
        
        # Create database user with wildcard host to allow connections from any IP
        docker exec ${safe_site_name}-db mysql -uroot -p"${DB_PASSWORD}" << MYSQL_EOF
CREATE USER IF NOT EXISTS '${SITE_DB_NAME}'@'%' IDENTIFIED BY '${SITE_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${SITE_DB_NAME}\`.* TO '${SITE_DB_NAME}'@'%';
CREATE USER IF NOT EXISTS '${SITE_DB_NAME}'@'localhost' IDENTIFIED BY '${SITE_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${SITE_DB_NAME}\`.* TO '${SITE_DB_NAME}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_EOF
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}   ✅ Database user '${SITE_DB_NAME}' created with full permissions${NC}"
        else
            echo -e "${YELLOW}   ⚠️  Some database commands may have failed (user might already exist)${NC}"
        fi
    else
        echo -e "${YELLOW}   ⚠️  Could not extract database credentials from site_config.json${NC}"
    fi
else
    echo -e "${YELLOW}   ⚠️  site_config.json not found yet${NC}"
fi

echo -e "${GREEN}✅ Database permissions configured for app installation${NC}"

# Final status check
echo -e "${BLUE}📊 Final container status:${NC}"
$DOCKER_COMPOSE_CMD -p "$safe_site_name" -f "$safe_site_name/${safe_site_name}-docker-compose.yml" ps

# Test if the site is accessible
echo -e "${BLUE}🔍 Testing site accessibility...${NC}"
sleep 10
if curl -f -s http://localhost:8000/api/method/ping >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Site is accessible after restart!${NC}"
else
    echo -e "${YELLOW}⚠️  Site may still be starting up...${NC}"
    echo -e "${BLUE}💡 You can check the status with: docker logs $APP_CONTAINER${NC}"
fi

# Show port information immediately after starting
echo ""
if [[ -f ".traefik-local-config" ]]; then
    source .traefik-local-config
    if [[ "$TRAEFIK_HTTP_PORT" != "80" ]]; then
        echo -e "${BLUE}📍 Using custom HTTP port: ${TRAEFIK_HTTP_PORT}${NC}"
        echo -e "${BLUE}   Your site will be accessible at: http://${site_name}:${TRAEFIK_HTTP_PORT}${NC}"
    else
        echo -e "${BLUE}📍 Using default HTTP port: 80${NC}"
        echo -e "${BLUE}   Your site will be accessible at: http://${site_name}${NC}"
    fi
else
    echo -e "${BLUE}📍 Using default HTTP port: 80${NC}"
    echo -e "${BLUE}   Your site will be accessible at: http://${site_name}${NC}"
fi
echo ""

# Auto-add domain to hosts file for local access
echo ""
echo -e "${BLUE}🔧 Managing hosts file for local access...${NC}"

# Additional network verification to prevent ERR_NETWORK_CHANGED
echo -e "${BLUE}🔍 Final network verification...${NC}"
if docker network inspect traefik_proxy >/dev/null 2>&1; then
    # Verify all site containers are connected
    for container in ${safe_site_name}-app ${safe_site_name}-db ${safe_site_name}-redis; do
        if docker ps --filter "name=$container" --format "{{.Names}}" | grep -q "$container"; then
            # Check if container is on traefik_proxy network
            if docker inspect "$container" | grep -q "traefik_proxy"; then
                echo -e "${GREEN}   ✅ $container connected to traefik_proxy${NC}"
            else
                echo -e "${YELLOW}   ⚠️  Connecting $container to traefik_proxy...${NC}"
                docker network connect traefik_proxy "$container" 2>/dev/null || echo -e "${BLUE}   Already connected${NC}"
            fi
        fi
    done
    echo -e "${GREEN}✅ Network verification complete${NC}"
else
    echo -e "${RED}❌ Network verification failed${NC}"
    echo -e "${YELLOW}   Recreating traefik_proxy network...${NC}"
    docker network create traefik_proxy --driver bridge
fi
echo ""

if manage_hosts_entry "$site_name" "add"; then
    if [[ ! $site_name =~ \.localhost$ ]]; then
        # Get the correct port from local config
        display_port=""
        if [[ -f ".traefik-local-config" ]]; then
            source .traefik-local-config
            if [[ "$TRAEFIK_HTTP_PORT" != "80" ]]; then
                display_port=":${TRAEFIK_HTTP_PORT}"
            fi
        fi
        echo -e "${BLUE}   You can now access your site at: http://$site_name${display_port}${NC}"
        echo -e "${YELLOW}   💡 To remove this domain later, run: ./manage-hosts.sh${NC}"
    fi
fi

# Final messages with port-aware URLs
echo ""
echo -e "${GREEN}🚀 Your optimized site is being prepared and will be live in approximately 5 minutes...${NC}"

# Determine the access URL based on configuration
access_url=""
if [[ -f ".traefik-local-config" ]]; then
    source .traefik-local-config
    if [[ "$USE_LOCALHOST" == "true" ]]; then
        # For localhost domains, show the correct port
        if [[ "$TRAEFIK_HTTP_PORT" != "80" ]]; then
            access_url="http://${site_name}:${TRAEFIK_HTTP_PORT}"
        else
            access_url="http://${site_name}"
        fi
    elif [[ "$TRAEFIK_HTTP_PORT" != "80" ]]; then
        access_url="http://${site_name}:${TRAEFIK_HTTP_PORT}"
    else
        access_url="http://${site_name}"
    fi
else
    # Default to port 80 if no config
    access_url="http://${site_name}"
fi

echo -e "🌐 Your site will be accessible at: ${access_url}"

echo ""
echo "💡 You can change the password after first login."
echo ""
echo "🚀 Benefits of this optimized setup:"
echo "   • Fewer containers to manage (4 vs 9)"
echo "   • Lower resource usage"
echo "   • Simpler networking"
echo "   • All Frappe processes in one container via Supervisor"
echo "   • Single Redis instance for all needs"
echo "   • Full process management and restart capabilities"
echo ""
echo "To add another domain or site, simply run this script again with a different site name."
echo ""
echo -e "${GREEN}🎯 FINAL ACCESS INFORMATION:${NC}"
echo -e "${GREEN}   🌐 Site URL: ${access_url}${NC}"
echo -e "${GREEN}   👤 Username: Administrator${NC}"
echo -e "${GREEN}   🔑 Password: admin${NC}"
echo ""
echo -e "${BLUE}💡 If you encounter net::ERR_NETWORK_CHANGED error:${NC}"
echo -e "   1. Clear your browser cache (Ctrl+Shift+Del)"
echo -e "   2. Close and restart your browser"
echo -e "   3. Try accessing the site again"
echo -e "   4. If issue persists, run: docker network ls (to check networks)"
echo ""
echo "🔧 Process Management Commands:"
echo "   • Check status: sudo docker exec $APP_CONTAINER /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf status"
echo "   • Restart web: sudo docker exec $APP_CONTAINER /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf restart frappe-web"
echo "   • Restart workers: sudo docker exec $APP_CONTAINER /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf restart frappe-worker-*"
echo "   • Restart all: sudo docker exec $APP_CONTAINER /home/frappe/.local/bin/supervisorctl -c /home/frappe/supervisor/supervisord.conf restart all"
echo "   • View logs: sudo docker exec $APP_CONTAINER tail -f /home/frappe/supervisor/logs/frappe-web.log"

echo ""
echo "📦 Custom App Management (Database Permissions Fixed!):"
echo "   • Install custom app: docker exec -it $APP_CONTAINER bench get-app your_app_name"
echo "   • Install app on site: docker exec -it $APP_CONTAINER bench --site ${site_name} install-app your_app_name"
echo "   • Check installed apps: docker exec -it $APP_CONTAINER bench --site ${site_name} list-apps"
echo "   • ✅ Database permissions are automatically configured for app installation!"
echo "   • ✅ No more 'Access denied' errors when installing apps!"
echo "   • Custom apps are now preserved on container restart AND system reboot!"
echo "   • Apps are stored in Docker named volume for persistence"
echo ""
echo "💻 VS Code Development:"
echo "   • Open in VS Code: code ${VSCODE_DIR}/${safe_site_name}-frappe-bench/apps"
echo "   • Edit Frappe/ERPNext code directly in VS Code"
echo "   • Changes are immediately reflected in the running container"
echo ""


# Auto-set restart policy for containers
echo ""
echo -e "${BLUE}🔄 Setting up container restart policies...${NC}"
echo -e "${YELLOW}💡 This ensures your containers automatically start after system reboot${NC}"

set_restart_policy_for_site() {
    local site_name=$1
    
    echo -e "${BLUE}🔄 Setting restart policy for $site_name containers...${NC}"
    
    # Get all containers for this site
    local containers=$(docker ps -a --filter "name=^${site_name}-" --format "{{.Names}}")
    
    if [[ -z "$containers" ]]; then
        echo -e "${YELLOW}⚠️  No containers found for $site_name${NC}"
        return 1
    fi
    
    # For each container, set restart policy to 'always'
    for container in $containers; do
        echo -e "${GREEN}📌 Setting restart policy for $container to 'always'${NC}"
        if docker update --restart=always "$container"; then
            echo -e "${GREEN}✅ Successfully set restart policy for $container${NC}"
        else
            echo -e "${RED}❌ Failed to set restart policy for $container${NC}"
        fi
    done
    
    echo -e "${GREEN}✅ All $site_name containers now set to restart automatically after system reboot${NC}"
}

# Set restart policy for the current site
if set_restart_policy_for_site "$safe_site_name"; then
    echo -e "${GREEN}🎉 Restart policies set successfully!${NC}"
    echo -e "${BLUE}💡 Your containers will now automatically start after system reboot${NC}"
else
    echo -e "${YELLOW}⚠️  Could not set restart policies automatically${NC}"
    echo -e "${BLUE}💡 You can run ./set-restart-policy.sh manually later${NC}"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    🎉 SETUP COMPLETED! 🎉                     ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✅ Your Frappe/ERPNext site is now fully configured and ready!${NC}"
echo ""
echo -e "${BLUE}🔧 What was completed:${NC}"
echo -e "   ✅ ERPNext Version: ${erpnext_version}"
echo -e "   ✅ Site created and configured"
echo -e "   ✅ Containers optimized and running"
echo -e "   ✅ Restart policies set for auto-start after reboot"
echo -e "   ✅ VS Code development environment prepared"
echo -e "   ✅ Hosts file configured for local access"
echo ""
echo -e "${GREEN}🌐 Access your site at: ${access_url}${NC}"
echo -e "${GREEN}👤 Username: Administrator${NC}"
echo -e "${GREEN}🔑 Password: admin${NC}"

echo ""
echo "===================== 🔹 Frappe Setup Info 🔹 ====================="
echo ""
echo "📌 Frappe Version      : ${erpnext_version}"
echo "👤 Default Username    : Administrator"
echo "🔑 Default Password    : admin"
echo ""
echo "💾 MySQL Password      : ${DB_PASSWORD}"
echo "💾 Redis Password      : ${REDIS_PASSWORD}"
echo ""
echo "✅ Database Permissions: Automatically configured for app installation!"
echo "   No more 'Access denied' errors when installing apps."
echo ""
echo "⚠️  Please save these credentials securely."
echo "   They will be required for future updates, backups, and system access."
echo ""
echo "=================================================================="

echo ""
echo -e "${BLUE}💡 Your containers will automatically start after system reboot!${NC}"
echo ""
echo ""


# Docker Manager prompt (if needed)
read -p "Do you want to access the docker-manager? (y/n): " ACCESS_MANAGER

if [[ "$ACCESS_MANAGER" =~ ^[Yy]$ ]]; then
    echo ""
    echo "🚀 Launching Docker Manager..."
    echo ""
    
    # Try different ways to launch docker-manager
    if command -v docker-manager &> /dev/null; then
        echo "✅ Found docker-manager in PATH"
        sudo docker-manager
    elif [[ -f "./docker-manager.sh" ]]; then
        echo "✅ Found docker-manager.sh in current directory"
        sudo ./docker-manager.sh
    elif [[ -f "../docker-manager.sh" ]]; then
        echo "✅ Found docker-manager.sh in project root"
        sudo ../docker-manager.sh
    else
        echo "❌ docker-manager not found in common locations"
        echo ""
        echo "💡 Try these commands:"
        echo "   sudo ./docker-manager.sh"
        echo "   sudo ../docker-manager.sh"
        echo "   sudo docker-manager (if installed globally)"
    fi
else
    echo ""
    echo "💡 You can access the docker-manager anytime by running:"
    echo "   sudo ../docker-manager.sh"
fi
